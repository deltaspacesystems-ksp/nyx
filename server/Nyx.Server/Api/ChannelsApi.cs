using Microsoft.EntityFrameworkCore;
using Nyx.Server.Data;
using Nyx.Server.Hubs;
using Nyx.Server.Security;
using Nyx.Server.Services;

namespace Nyx.Server.Api;

public static class ChannelsApi
{
    record NewGuildChannel(Guid? Id, int Kind, Guid? ParentId, string? MetaCipher, int Position, bool Restricted,
        int SlowmodeSeconds, List<Guid>? Members, List<KeyItem>? Keys);
    record UpdateChannelReq(string? MetaCipher, Guid? ParentId, bool ClearParent, int? Position, int? SlowmodeSeconds);
    record ReorderItem(Guid Id, Guid? ParentId, int Position);
    record NewDmReq(List<Guid> UserIds, List<KeyItem> Keys, string? MetaCipher);
    record AddMembersReq(List<Guid> UserIds, int Version, List<KeyItem> Keys);
    record AddMemberReq(string Sealed);
    record RotateChannelReq(int Version, List<KeyItem> Keys);
    record MessageReq(string Ciphertext, int KeyVersion, long? ReplyTo);
    record ReactionReq(string Cipher);
    record ReadReq(long MessageId);

