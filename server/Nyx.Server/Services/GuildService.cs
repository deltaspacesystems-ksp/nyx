using Microsoft.EntityFrameworkCore;
using Nyx.Server.Data;
using Nyx.Server.Hubs;

namespace Nyx.Server.Services;

/// <summary>Where encrypted blobs live on disk. Files are only ever ciphertext.</summary>
public sealed class BlobStore(string root)
{
    public string Root { get; } = root;
    public string TmpDir { get; } = Path.Combine(root, "tmp");

    public string PathOf(Guid id) => Path.Combine(Root, id.ToString("N"));

    public void Delete(Guid id)
    {
        try { var p = PathOf(id); if (File.Exists(p)) File.Delete(p); } catch (IOException) { }
    }
}

public sealed class GuildService(NyxDb db, Realtime rt, BlobStore blobs)
{
    /// <summary>Adds a user to a guild and to every non-private channel. Keys follow when an online member seals them.</summary>
    public async Task AddMemberAsync(Guild guild, Guid userId)
    {
        if (await db.Bans.AnyAsync(b => b.GuildId == guild.Id && b.UserId == userId))
            throw new ApiError(403, "You are banned from this server.");
        if (await db.GuildMembers.AnyAsync(m => m.GuildId == guild.Id && m.UserId == userId)) return;

        db.GuildMembers.Add(new GuildMember { GuildId = guild.Id, UserId = userId });
        var open = await db.Channels.Where(c => c.GuildId == guild.Id && !c.Restricted && c.Kind != ChannelKind.Category)
            .Select(c => c.Id).ToListAsync();
        foreach (var c in open) db.ChannelMembers.Add(new ChannelMember { ChannelId = c, UserId = userId });
        await db.SaveChangesAsync();

        await rt.JoinGuild(userId, guild.Id);
        foreach (var c in open) await rt.JoinChannel(userId, c);
        await rt.ToGuild(guild.Id, "MemberAdd", new { guildId = guild.Id, userId });
        await rt.ToUser(userId, "Resync", new { reason = "joined-guild", guildId = guild.Id });
    }

    public async Task RemoveMemberAsync(Guid guildId, Guid userId, string reason)
    {
        var chans = await db.Channels.Where(c => c.GuildId == guildId).Select(c => c.Id).ToListAsync();
        var scopes = chans.Append(guildId).ToList();
        db.MemberRoles.RemoveRange(db.MemberRoles.Where(m => m.GuildId == guildId && m.UserId == userId));
        db.GuildMembers.RemoveRange(db.GuildMembers.Where(m => m.GuildId == guildId && m.UserId == userId));
        db.ChannelMembers.RemoveRange(db.ChannelMembers.Where(m => chans.Contains(m.ChannelId) && m.UserId == userId));
        db.Keys.RemoveRange(db.Keys.Where(k => scopes.Contains(k.ScopeId) && k.UserId == userId));
        db.ReadStates.RemoveRange(db.ReadStates.Where(r => chans.Contains(r.ChannelId) && r.UserId == userId));
        await db.SaveChangesAsync();

        foreach (var c in chans) await rt.LeaveChannel(userId, c);
        await rt.LeaveGuild(userId, guildId);
        await rt.ToUser(userId, "GuildRemoved", new { guildId, reason });
        await rt.ToGuild(guildId, "MemberRemove", new { guildId, userId, reason });
        // Anyone with permission re-keys, so the departed member's old keys are useless for anything new.
        await rt.ToGuild(guildId, "KeyRotationNeeded", new { guildId });
    }

    public async Task DeleteGuildAsync(Guild guild)
    {
        var members = await db.GuildMembers.Where(m => m.GuildId == guild.Id).Select(m => m.UserId).ToListAsync();
        var chans = await db.Channels.Where(c => c.GuildId == guild.Id).Select(c => c.Id).ToListAsync();
        await PurgeChannelsAsync(chans);
        var blobIds = await db.Blobs.Where(b => b.Scope == BlobScope.Guild && b.ScopeId == guild.Id).Select(b => b.Id).ToListAsync();
        db.Blobs.RemoveRange(db.Blobs.Where(b => blobIds.Contains(b.Id)));
        db.Assets.RemoveRange(db.Assets.Where(a => a.GuildId == guild.Id));
        db.MemberRoles.RemoveRange(db.MemberRoles.Where(m => m.GuildId == guild.Id));
        db.Roles.RemoveRange(db.Roles.Where(r => r.GuildId == guild.Id));
        db.Bans.RemoveRange(db.Bans.Where(b => b.GuildId == guild.Id));
        db.Invites.RemoveRange(db.Invites.Where(i => i.GuildId == guild.Id));
        db.Keys.RemoveRange(db.Keys.Where(k => k.ScopeId == guild.Id));
        db.GuildMembers.RemoveRange(db.GuildMembers.Where(m => m.GuildId == guild.Id));
        db.Guilds.Remove(guild);
        await db.SaveChangesAsync();
        foreach (var id in blobIds) blobs.Delete(id);

        await rt.ToGuild(guild.Id, "GuildRemoved", new { guildId = guild.Id, reason = "deleted" });
        foreach (var u in members)
        {
            foreach (var c in chans) await rt.LeaveChannel(u, c);
            await rt.LeaveGuild(u, guild.Id);
        }
    }

    /// <summary>Deletes channels with everything in them (messages, reactions, keys, read state, attachments).</summary>
    public async Task PurgeChannelsAsync(List<Guid> channelIds)
    {
        if (channelIds.Count == 0) return;
        var msgIds = db.Messages.Where(m => channelIds.Contains(m.ChannelId)).Select(m => m.Id);
        db.Reactions.RemoveRange(db.Reactions.Where(r => msgIds.Contains(r.MessageId)));
        db.Messages.RemoveRange(db.Messages.Where(m => channelIds.Contains(m.ChannelId)));
        db.ReadStates.RemoveRange(db.ReadStates.Where(r => channelIds.Contains(r.ChannelId)));
        db.Keys.RemoveRange(db.Keys.Where(k => channelIds.Contains(k.ScopeId)));
        db.ChannelMembers.RemoveRange(db.ChannelMembers.Where(m => channelIds.Contains(m.ChannelId)));
        var blobIds = await db.Blobs.Where(b => b.Scope == BlobScope.Channel && channelIds.Contains(b.ScopeId)).Select(b => b.Id).ToListAsync();
        db.Blobs.RemoveRange(db.Blobs.Where(b => blobIds.Contains(b.Id)));
        db.Channels.RemoveRange(db.Channels.Where(c => channelIds.Contains(c.Id)));
        await db.SaveChangesAsync();
        foreach (var id in blobIds) blobs.Delete(id);
    }
}
