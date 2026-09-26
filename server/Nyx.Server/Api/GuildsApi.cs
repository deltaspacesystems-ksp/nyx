using Microsoft.EntityFrameworkCore;
using Nyx.Server.Data;
using Nyx.Server.Hubs;
using Nyx.Server.Security;
using Nyx.Server.Services;

namespace Nyx.Server.Api;

public record KeyItem(Guid UserId, string Sealed);

public static class GuildsApi
{
    record NewChannel(Guid Id, int Kind, Guid? ParentId, string? MetaCipher, int Position, bool Restricted, List<KeyItem>? Keys, List<Guid>? Members);
    record CreateGuildReq(string MetaCipher, string EveryoneMeta, string OwnerKey, List<NewChannel>? Channels);
    record MetaReq(string MetaCipher);
    record RoleReq(string MetaCipher, long Permissions, int Position);
    record RolesReq(List<Guid> RoleIds);
    record NickReq(string? NickCipher);
    record TimeoutReq(DateTime? Until);
    record InviteReq(int MaxUses, int ExpiresHours);
    record OwnerReq(Guid UserId);
    record AssetReq(string Kind, string MetaCipher, Guid BlobId);
    record ChannelRotate(Guid ChannelId, int Version, List<KeyItem> Keys);
    record RotateReq(int Version, List<KeyItem> GuildKeys, List<ChannelRotate>? Channels);
    record ShareItem(Guid ScopeId, int Version, Guid UserId, string Sealed);
    record SharesReq(List<ShareItem> Shares);

    static readonly ChannelKind[] GuildKinds = [ChannelKind.Text, ChannelKind.Voice, ChannelKind.Category, ChannelKind.Announcement];