    public static void Map(IEndpointRouteBuilder app)
    {
        var api = app.MapGroup("/api").RequireAuthorization().RequireRateLimiting("api");

        // ------------------------------------------------------------ guild channels
        api.MapPost("/guilds/{gid:guid}/channels", async (Guid gid, NewGuildChannel r, HttpContext ctx, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Access access, Realtime rt) =>
        {
            var uid = me.UserId();
            if (!await access.HasAsync(gid, uid, Perm.ManageChannels)) return Support.Forbidden();
            var kind = (ChannelKind)r.Kind;
            if (!Enum.IsDefined(kind) || kind is ChannelKind.Dm or ChannelKind.GroupDm) return Support.Bad("Bad channel kind.");
            if (r.MetaCipher is { Length: > 8192 }) return Support.Bad("Too large.");
            if (r.SlowmodeSeconds is < 0 or > 21600) return Support.Bad("Bad slowmode.");
            if (await db.Channels.CountAsync(c => c.GuildId == gid) >= 500) return Support.Bad("Too many channels.");
            var id = r.Id ?? Guid.NewGuid();
            if (await db.Channels.AnyAsync(c => c.Id == id)) return Support.Bad("Channel id already exists.");
            if (r.ParentId is { } pid && !await db.Channels.AnyAsync(c => c.Id == pid && c.GuildId == gid && c.Kind == ChannelKind.Category))
                return Support.Bad("Parent must be a category in this server.");

            var ch = new Channel
            {
                Id = id, GuildId = gid, Kind = kind, ParentId = r.ParentId, Position = r.Position, MetaCipher = r.MetaCipher,
                Restricted = r.Restricted && kind != ChannelKind.Category, SlowmodeSeconds = r.SlowmodeSeconds,
            };
            db.Channels.Add(ch);

            var eligible = new HashSet<Guid>();
            if (kind != ChannelKind.Category)
            {
                var guildMembers = (await db.GuildMembers.Where(m => m.GuildId == gid).Select(m => m.UserId).ToListAsync()).ToHashSet();
                eligible = ch.Restricted ? [uid, .. (r.Members ?? []).Where(guildMembers.Contains)] : guildMembers;
                var keys = (r.Keys ?? []).Where(k => eligible.Contains(k.UserId) && k.Sealed.Length is > 0 and <= 2048).DistinctBy(k => k.UserId).ToList();
                if (keys.All(k => k.UserId != uid)) return Support.Bad("Missing channel key.");
                foreach (var m in eligible) db.ChannelMembers.Add(new ChannelMember { ChannelId = id, UserId = m });
                foreach (var k in keys) db.Keys.Add(new KeyShare { ScopeId = id, Version = 1, UserId = k.UserId, Sealed = k.Sealed });
            }
            AuthApi.Audit(db, ctx, uid, "channel.created", id.ToString(), gid);
            await db.SaveChangesAsync();

            var members = ch.Restricted ? eligible.AsEnumerable() : null;
            foreach (var m in eligible) await rt.JoinChannel(m, id);
            if (ch.Restricted) foreach (var m in eligible) await rt.ToUser(m, "ChannelCreate", Dto.Channel(ch, members));
            else await rt.ToGuild(gid, "ChannelCreate", Dto.Channel(ch));
            return Results.Ok(Dto.Channel(ch, members));
        });

        api.MapPut("/channels/{id:guid}", async (Guid id, UpdateChannelReq r, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Access access, Realtime rt) =>
        {
            var uid = me.UserId();
            var ch = await db.Channels.FirstOrDefaultAsync(c => c.Id == id);
            if (ch is null) return Support.NotFound();
            if (ch.GuildId is { } gid)
            {
                if (!await access.HasAsync(gid, uid, Perm.ManageChannels)) return Support.Forbidden();
            }
            else if (!await db.ChannelMembers.AnyAsync(m => m.ChannelId == id && m.UserId == uid)) return Support.NotFound();
            else if (ch.Kind == ChannelKind.Dm) return Support.Bad("Direct messages cannot be edited.");

            if (r.MetaCipher is { } mc)
            {
                if (mc.Length > 8192) return Support.Bad("Too large.");
                ch.MetaCipher = mc;
            }
            if (ch.GuildId is { } g2)
            {
                if (r.ClearParent) ch.ParentId = null;
                else if (r.ParentId is { } p)
                {
                    if (!await db.Channels.AnyAsync(c => c.Id == p && c.GuildId == g2 && c.Kind == ChannelKind.Category)) return Support.Bad("Parent must be a category.");
                    ch.ParentId = p;
                }
                if (r.Position is { } pos) ch.Position = pos;
                if (r.SlowmodeSeconds is { } sm) ch.SlowmodeSeconds = Math.Clamp(sm, 0, 21600);
            }
            await db.SaveChangesAsync();
            await BroadcastChannel(rt, db, ch, "ChannelUpdate");
            return Results.Ok(Dto.Channel(ch));
        });

        api.MapPost("/guilds/{gid:guid}/channels/reorder", async (Guid gid, List<ReorderItem> items, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Access access, Realtime rt) =>
        {
            if (!await access.HasAsync(gid, me.UserId(), Perm.ManageChannels)) return Support.Forbidden();
            if (items.Count > 500) return Support.Bad("Too many items.");
            var ids = items.Select(i => i.Id).ToList();
            var chans = await db.Channels.Where(c => c.GuildId == gid && ids.Contains(c.Id)).ToDictionaryAsync(c => c.Id);
            var categories = (await db.Channels.Where(c => c.GuildId == gid && c.Kind == ChannelKind.Category).Select(c => c.Id).ToListAsync()).ToHashSet();
            foreach (var i in items)
            {
                if (!chans.TryGetValue(i.Id, out var c)) continue;
                if (i.ParentId is { } p && !categories.Contains(p)) continue;
                c.ParentId = c.Kind == ChannelKind.Category ? null : i.ParentId;
                c.Position = i.Position;
            }
            await db.SaveChangesAsync();
            await rt.ToGuild(gid, "ChannelsReordered", items);
            return Results.NoContent();
        });

        api.MapDelete("/channels/{id:guid}", async (Guid id, HttpContext ctx, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Access access, GuildService guilds, Realtime rt) =>
        {
            var ch = await db.Channels.FirstOrDefaultAsync(c => c.Id == id);
            if (ch?.GuildId is not { } gid) return Support.NotFound();
            if (!await access.HasAsync(gid, me.UserId(), Perm.ManageChannels)) return Support.Forbidden();
            if (ch.Kind == ChannelKind.Category)
                foreach (var child in await db.Channels.Where(c => c.ParentId == id).ToListAsync()) child.ParentId = null;
            AuthApi.Audit(db, ctx, me.UserId(), "channel.deleted", id.ToString(), gid);
            await db.SaveChangesAsync();
            var members = await db.ChannelMembers.Where(m => m.ChannelId == id).Select(m => m.UserId).ToListAsync();
            await guilds.PurgeChannelsAsync([id]);
            foreach (var u in members) await rt.LeaveChannel(u, id);
            await rt.ToGuild(gid, "ChannelDelete", new { channelId = id, guildId = gid });
            return Results.NoContent();
        });

        // Private (restricted) guild channels: add / remove a member.
        api.MapPut("/channels/{id:guid}/members/{uid:guid}", async (Guid id, Guid uid, AddMemberReq r, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Access access, Realtime rt) =>
        {
            var ch = await db.Channels.FirstOrDefaultAsync(c => c.Id == id);
            if (ch?.GuildId is not { } gid || !ch.Restricted) return Support.NotFound();
            if (!await access.HasAsync(gid, me.UserId(), Perm.ManageChannels)) return Support.Forbidden();
            if (!await access.IsGuildMemberAsync(gid, uid)) return Support.Bad("Not a member of this server.");
            if (r.Sealed.Length is 0 or > 2048) return Support.Bad("Missing key.");
            if (!await db.ChannelMembers.AnyAsync(m => m.ChannelId == id && m.UserId == uid))
            {
                db.ChannelMembers.Add(new ChannelMember { ChannelId = id, UserId = uid });
                if (!await db.Keys.AnyAsync(k => k.ScopeId == id && k.Version == ch.KeyVersion && k.UserId == uid))
                    db.Keys.Add(new KeyShare { ScopeId = id, Version = ch.KeyVersion, UserId = uid, Sealed = r.Sealed });
                await db.SaveChangesAsync();
                await rt.JoinChannel(uid, id);
                await rt.ToUser(uid, "Resync", new { reason = "added-to-channel", channelId = id });
            }
            return Results.NoContent();
        });

        api.MapDelete("/channels/{id:guid}/members/{uid:guid}", async (Guid id, Guid uid, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Access access, Realtime rt) =>
        {
            var actor = me.UserId();
            var ch = await db.Channels.FirstOrDefaultAsync(c => c.Id == id);
            if (ch is null || !await db.ChannelMembers.AnyAsync(m => m.ChannelId == id && m.UserId == uid)) return Support.NotFound();
            if (ch.Kind == ChannelKind.Dm) return Support.Bad("You cannot leave a direct message; close it instead.");
            if (ch.GuildId is { } gid)
            {
                if (!ch.Restricted) return Support.Bad("Everyone in the server can see this channel.");
                if (!await access.HasAsync(gid, actor, Perm.ManageChannels)) return Support.Forbidden();
            }
            else if (uid != actor && ch.OwnerId != actor) return Support.Forbidden("Only the group owner can remove people.");
            else if (!await db.ChannelMembers.AnyAsync(m => m.ChannelId == id && m.UserId == actor)) return Support.NotFound();

            db.ChannelMembers.RemoveRange(db.ChannelMembers.Where(m => m.ChannelId == id && m.UserId == uid));
            db.Keys.RemoveRange(db.Keys.Where(k => k.ScopeId == id && k.UserId == uid));
            db.ReadStates.RemoveRange(db.ReadStates.Where(r => r.ChannelId == id && r.UserId == uid));
            if (ch.OwnerId == uid)
                ch.OwnerId = await db.ChannelMembers.Where(m => m.ChannelId == id && m.UserId != uid).Select(m => (Guid?)m.UserId).FirstOrDefaultAsync();
            await db.SaveChangesAsync();
            await rt.LeaveChannel(uid, id);
            await rt.ToUser(uid, "ChannelDelete", new { channelId = id, guildId = ch.GuildId });
            await rt.ToChannel(id, "ChannelMemberRemove", new { channelId = id, userId = uid });
            await rt.ToChannel(id, "KeyRotationNeeded", new { channelId = id });
            return Results.NoContent();
        });

        api.MapPost("/channels/{id:guid}/rotate", async (Guid id, RotateChannelReq r, HttpContext ctx, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Access access, Realtime rt) =>
        {
            var uid = me.UserId();
            var ch = await access.MemberChannelAsync(id, uid);
            if (ch is null) return Support.NotFound();
            if (ch.GuildId is { } gid && !await access.HasAsync(gid, uid, Perm.ManageChannels)) return Support.Forbidden();
            if (r.Version != ch.KeyVersion + 1) return Support.Error(409, "Key version is out of date.");
            var members = (await db.ChannelMembers.Where(m => m.ChannelId == id).Select(m => m.UserId).ToListAsync()).ToHashSet();
            if (!members.SetEquals(r.Keys.Select(k => k.UserId))) return Support.Bad("Keys must cover exactly the current members.");
            foreach (var k in r.Keys) db.Keys.Add(new KeyShare { ScopeId = id, Version = r.Version, UserId = k.UserId, Sealed = k.Sealed });
            ch.KeyVersion = r.Version;
            AuthApi.Audit(db, ctx, uid, "keys.rotated", $"channel {id} v{r.Version}", ch.GuildId);
            await db.SaveChangesAsync();
            foreach (var m in members) await rt.ToUser(m, "Resync", new { reason = "keys-rotated", channelId = id });
            return Results.NoContent();
        });

        // ---------------------------------------------------------------------- DMs
        api.MapPost("/dms", async (NewDmReq r, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Realtime rt) =>
        {
            var uid = me.UserId();
            var others = (r.UserIds ?? []).Where(u => u != uid).Distinct().ToList();
            if (others.Count is < 1 or > 9) return Support.Bad("A conversation needs 1-9 other people.");
            var known = await db.Users.Where(u => others.Contains(u.Id)).CountAsync();
            if (known != others.Count) return Support.Bad("Unknown user.");
            if (r.MetaCipher is { Length: > 8192 }) return Support.Bad("Too large.");

            if (await db.Relations.AnyAsync(x => x.Kind == RelationKind.Blocked && ((x.UserId == uid && others.Contains(x.TargetId)) || (x.TargetId == uid && others.Contains(x.UserId)))))
                return Support.Forbidden("You cannot message this person.");

            if (others.Count == 1)
            {
                var pair = Access.PairKey(uid, others[0]);
                var existing = await db.Channels.FirstOrDefaultAsync(c => c.DmPairKey == pair);
                if (existing is not null)
                    return Results.Ok(new { existing = true, channel = Dto.Channel(existing, [uid, others[0]]) });
            }

            var everyone = others.Append(uid).ToHashSet();
            var keys = (r.Keys ?? []).Where(k => everyone.Contains(k.UserId) && k.Sealed.Length is > 0 and <= 2048).DistinctBy(k => k.UserId).ToList();
            if (keys.Count != everyone.Count) return Support.Bad("Keys must cover everyone in the conversation.");
            if (await db.ChannelMembers.CountAsync(m => m.UserId == uid && db.Channels.Any(c => c.Id == m.ChannelId && c.GuildId == null)) >= 500)
                return Support.Bad("Too many conversations.");

            var ch = new Channel
            {
                Kind = others.Count == 1 ? ChannelKind.Dm : ChannelKind.GroupDm,
                DmPairKey = others.Count == 1 ? Access.PairKey(uid, others[0]) : null,
                OwnerId = others.Count == 1 ? null : uid,
                MetaCipher = others.Count == 1 ? null : r.MetaCipher,
            };
            db.Channels.Add(ch);
            foreach (var m in everyone) db.ChannelMembers.Add(new ChannelMember { ChannelId = ch.Id, UserId = m });
            foreach (var k in keys) db.Keys.Add(new KeyShare { ScopeId = ch.Id, Version = 1, UserId = k.UserId, Sealed = k.Sealed });
            await db.SaveChangesAsync();
            foreach (var m in everyone)
            {
                await rt.JoinChannel(m, ch.Id);
                await rt.ToUser(m, "ChannelCreate", Dto.Channel(ch, everyone));
            }
            return Results.Ok(new { existing = false, channel = Dto.Channel(ch, everyone) });
        });

        // Group DM: adding people rotates the key, so newcomers cannot read what was said before they joined.
        api.MapPost("/channels/{id:guid}/members", async (Guid id, AddMembersReq r, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Access access, Realtime rt) =>
        {
            var uid = me.UserId();
            var ch = await access.MemberChannelAsync(id, uid);
            if (ch is null || ch.Kind != ChannelKind.GroupDm) return Support.NotFound();
            var current = (await db.ChannelMembers.Where(m => m.ChannelId == id).Select(m => m.UserId).ToListAsync()).ToHashSet();
            var add = r.UserIds.Distinct().Where(u => !current.Contains(u)).ToList();
            if (add.Count == 0) return Support.Bad("Nobody to add.");
            if (current.Count + add.Count > 10) return Support.Bad("A group can have at most 10 people.");
            if (await db.Users.CountAsync(u => add.Contains(u.Id)) != add.Count) return Support.Bad("Unknown user.");
            var all = current.Concat(add).ToHashSet();
            if (r.Version != ch.KeyVersion + 1 || !all.SetEquals(r.Keys.Select(k => k.UserId))) return Support.Bad("Keys must cover everyone, with the next version.");

            foreach (var u in add) db.ChannelMembers.Add(new ChannelMember { ChannelId = id, UserId = u });
            foreach (var k in r.Keys) db.Keys.Add(new KeyShare { ScopeId = id, Version = r.Version, UserId = k.UserId, Sealed = k.Sealed });
            ch.KeyVersion = r.Version;
            await db.SaveChangesAsync();
            foreach (var u in add) await rt.JoinChannel(u, id);
            foreach (var u in all) await rt.ToUser(u, add.Contains(u) ? "ChannelCreate" : "ChannelUpdate", Dto.Channel(ch, all));
            return Results.NoContent();
        });

        // ----------------------------------------------------------------- messages
        api.MapGet("/channels/{id:guid}/messages", async (Guid id, System.Security.Claims.ClaimsPrincipal me, MessageService svc, long? before, long? after, int? limit) =>
        {
            try { return Results.Ok(await svc.HistoryAsync(me.UserId(), id, before, after, limit ?? 50)); }
            catch (ApiError e) { return Support.Error(e.Status, e.Message); }
        });

        api.MapPost("/channels/{id:guid}/messages", async (Guid id, MessageReq r, System.Security.Claims.ClaimsPrincipal me, MessageService svc) =>
        {
            try { return Results.Ok(new { id = (await svc.CreateAsync(me.UserId(), id, r.Ciphertext, r.KeyVersion, r.ReplyTo)).Id }); }
            catch (ApiError e) { return Support.Error(e.Status, e.Message); }
        });

        api.MapPut("/messages/{id:long}", async (long id, MessageReq r, System.Security.Claims.ClaimsPrincipal me, MessageService svc) =>
        {
            try { await svc.EditAsync(me.UserId(), id, r.Ciphertext, r.KeyVersion); return Results.NoContent(); }
            catch (ApiError e) { return Support.Error(e.Status, e.Message); }
        });

        api.MapDelete("/messages/{id:long}", async (long id, System.Security.Claims.ClaimsPrincipal me, MessageService svc) =>
        {
            try { await svc.DeleteAsync(me.UserId(), id); return Results.NoContent(); }
            catch (ApiError e) { return Support.Error(e.Status, e.Message); }
        });

        api.MapPut("/messages/{id:long}/pin", async (long id, System.Security.Claims.ClaimsPrincipal me, MessageService svc) =>
        {
            try { await svc.SetPinnedAsync(me.UserId(), id, true); return Results.NoContent(); }
            catch (ApiError e) { return Support.Error(e.Status, e.Message); }
        });

        api.MapDelete("/messages/{id:long}/pin", async (long id, System.Security.Claims.ClaimsPrincipal me, MessageService svc) =>
        {
            try { await svc.SetPinnedAsync(me.UserId(), id, false); return Results.NoContent(); }
            catch (ApiError e) { return Support.Error(e.Status, e.Message); }
        });

        api.MapGet("/channels/{id:guid}/pins", async (Guid id, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Access access) =>
        {
            if (await access.MemberChannelAsync(id, me.UserId()) is null) return Support.NotFound();
            var pins = await db.Messages.AsNoTracking().Where(m => m.ChannelId == id && m.Pinned && !m.Deleted).OrderByDescending(m => m.Id).ToListAsync();
            return Results.Ok(pins.Select(m => Dto.Message(m)));
        });

        api.MapPut("/messages/{id:long}/reactions/{tag}", async (long id, string tag, ReactionReq r, System.Security.Claims.ClaimsPrincipal me, MessageService svc) =>
        {
            try { await svc.ReactAsync(me.UserId(), id, tag, r.Cipher, true); return Results.NoContent(); }
            catch (ApiError e) { return Support.Error(e.Status, e.Message); }
        });

        api.MapDelete("/messages/{id:long}/reactions/{tag}", async (long id, string tag, System.Security.Claims.ClaimsPrincipal me, MessageService svc) =>
        {
            try { await svc.ReactAsync(me.UserId(), id, tag, "-", false); return Results.NoContent(); }
            catch (ApiError e) { return Support.Error(e.Status, e.Message); }
        });

        api.MapPut("/channels/{id:guid}/read", async (Guid id, ReadReq r, System.Security.Claims.ClaimsPrincipal me, MessageService svc) =>
        {
            try { await svc.MarkReadAsync(me.UserId(), id, r.MessageId); return Results.NoContent(); }
            catch (ApiError e) { return Support.Error(e.Status, e.Message); }
        });
    }

    static async Task BroadcastChannel(Realtime rt, NyxDb db, Channel ch, string evt)
    {
        if (ch.GuildId is { } gid && (!ch.Restricted || ch.Kind == ChannelKind.Category))
        {
            await rt.ToGuild(gid, evt, Dto.Channel(ch));
            return;
        }
        var members = await db.ChannelMembers.Where(m => m.ChannelId == ch.Id).Select(m => m.UserId).ToListAsync();
        foreach (var m in members) await rt.ToUser(m, evt, Dto.Channel(ch, members));
    }
}
