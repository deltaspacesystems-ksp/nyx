using Microsoft.EntityFrameworkCore;
using Nyx.Server.Data;

namespace Nyx.Server.Security;

/// <summary>Central place for "may this user do that?". Every endpoint and hub method goes through it.</summary>
public sealed class Access(NyxDb db)
{
    public async Task<long> GuildPermsAsync(Guid guildId, Guid userId)
    {
        var g = await db.Guilds.AsNoTracking().FirstOrDefaultAsync(x => x.Id == guildId);
        if (g is null) return 0;
        if (g.OwnerId == userId) return (long)Perm.All;
        if (!await db.GuildMembers.AnyAsync(m => m.GuildId == guildId && m.UserId == userId)) return 0;

        var mine = db.MemberRoles.Where(m => m.GuildId == guildId && m.UserId == userId).Select(m => m.RoleId);
        var perms = await db.Roles.Where(r => r.GuildId == guildId && (r.IsEveryone || mine.Contains(r.Id)))
            .Select(r => r.Permissions).ToListAsync();
        long acc = 0;
        foreach (var p in perms) acc |= p;
        return (acc & (long)Perm.Administrator) != 0 ? (long)Perm.All : acc;
    }

    public async Task<bool> HasAsync(Guid guildId, Guid userId, Perm perm)
    {
        var have = await GuildPermsAsync(guildId, userId);
        return (have & (long)perm) == (long)perm;
    }

    /// <summary>Owner = int.MaxValue; otherwise the highest role position the member holds (0 = @everyone).</summary>
    public async Task<int> RankAsync(Guid guildId, Guid userId)
    {
        var g = await db.Guilds.AsNoTracking().FirstOrDefaultAsync(x => x.Id == guildId);
        if (g is null) return -1;
        if (g.OwnerId == userId) return int.MaxValue;
        var mine = db.MemberRoles.Where(m => m.GuildId == guildId && m.UserId == userId).Select(m => m.RoleId);
        var pos = await db.Roles.Where(r => mine.Contains(r.Id)).Select(r => (int?)r.Position).MaxAsync();
        return pos ?? 0;
    }

    public Task<bool> IsGuildMemberAsync(Guid guildId, Guid userId) =>
        db.GuildMembers.AnyAsync(m => m.GuildId == guildId && m.UserId == userId);

    /// <summary>The channel, but only if the user is a member of it.</summary>
    public async Task<Channel?> MemberChannelAsync(Guid channelId, Guid userId)
    {
        var ch = await db.Channels.FirstOrDefaultAsync(c => c.Id == channelId);
        if (ch is null) return null;
        var member = await db.ChannelMembers.AnyAsync(m => m.ChannelId == channelId && m.UserId == userId);
        return member ? ch : null;
    }

    /// <summary>Permission for an action inside a channel: DMs have no roles, guild channels use guild roles.</summary>
    public async Task<bool> ChannelPermAsync(Channel ch, Guid userId, Perm perm)
    {
        if (ch.GuildId is null) return true; // DM / group DM members may do everything (owner-only actions are checked separately)
        return await HasAsync(ch.GuildId.Value, userId, perm);
    }

    public async Task<bool> IsTimedOutAsync(Guid guildId, Guid userId)
    {
        var until = await db.GuildMembers.Where(m => m.GuildId == guildId && m.UserId == userId)
            .Select(m => m.TimeoutUntil).FirstOrDefaultAsync();
        return until is not null && until > DateTime.UtcNow;
    }

    public static string PairKey(Guid a, Guid b) =>
        a.CompareTo(b) < 0 ? $"{a:N}:{b:N}" : $"{b:N}:{a:N}";
}