    public static void Map(IEndpointRouteBuilder app)
    {
        var api = app.MapGroup("/api").RequireAuthorization().RequireRateLimiting("api");

        // ------------------------------------------------------------------ guilds
        api.MapPost("/guilds", async (CreateGuildReq r, HttpContext ctx, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Realtime rt) =>
        {
            var uid = me.UserId();
            if (!Support.ValidCipher(r.MetaCipher, 16 * 1024) || !Support.ValidCipher(r.EveryoneMeta, 4096) || !Support.ValidCipher(r.OwnerKey, 2048))
                return Support.Bad("Malformed request.");
            if (await db.Guilds.CountAsync(g => g.OwnerId == uid) >= 20) return Support.Bad("You own too many servers.");
            var chans = r.Channels ?? [];
            if (chans.Count > 50) return Support.Bad("Too many channels.");

            var guild = new Guild { OwnerId = uid, MetaCipher = r.MetaCipher };
            db.Guilds.Add(guild);
            db.GuildMembers.Add(new GuildMember { GuildId = guild.Id, UserId = uid });
            db.Keys.Add(new KeyShare { ScopeId = guild.Id, Version = 1, UserId = uid, Sealed = r.OwnerKey });
            db.Roles.Add(new Role { GuildId = guild.Id, MetaCipher = r.EveryoneMeta, Permissions = (long)Perm.Everyone, Position = 0, IsEveryone = true });

            var created = new List<Channel>();
            foreach (var c in chans)
            {
                if (c.Id == Guid.Empty || !Enum.IsDefined((ChannelKind)c.Kind) || !GuildKinds.Contains((ChannelKind)c.Kind))
                    return Support.Bad("Bad channel.");
                if (await db.Channels.AnyAsync(x => x.Id == c.Id)) return Support.Bad("Channel id already exists.");
                var ch = new Channel { Id = c.Id, GuildId = guild.Id, Kind = (ChannelKind)c.Kind, ParentId = c.ParentId, Position = c.Position, MetaCipher = c.MetaCipher };
                db.Channels.Add(ch);
                created.Add(ch);
                if (ch.Kind == ChannelKind.Category) continue;
                var mine = c.Keys?.FirstOrDefault(k => k.UserId == uid) ?? throw new ApiError(400, "Missing channel key.");
                db.ChannelMembers.Add(new ChannelMember { ChannelId = ch.Id, UserId = uid });
                db.Keys.Add(new KeyShare { ScopeId = ch.Id, Version = 1, UserId = uid, Sealed = mine.Sealed });
            }
            AuthApi.Audit(db, ctx, uid, "guild.created", "", guild.Id);
            await db.SaveChangesAsync();
            await rt.JoinGuild(uid, guild.Id);
            foreach (var c in created.Where(c => c.Kind != ChannelKind.Category)) await rt.JoinChannel(uid, c.Id);
            return Results.Ok(new { guild = Dto.Guild(guild), channels = created.Select(c => Dto.Channel(c)) });
        });

        api.MapPut("/guilds/{gid:guid}", async (Guid gid, MetaReq r, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Access access, Realtime rt) =>
        {
            if (!await access.HasAsync(gid, me.UserId(), Perm.ManageGuild)) return Support.Forbidden();
            if (!Support.ValidCipher(r.MetaCipher, 16 * 1024)) return Support.Bad("Malformed request.");
            var g = await db.Guilds.FirstAsync(x => x.Id == gid);
            g.MetaCipher = r.MetaCipher;
            await db.SaveChangesAsync();
            await rt.ToGuild(gid, "GuildUpdate", Dto.Guild(g));
            return Results.Ok(Dto.Guild(g));
        });

        api.MapDelete("/guilds/{gid:guid}", async (Guid gid, HttpContext ctx, System.Security.Claims.ClaimsPrincipal me, NyxDb db, GuildService guilds) =>
        {
            var g = await db.Guilds.FirstOrDefaultAsync(x => x.Id == gid);
            if (g is null || g.OwnerId != me.UserId()) return Support.Forbidden("Only the owner can delete a server.");
            AuthApi.Audit(db, ctx, me.UserId(), "guild.deleted", "", gid);
            await guilds.DeleteGuildAsync(g);
            return Results.NoContent();
        });

        api.MapPut("/guilds/{gid:guid}/owner", async (Guid gid, OwnerReq r, HttpContext ctx, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Realtime rt) =>
        {
            var g = await db.Guilds.FirstOrDefaultAsync(x => x.Id == gid);
            if (g is null || g.OwnerId != me.UserId()) return Support.Forbidden("Only the owner can transfer a server.");
            if (!await db.GuildMembers.AnyAsync(m => m.GuildId == gid && m.UserId == r.UserId)) return Support.Bad("Not a member.");
            g.OwnerId = r.UserId;
            AuthApi.Audit(db, ctx, me.UserId(), "guild.owner-transferred", r.UserId.ToString(), gid);
            await db.SaveChangesAsync();
            await rt.ToGuild(gid, "GuildUpdate", Dto.Guild(g));
            return Results.NoContent();
        });

        api.MapPost("/guilds/{gid:guid}/leave", async (Guid gid, System.Security.Claims.ClaimsPrincipal me, NyxDb db, GuildService guilds) =>
        {
            var g = await db.Guilds.FirstOrDefaultAsync(x => x.Id == gid);
            if (g is null || !await db.GuildMembers.AnyAsync(m => m.GuildId == gid && m.UserId == me.UserId())) return Support.NotFound();
            if (g.OwnerId == me.UserId()) return Support.Bad("Transfer ownership or delete the server first.");
            await guilds.RemoveMemberAsync(gid, me.UserId(), "left");
            return Results.NoContent();
        });

        // ------------------------------------------------------------------- roles
        api.MapPost("/guilds/{gid:guid}/roles", async (Guid gid, RoleReq r, HttpContext ctx, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Access access, Realtime rt) =>
        {
            var uid = me.UserId();
            if (!await access.HasAsync(gid, uid, Perm.ManageRoles)) return Support.Forbidden();
            var err = await CheckRoleRequest(gid, uid, r, access);
            if (err is not null) return err;
            if (await db.Roles.CountAsync(x => x.GuildId == gid) >= 250) return Support.Bad("Too many roles.");
            var role = new Role { GuildId = gid, MetaCipher = r.MetaCipher, Permissions = r.Permissions, Position = r.Position };
            db.Roles.Add(role);
            AuthApi.Audit(db, ctx, uid, "role.created", role.Id.ToString(), gid);
            await db.SaveChangesAsync();
            await rt.ToGuild(gid, "RoleUpdate", Dto.Role(role));
            return Results.Ok(Dto.Role(role));
        });

        api.MapPut("/guilds/{gid:guid}/roles/{rid:guid}", async (Guid gid, Guid rid, RoleReq r, HttpContext ctx, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Access access, Realtime rt) =>
        {
            var uid = me.UserId();
            if (!await access.HasAsync(gid, uid, Perm.ManageRoles)) return Support.Forbidden();
            var role = await db.Roles.FirstOrDefaultAsync(x => x.Id == rid && x.GuildId == gid);
            if (role is null) return Support.NotFound();
            var rank = await access.RankAsync(gid, uid);
            if (role.Position >= rank && !role.IsEveryone) return Support.Forbidden("That role is above yours.");
            if (role.IsEveryone)
            {
                if (!Support.ValidCipher(r.MetaCipher, 4096)) return Support.Bad("Malformed request.");
                if ((r.Permissions & ~(long)Perm.All) != 0) return Support.Bad("Unknown permissions.");
                role.MetaCipher = r.MetaCipher;
                role.Permissions = r.Permissions & ~(long)Perm.Administrator; // @everyone can never be admin
            }
            else
            {
                var err = await CheckRoleRequest(gid, uid, r, access);
                if (err is not null) return err;
                role.MetaCipher = r.MetaCipher;
                role.Permissions = r.Permissions;
                role.Position = r.Position;
            }
            AuthApi.Audit(db, ctx, uid, "role.updated", rid.ToString(), gid);
            await db.SaveChangesAsync();
            await rt.ToGuild(gid, "RoleUpdate", Dto.Role(role));
            return Results.Ok(Dto.Role(role));
        });

        api.MapDelete("/guilds/{gid:guid}/roles/{rid:guid}", async (Guid gid, Guid rid, HttpContext ctx, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Access access, Realtime rt) =>
        {
            var uid = me.UserId();
            if (!await access.HasAsync(gid, uid, Perm.ManageRoles)) return Support.Forbidden();
            var role = await db.Roles.FirstOrDefaultAsync(x => x.Id == rid && x.GuildId == gid);
            if (role is null || role.IsEveryone) return Support.NotFound();
            if (role.Position >= await access.RankAsync(gid, uid)) return Support.Forbidden("That role is above yours.");
            db.MemberRoles.RemoveRange(db.MemberRoles.Where(m => m.RoleId == rid));
            db.Roles.Remove(role);
            AuthApi.Audit(db, ctx, uid, "role.deleted", rid.ToString(), gid);
            await db.SaveChangesAsync();
            await rt.ToGuild(gid, "RoleDelete", new { guildId = gid, roleId = rid });
            return Results.NoContent();
        });

        api.MapPut("/guilds/{gid:guid}/members/{uid:guid}/roles", async (Guid gid, Guid uid, RolesReq r, HttpContext ctx, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Access access, Realtime rt) =>
        {
            var actor = me.UserId();
            if (!await access.HasAsync(gid, actor, Perm.ManageRoles)) return Support.Forbidden();
            if (!await access.IsGuildMemberAsync(gid, uid)) return Support.NotFound();
            var rank = await access.RankAsync(gid, actor);
            if (uid != actor && await access.RankAsync(gid, uid) >= rank) return Support.Forbidden("That member is above you.");

            var wanted = r.RoleIds.Distinct().ToList();
            var roles = await db.Roles.Where(x => x.GuildId == gid && wanted.Contains(x.Id) && !x.IsEveryone).ToListAsync();
            if (roles.Count != wanted.Count) return Support.Bad("Unknown role.");
            var current = await db.MemberRoles.Where(m => m.GuildId == gid && m.UserId == uid).ToListAsync();
            var currentIds = current.Select(c => c.RoleId).ToHashSet();
            var changed = wanted.Except(currentIds).Concat(currentIds.Except(wanted)).ToList();
            var changedRoles = await db.Roles.Where(x => changed.Contains(x.Id)).ToListAsync();
            if (changedRoles.Any(x => x.Position >= rank)) return Support.Forbidden("You cannot change a role above yours.");

            db.MemberRoles.RemoveRange(current.Where(c => !wanted.Contains(c.RoleId)));
            foreach (var id in wanted.Where(w => !currentIds.Contains(w))) db.MemberRoles.Add(new MemberRole { GuildId = gid, UserId = uid, RoleId = id });
            AuthApi.Audit(db, ctx, actor, "member.roles", $"{uid}: {string.Join(',', wanted)}", gid);
            await db.SaveChangesAsync();
            await rt.ToGuild(gid, "MemberUpdate", new { guildId = gid, userId = uid, roleIds = wanted });
            return Results.NoContent();
        });

        // ----------------------------------------------------------------- members
        api.MapPut("/guilds/{gid:guid}/members/me", async (Guid gid, NickReq r, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Realtime rt) =>
        {
            var m = await db.GuildMembers.FirstOrDefaultAsync(x => x.GuildId == gid && x.UserId == me.UserId());
            if (m is null) return Support.NotFound();
            if (r.NickCipher is { Length: > 4096 }) return Support.Bad("Too large.");
            m.NickCipher = r.NickCipher;
            await db.SaveChangesAsync();
            await rt.ToGuild(gid, "MemberUpdate", new { guildId = gid, userId = m.UserId, nickCipher = m.NickCipher });
            return Results.NoContent();
        });

        api.MapDelete("/guilds/{gid:guid}/members/{uid:guid}", async (Guid gid, Guid uid, HttpContext ctx, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Access access, GuildService guilds) =>
        {
            var actor = me.UserId();
            if (!await access.HasAsync(gid, actor, Perm.KickMembers)) return Support.Forbidden();
            var err = await CanModerate(gid, actor, uid, access, db);
            if (err is not null) return err;
            AuthApi.Audit(db, ctx, actor, "member.kicked", uid.ToString(), gid);
            await guilds.RemoveMemberAsync(gid, uid, "kicked");
            return Results.NoContent();
        });

        api.MapPut("/guilds/{gid:guid}/bans/{uid:guid}", async (Guid gid, Guid uid, HttpContext ctx, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Access access, GuildService guilds) =>
        {
            var actor = me.UserId();
            if (!await access.HasAsync(gid, actor, Perm.BanMembers)) return Support.Forbidden();
            var err = await CanModerate(gid, actor, uid, access, db);
            if (err is not null) return err;
            if (!await db.Bans.AnyAsync(b => b.GuildId == gid && b.UserId == uid)) db.Bans.Add(new GuildBan { GuildId = gid, UserId = uid, BannedBy = actor });
            AuthApi.Audit(db, ctx, actor, "member.banned", uid.ToString(), gid);
            await db.SaveChangesAsync();
            await guilds.RemoveMemberAsync(gid, uid, "banned");
            return Results.NoContent();
        });

        api.MapDelete("/guilds/{gid:guid}/bans/{uid:guid}", async (Guid gid, Guid uid, HttpContext ctx, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Access access) =>
        {
            if (!await access.HasAsync(gid, me.UserId(), Perm.BanMembers)) return Support.Forbidden();
            var b = await db.Bans.FirstOrDefaultAsync(x => x.GuildId == gid && x.UserId == uid);
            if (b is null) return Support.NotFound();
            db.Bans.Remove(b);
            AuthApi.Audit(db, ctx, me.UserId(), "member.unbanned", uid.ToString(), gid);
            await db.SaveChangesAsync();
            return Results.NoContent();
        });

        api.MapGet("/guilds/{gid:guid}/bans", async (Guid gid, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Access access) =>
            !await access.HasAsync(gid, me.UserId(), Perm.BanMembers)
                ? Support.Forbidden()
                : Results.Ok(await db.Bans.AsNoTracking().Where(b => b.GuildId == gid).Select(b => new { b.UserId, b.BannedBy, b.At }).ToListAsync()));

        api.MapPut("/guilds/{gid:guid}/members/{uid:guid}/timeout", async (Guid gid, Guid uid, TimeoutReq r, HttpContext ctx, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Access access, Realtime rt) =>
        {
            var actor = me.UserId();
            if (!await access.HasAsync(gid, actor, Perm.KickMembers)) return Support.Forbidden();
            var err = await CanModerate(gid, actor, uid, access, db);
            if (err is not null) return err;
            if (r.Until is { } u && (u < DateTime.UtcNow || u > DateTime.UtcNow.AddDays(28))) return Support.Bad("Timeout must be within 28 days.");
            var m = await db.GuildMembers.FirstAsync(x => x.GuildId == gid && x.UserId == uid);
            m.TimeoutUntil = r.Until?.ToUniversalTime();
            AuthApi.Audit(db, ctx, actor, "member.timeout", $"{uid} until {r.Until:u}", gid);
            await db.SaveChangesAsync();
            await rt.ToGuild(gid, "MemberUpdate", new { guildId = gid, userId = uid, timeoutUntil = m.TimeoutUntil });
            return Results.NoContent();
        });

        // ----------------------------------------------------------------- invites
        api.MapPost("/guilds/{gid:guid}/invites", async (Guid gid, InviteReq r, HttpContext ctx, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Access access) =>
        {
            if (!await access.HasAsync(gid, me.UserId(), Perm.CreateInvite)) return Support.Forbidden();
            if (r.MaxUses is < 0 or > 100 || r.ExpiresHours is < 1 or > 24 * 30) return Support.Bad("Invalid invite options.");
            if (await db.Invites.CountAsync(i => i.GuildId == gid && i.ExpiresAt > DateTime.UtcNow) >= 50) return Support.Bad("Too many active invites.");
            var inv = new Invite
            {
                Code = Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(6)),
                CreatedBy = me.UserId(), GuildId = gid, MaxUses = r.MaxUses, ExpiresAt = DateTime.UtcNow.AddHours(r.ExpiresHours),
            };
            db.Invites.Add(inv);
            AuthApi.Audit(db, ctx, me.UserId(), "invite.created", inv.Code, gid);
            await db.SaveChangesAsync();
            return Results.Ok(new { inv.Code, inv.MaxUses, inv.Uses, inv.ExpiresAt });
        });

