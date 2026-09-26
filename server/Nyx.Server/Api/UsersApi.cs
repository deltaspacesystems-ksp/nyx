using Microsoft.EntityFrameworkCore;
using Nyx.Server.Data;
using Nyx.Server.Hubs;
using Nyx.Server.Security;

namespace Nyx.Server.Api;

public static class UsersApi
{
    record ProfileReq(string? DisplayName, string? ProfileCipher, int? ProfileVersion);
    record ProfileKeyItem(Guid ViewerId, int Version, string Sealed);

    public static void Map(IEndpointRouteBuilder app)
    {
        var api = app.MapGroup("/api").RequireAuthorization().RequireRateLimiting("api");

        // Everything the client needs to render itself, in one round trip.
        api.MapGet("/bootstrap", async (System.Security.Claims.ClaimsPrincipal me, NyxDb db, Connections conns) =>
        {
            var uid = me.UserId();
            var allUsers = await db.Users.AsNoTracking().OrderBy(u => u.CreatedAt).ToListAsync();
            var users = allUsers.Select(u => Dto.User(u, conns.IsOnline(u.Id))).ToList();
            var meUser = allUsers.First(u => u.Id == uid);

            var guildIds = await db.GuildMembers.Where(m => m.UserId == uid).Select(m => m.GuildId).ToListAsync();
            var myChannelIds = await db.ChannelMembers.Where(m => m.UserId == uid).Select(m => m.ChannelId).ToListAsync();
            var chanSet = myChannelIds.ToHashSet();

            var guilds = new List<object>();
            foreach (var gid in guildIds)
            {
                var g = await db.Guilds.AsNoTracking().FirstAsync(x => x.Id == gid);
                var roles = await db.Roles.AsNoTracking().Where(r => r.GuildId == gid).OrderBy(r => r.Position).ToListAsync();
                var members = await db.GuildMembers.AsNoTracking().Where(m => m.GuildId == gid).ToListAsync();
                var memberRoles = (await db.MemberRoles.AsNoTracking().Where(m => m.GuildId == gid).ToListAsync()).ToLookup(m => m.UserId);
                var channels = await db.Channels.AsNoTracking().Where(c => c.GuildId == gid).OrderBy(c => c.Position).ToListAsync();
                var visible = channels.Where(c => c.Kind == ChannelKind.Category || chanSet.Contains(c.Id)).ToList();
                var restrictedIds = visible.Where(c => c.Restricted).Select(c => c.Id).ToList();
                var restricted = (await db.ChannelMembers.AsNoTracking().Where(m => restrictedIds.Contains(m.ChannelId)).ToListAsync()).ToLookup(m => m.ChannelId);
                var assets = await db.Assets.AsNoTracking().Where(a => a.GuildId == gid).ToListAsync();
                guilds.Add(new
                {
                    guild = Dto.Guild(g),
                    roles = roles.Select(Dto.Role),
                    members = members.Select(m => Dto.Member(m, memberRoles[m.UserId].Select(x => x.RoleId))),
                    channels = visible.Select(c => Dto.Channel(c, c.Restricted ? restricted[c.Id].Select(m => m.UserId) : null)),
                    assets = assets.Select(Dto.Asset),
                });
            }

            var dmChannels = await db.Channels.AsNoTracking().Where(c => c.GuildId == null && myChannelIds.Contains(c.Id)).ToListAsync();
            var dmIds = dmChannels.Select(c => c.Id).ToList();
            var dmMembers = (await db.ChannelMembers.AsNoTracking().Where(m => dmIds.Contains(m.ChannelId)).ToListAsync()).ToLookup(m => m.ChannelId);

            var keys = await db.Keys.AsNoTracking().Where(k => k.UserId == uid).Select(k => new { k.ScopeId, k.Version, k.Sealed }).ToListAsync();
            var profileKeys = await db.ProfileKeys.AsNoTracking().Where(p => p.ViewerId == uid).Select(p => new { p.OwnerId, p.Version, p.Sealed }).ToListAsync();
            var reads = await db.ReadStates.AsNoTracking().Where(r => r.UserId == uid).Select(r => new { r.ChannelId, r.LastReadId }).ToListAsync();

            var last = await db.Messages.AsNoTracking().Where(m => myChannelIds.Contains(m.ChannelId))
                .GroupBy(m => m.ChannelId).Select(g => new { ChannelId = g.Key, LastId = g.Max(m => m.Id) }).ToListAsync();

            // Members who still lack the current key of something I hold: my client should seal it to them.
            var pending = new List<object>();
            var held = keys.ToLookup(k => k.ScopeId, k => k.Version);
            foreach (var gid in guildIds)
            {
                var ver = await db.Guilds.Where(g => g.Id == gid).Select(g => g.KeyVersion).FirstAsync();
                if (!held[gid].Contains(ver)) continue;
                var have = db.Keys.Where(k => k.ScopeId == gid && k.Version == ver).Select(k => k.UserId);
                var missing = await db.GuildMembers.Where(m => m.GuildId == gid && !have.Contains(m.UserId)).Select(m => m.UserId).ToListAsync();
                if (missing.Count > 0) pending.Add(new { scopeId = gid, version = ver, userIds = missing });
            }
            foreach (var c in await db.Channels.AsNoTracking().Where(c => myChannelIds.Contains(c.Id)).ToListAsync())
            {
                if (!held[c.Id].Contains(c.KeyVersion)) continue;
                var have = db.Keys.Where(k => k.ScopeId == c.Id && k.Version == c.KeyVersion).Select(k => k.UserId);
                var missing = await db.ChannelMembers.Where(m => m.ChannelId == c.Id && !have.Contains(m.UserId)).Select(m => m.UserId).ToListAsync();
                if (missing.Count > 0) pending.Add(new { scopeId = c.Id, version = c.KeyVersion, userIds = missing });
            }
            // Users without my profile key yet.
            var sharedTo = db.ProfileKeys.Where(p => p.OwnerId == uid).Select(p => p.ViewerId);
            var profilePending = await db.Users.Where(u => u.Id != uid && !sharedTo.Contains(u.Id)).Select(u => u.Id).ToListAsync();

            return Results.Ok(new
            {
                me = Dto.User(meUser, true),
                users,
                guilds,
                dms = dmChannels.Select(c => Dto.Channel(c, dmMembers[c.Id].Select(m => m.UserId))),
                keys,
                profileKeys,
                readStates = reads,
                lastMessageIds = last,
                pendingKeys = pending,
                pendingProfileKeys = profilePending,
                isInstanceAdmin = meUser.IsInstanceAdmin,
                totpEnabled = meUser.TotpEnabled,
                relations = await FriendsApi.ForAsync(db, uid),
                serverTime = DateTime.UtcNow,
            });
        });

        api.MapGet("/users", async (NyxDb db, Connections conns) =>
            (await db.Users.AsNoTracking().OrderBy(u => u.CreatedAt).ToListAsync()).Select(u => Dto.User(u, conns.IsOnline(u.Id))));

        api.MapPut("/users/me", async (ProfileReq r, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Realtime rt, Connections conns) =>
        {
            var u = await db.Users.FirstAsync(x => x.Id == me.UserId());
            if (r.DisplayName is { } dn)
            {
                dn = dn.Trim();
                if (dn.Length is 0 or > 40) return Support.Bad("Display name must be 1-40 characters.");
                u.DisplayName = dn;
            }
            if (r.ProfileCipher is { } pc)
            {
                if (pc.Length > 64 * 1024) return Support.Bad("Profile too large.");
                u.ProfileCipher = pc;
                u.ProfileVersion = r.ProfileVersion ?? u.ProfileVersion + 1;
            }
            await db.SaveChangesAsync();
            await rt.ToAll("UserUpdate", Dto.User(u, conns.IsOnline(u.Id)));
            return Results.Ok(Dto.User(u, true));
        });

        // My profile key, sealed by me to each viewer (only I hold the plain key).
        api.MapPost("/users/me/profile-keys", async (List<ProfileKeyItem> items, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Realtime rt) =>
        {
            var uid = me.UserId();
            if (items.Count is 0 or > 500) return Support.Bad("Bad request.");
            var viewers = items.Select(i => i.ViewerId).ToList();
            var known = (await db.Users.Where(u => viewers.Contains(u.Id)).Select(u => u.Id).ToListAsync()).ToHashSet();
            foreach (var i in items)
            {
                if (!known.Contains(i.ViewerId) || i.ViewerId == uid || i.Sealed.Length is 0 or > 2048) continue;
                var row = await db.ProfileKeys.FirstOrDefaultAsync(p => p.OwnerId == uid && p.ViewerId == i.ViewerId);
                if (row is null) db.ProfileKeys.Add(new ProfileKeyShare { OwnerId = uid, ViewerId = i.ViewerId, Version = i.Version, Sealed = i.Sealed });
                else if (i.Version >= row.Version) { row.Version = i.Version; row.Sealed = i.Sealed; }
            }
            await db.SaveChangesAsync();
            foreach (var v in known) await rt.ToUser(v, "ProfileKey", new { ownerId = uid });
            return Results.NoContent();
        });
    }
}