        api.MapGet("/guilds/{gid:guid}/invites", async (Guid gid, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Access access) =>
            !await access.HasAsync(gid, me.UserId(), Perm.ManageGuild)
                ? Support.Forbidden()
                : Results.Ok(await db.Invites.AsNoTracking().Where(i => i.GuildId == gid && i.ExpiresAt > DateTime.UtcNow)
                    .Select(i => new { i.Code, i.CreatedBy, i.MaxUses, i.Uses, i.ExpiresAt }).ToListAsync()));

        api.MapDelete("/invites/{code}", async (string code, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Access access) =>
        {
            var inv = await db.Invites.FirstOrDefaultAsync(i => i.Code == code.ToUpperInvariant());
            if (inv is null) return Support.NotFound();
            var isAdmin = await db.Users.AnyAsync(u => u.Id == me.UserId() && u.IsInstanceAdmin);
            var allowed = inv.CreatedBy == me.UserId() || (inv.GuildId is { } g ? await access.HasAsync(g, me.UserId(), Perm.ManageGuild) : isAdmin);
            if (!allowed) return Support.Forbidden();
            db.Invites.Remove(inv);
            await db.SaveChangesAsync();
            return Results.NoContent();
        });

        api.MapPost("/invites/{code}/join", async (string code, System.Security.Claims.ClaimsPrincipal me, NyxDb db, GuildService guilds) =>
        {
            var inv = await db.Invites.FirstOrDefaultAsync(i => i.Code == code.Trim().ToUpperInvariant());
            if (inv?.GuildId is null || inv.ExpiresAt < DateTime.UtcNow || (inv.MaxUses > 0 && inv.Uses >= inv.MaxUses))
                return Support.Bad("Invalid or expired invite.");
            var guild = await db.Guilds.FirstOrDefaultAsync(g => g.Id == inv.GuildId);
            if (guild is null) return Support.Bad("Invalid or expired invite.");
            if (!await db.GuildMembers.AnyAsync(m => m.GuildId == guild.Id && m.UserId == me.UserId())) inv.Uses++;
            await db.SaveChangesAsync();
            await guilds.AddMemberAsync(guild, me.UserId());
            return Results.Ok(new { guildId = guild.Id });
        });

        // Registration invites (create a new account on this instance): instance admin only.
        api.MapPost("/invites", async (System.Security.Claims.ClaimsPrincipal me, NyxDb db) =>
        {
            if (!await db.Users.AnyAsync(u => u.Id == me.UserId() && u.IsInstanceAdmin)) return Support.Forbidden("Only the instance admin can invite new people.");
            var inv = new Invite
            {
                Code = Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(6)),
                CreatedBy = me.UserId(), MaxUses = 1, ExpiresAt = DateTime.UtcNow.AddDays(2),
            };
            db.Invites.Add(inv);
            await db.SaveChangesAsync();
            return Results.Ok(new { inv.Code, inv.ExpiresAt });
        });

        // ------------------------------------------------------------ custom assets
        api.MapPost("/guilds/{gid:guid}/assets", async (Guid gid, AssetReq r, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Access access, Realtime rt) =>
        {
            var uid = me.UserId();
            if (!await access.HasAsync(gid, uid, Perm.ManageEmojis)) return Support.Forbidden();
            if (r.Kind is not ("emoji" or "sticker" or "sound") || !Support.ValidCipher(r.MetaCipher, 2048)) return Support.Bad("Malformed request.");
            var blob = await db.Blobs.FirstOrDefaultAsync(b => b.Id == r.BlobId && b.Scope == BlobScope.Guild && b.ScopeId == gid && b.OwnerId == uid);
            if (blob is null) return Support.Bad("Upload the file to this server first.");
            if (await db.Assets.CountAsync(a => a.GuildId == gid && a.Kind == r.Kind) >= 250) return Support.Bad("Limit reached.");
            var a = new GuildAsset { GuildId = gid, Kind = r.Kind, MetaCipher = r.MetaCipher, BlobId = r.BlobId, CreatedBy = uid };
            db.Assets.Add(a);
            await db.SaveChangesAsync();
            await rt.ToGuild(gid, "AssetUpdate", Dto.Asset(a));
            return Results.Ok(Dto.Asset(a));
        });

        api.MapDelete("/guilds/{gid:guid}/assets/{aid:guid}", async (Guid gid, Guid aid, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Access access, Realtime rt, BlobStore blobs) =>
        {
            if (!await access.HasAsync(gid, me.UserId(), Perm.ManageEmojis)) return Support.Forbidden();
            var a = await db.Assets.FirstOrDefaultAsync(x => x.Id == aid && x.GuildId == gid);
            if (a is null) return Support.NotFound();
            db.Assets.Remove(a);
            var blob = await db.Blobs.FirstOrDefaultAsync(b => b.Id == a.BlobId);
            if (blob is not null) { db.Blobs.Remove(blob); blobs.Delete(blob.Id); }
            await db.SaveChangesAsync();
            await rt.ToGuild(gid, "AssetDelete", new { guildId = gid, assetId = aid });
            return Results.NoContent();
        });

        api.MapGet("/guilds/{gid:guid}/audit", async (Guid gid, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Access access) =>
            !await access.HasAsync(gid, me.UserId(), Perm.ManageGuild)
                ? Support.Forbidden()
                : Results.Ok(await db.Audit.AsNoTracking().Where(a => a.GuildId == gid).OrderByDescending(a => a.Id).Take(200)
                    .Select(a => new { a.At, a.UserId, a.Action, a.Detail }).ToListAsync()));

        // -------------------------------------------------------------------- keys
        // Seal a key version I hold to another member. Idempotent; only members of the scope, only versions that exist.
        api.MapPost("/keys", async (SharesReq r, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Realtime rt) =>
        {
            var uid = me.UserId();
            if (r.Shares.Count is 0 or > 1000) return Support.Bad("Bad request.");
            var notify = new HashSet<Guid>();
            foreach (var s in r.Shares)
            {
                if (s.Sealed.Length is 0 or > 2048 || s.UserId == uid) continue;
                if (!await db.Keys.AnyAsync(k => k.ScopeId == s.ScopeId && k.Version == s.Version && k.UserId == uid)) continue; // I must hold it
                var isGuild = await db.Guilds.AnyAsync(g => g.Id == s.ScopeId);
                var targetIsMember = isGuild
                    ? await db.GuildMembers.AnyAsync(m => m.GuildId == s.ScopeId && m.UserId == s.UserId)
                    : await db.ChannelMembers.AnyAsync(m => m.ChannelId == s.ScopeId && m.UserId == s.UserId);
                if (!targetIsMember) continue;
                if (await db.Keys.AnyAsync(k => k.ScopeId == s.ScopeId && k.Version == s.Version && k.UserId == s.UserId)) continue;
                db.Keys.Add(new KeyShare { ScopeId = s.ScopeId, Version = s.Version, UserId = s.UserId, Sealed = s.Sealed });
                notify.Add(s.UserId);
            }
            await db.SaveChangesAsync();
            foreach (var u in notify) await rt.ToUser(u, "KeysAvailable", new { });
            return Results.NoContent();
        });

        api.MapPost("/guilds/{gid:guid}/rotate", async (Guid gid, RotateReq r, HttpContext ctx, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Access access, Realtime rt) =>
        {
            var uid = me.UserId();
            if (!await access.HasAsync(gid, uid, Perm.ManageGuild)) return Support.Forbidden();
            var g = await db.Guilds.FirstAsync(x => x.Id == gid);
            if (r.Version != g.KeyVersion + 1) return Support.Error(409, "Key version is out of date.");
            var members = (await db.GuildMembers.Where(m => m.GuildId == gid).Select(m => m.UserId).ToListAsync()).ToHashSet();
            if (!members.SetEquals(r.GuildKeys.Select(k => k.UserId))) return Support.Bad("Keys must cover exactly the current members.");
            foreach (var k in r.GuildKeys) db.Keys.Add(new KeyShare { ScopeId = gid, Version = r.Version, UserId = k.UserId, Sealed = k.Sealed });
            g.KeyVersion = r.Version;

            foreach (var cr in r.Channels ?? [])
            {
                var ch = await db.Channels.FirstOrDefaultAsync(c => c.Id == cr.ChannelId && c.GuildId == gid);
                if (ch is null || cr.Version != ch.KeyVersion + 1) return Support.Error(409, "Channel key version is out of date.");
                var cm = (await db.ChannelMembers.Where(m => m.ChannelId == ch.Id).Select(m => m.UserId).ToListAsync()).ToHashSet();
                if (!cm.SetEquals(cr.Keys.Select(k => k.UserId))) return Support.Bad("Channel keys must cover exactly the current members.");
                foreach (var k in cr.Keys) db.Keys.Add(new KeyShare { ScopeId = ch.Id, Version = cr.Version, UserId = k.UserId, Sealed = k.Sealed });
                ch.KeyVersion = cr.Version;
            }
            AuthApi.Audit(db, ctx, uid, "keys.rotated", $"v{r.Version}", gid);
            await db.SaveChangesAsync();
            await rt.ToGuild(gid, "Resync", new { reason = "keys-rotated", guildId = gid });
            return Results.NoContent();
        });
    }

    static async Task<IResult?> CheckRoleRequest(Guid gid, Guid uid, RoleReq r, Access access)
    {
        if (!Support.ValidCipher(r.MetaCipher, 4096)) return Support.Bad("Malformed request.");
        if ((r.Permissions & ~(long)Perm.All) != 0) return Support.Bad("Unknown permissions.");
        var rank = await access.RankAsync(gid, uid);
        if (r.Position < 1 || r.Position >= rank) return Support.Bad("Role position must be below your highest role.");
        var mine = await access.GuildPermsAsync(gid, uid);
        if ((r.Permissions & ~mine) != 0) return Support.Forbidden("You cannot grant permissions you do not have.");
        return null;
    }

    static async Task<IResult?> CanModerate(Guid gid, Guid actor, Guid target, Access access, NyxDb db)
    {
        var g = await db.Guilds.AsNoTracking().FirstOrDefaultAsync(x => x.Id == gid);
        if (g is null || !await access.IsGuildMemberAsync(gid, target)) return Support.NotFound();
        if (target == g.OwnerId) return Support.Forbidden("You cannot do that to the server owner.");
        if (target == actor) return Support.Bad("You cannot do that to yourself.");
        return await access.RankAsync(gid, target) >= await access.RankAsync(gid, actor)
            ? Support.Forbidden("That member is above you.") : null;
    }
}
