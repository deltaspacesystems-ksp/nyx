using Microsoft.EntityFrameworkCore;
using Nyx.Server.Data;
using Nyx.Server.Hubs;
using Nyx.Server.Security;

namespace Nyx.Server.Services;

/// <summary>Thrown by services; REST turns it into a JSON error, the hub into a HubException.</summary>
public class ApiError(int status, string message) : Exception(message)
{
    public int Status { get; } = status;
}

public sealed class Limiters
{
    public Bucket Messages { get; } = new(10, 2);     // burst 10, then 2/s
    public Bucket Actions { get; } = new(20, 4);      // reactions, edits, pins
    public Bucket Typing { get; } = new(1, 1.0 / 3);
    public Bucket Signals { get; } = new(60, 30);     // WebRTC signalling (ICE candidates come in bursts)
}

public sealed class MessageService(NyxDb db, Access access, Realtime rt, Limiters limits)
{
    public const int MaxCipher = 256 * 1024;

    async Task<Channel> MemberTextChannel(Guid userId, Guid channelId)
    {
        var ch = await access.MemberChannelAsync(channelId, userId) ?? throw new ApiError(404, "Channel not found.");
        if (!ch.IsText) throw new ApiError(400, "Not a text channel.");
        return ch;
    }

    public async Task<Message> CreateAsync(Guid userId, Guid channelId, string ciphertext, int keyVersion, long? replyTo)
    {
        if (!limits.Messages.TryTake(userId)) throw new ApiError(429, "You are sending messages too fast.");
        if (!Support.ValidCipher(ciphertext, MaxCipher)) throw new ApiError(400, "Message empty or too large.");
        var ch = await MemberTextChannel(userId, channelId);
        if (keyVersion < 1 || keyVersion > ch.KeyVersion) throw new ApiError(400, "Unknown key version.");

        if (ch.Kind == ChannelKind.Dm && ch.DmPairKey is not null)
        {
            var other = await db.ChannelMembers.Where(m => m.ChannelId == channelId && m.UserId != userId).Select(m => m.UserId).FirstOrDefaultAsync();
            if (other != Guid.Empty && await db.Relations.AnyAsync(r => r.Kind == RelationKind.Blocked && ((r.UserId == userId && r.TargetId == other) || (r.UserId == other && r.TargetId == userId))))
                throw new ApiError(403, "You cannot message this person.");
        }

        if (ch.GuildId is { } gid)
        {
            var perms = await access.GuildPermsAsync(gid, userId);
            if ((perms & (long)Perm.SendMessages) == 0) throw new ApiError(403, "You cannot send messages here.");
            if (await access.IsTimedOutAsync(gid, userId)) throw new ApiError(403, "You are timed out.");
            if (ch.SlowmodeSeconds > 0 && (perms & (long)Perm.ManageMessages) == 0)
            {
                var last = await db.Messages.Where(m => m.ChannelId == channelId && m.SenderId == userId)
                    .OrderByDescending(m => m.Id).Select(m => (DateTime?)m.CreatedAt).FirstOrDefaultAsync();
                if (last is not null && (DateTime.UtcNow - last.Value).TotalSeconds < ch.SlowmodeSeconds)
                    throw new ApiError(429, "Slowmode is on for this channel.");
            }
        }

        if (replyTo is { } rid && !await db.Messages.AnyAsync(m => m.Id == rid && m.ChannelId == channelId))
            throw new ApiError(400, "Replied-to message not found.");

        var msg = new Message { ChannelId = channelId, SenderId = userId, Ciphertext = ciphertext, KeyVersion = keyVersion, ReplyTo = replyTo };
        db.Messages.Add(msg);
        await db.SaveChangesAsync();
        await rt.ToChannel(channelId, "MessageCreate", Dto.Message(msg));
        return msg;
    }

    public async Task<Message> EditAsync(Guid userId, long messageId, string ciphertext, int keyVersion)
    {
        if (!limits.Actions.TryTake(userId)) throw new ApiError(429, "Slow down.");
        if (!Support.ValidCipher(ciphertext, MaxCipher)) throw new ApiError(400, "Message empty or too large.");
        var msg = await db.Messages.FirstOrDefaultAsync(m => m.Id == messageId) ?? throw new ApiError(404, "Message not found.");
        var ch = await MemberTextChannel(userId, msg.ChannelId);
        if (msg.SenderId != userId || msg.Deleted) throw new ApiError(403, "You can only edit your own messages.");
        if (keyVersion < 1 || keyVersion > ch.KeyVersion) throw new ApiError(400, "Unknown key version.");
        msg.Ciphertext = ciphertext;
        msg.KeyVersion = keyVersion;
        msg.EditedAt = DateTime.UtcNow;
        await db.SaveChangesAsync();
        await BroadcastUpdate(msg);
        return msg;
    }

    public async Task DeleteAsync(Guid userId, long messageId)
    {
        if (!limits.Actions.TryTake(userId)) throw new ApiError(429, "Slow down.");
        var msg = await db.Messages.FirstOrDefaultAsync(m => m.Id == messageId) ?? throw new ApiError(404, "Message not found.");
        var ch = await MemberTextChannel(userId, msg.ChannelId);
        var own = msg.SenderId == userId;
        if (!own && !(ch.GuildId is not null && await access.HasAsync(ch.GuildId.Value, userId, Perm.ManageMessages)))
            throw new ApiError(403, "You cannot delete this message.");
        msg.Deleted = true;
        msg.Ciphertext = "";
        msg.Pinned = false;
        db.Reactions.RemoveRange(db.Reactions.Where(r => r.MessageId == messageId));
        await db.SaveChangesAsync();
        await rt.ToChannel(msg.ChannelId, "MessageDelete", new { msg.Id, msg.ChannelId });
    }

    public async Task SetPinnedAsync(Guid userId, long messageId, bool pinned)
    {
        if (!limits.Actions.TryTake(userId)) throw new ApiError(429, "Slow down.");
        var msg = await db.Messages.FirstOrDefaultAsync(m => m.Id == messageId) ?? throw new ApiError(404, "Message not found.");
        var ch = await MemberTextChannel(userId, msg.ChannelId);
        if (!await access.ChannelPermAsync(ch, userId, Perm.ManageMessages)) throw new ApiError(403, "Missing permission.");
        if (msg.Deleted) throw new ApiError(400, "Message was deleted.");
        if (pinned && !msg.Pinned && await db.Messages.CountAsync(m => m.ChannelId == ch.Id && m.Pinned) >= 50)
            throw new ApiError(400, "A channel can have at most 50 pinned messages.");
        msg.Pinned = pinned;
        await db.SaveChangesAsync();
        await BroadcastUpdate(msg);
    }

    public async Task ReactAsync(Guid userId, long messageId, string tag, string cipher, bool add)
    {
        if (!limits.Actions.TryTake(userId)) throw new ApiError(429, "Slow down.");
        if (tag.Length is < 8 or > 64 || cipher.Length is < 1 or > 1024) throw new ApiError(400, "Bad reaction.");
        var msg = await db.Messages.FirstOrDefaultAsync(m => m.Id == messageId) ?? throw new ApiError(404, "Message not found.");
        var ch = await MemberTextChannel(userId, msg.ChannelId);
        if (msg.Deleted) throw new ApiError(400, "Message was deleted.");
        if (add)
        {
            if (!await access.ChannelPermAsync(ch, userId, Perm.AddReactions)) throw new ApiError(403, "You cannot add reactions here.");
            if (await db.Reactions.AnyAsync(r => r.MessageId == messageId && r.UserId == userId && r.Tag == tag)) return;
            var distinct = await db.Reactions.Where(r => r.MessageId == messageId).Select(r => r.Tag).Distinct().CountAsync();
            if (distinct >= 20 && !await db.Reactions.AnyAsync(r => r.MessageId == messageId && r.Tag == tag))
                throw new ApiError(400, "Too many different reactions on this message.");
            db.Reactions.Add(new Reaction { MessageId = messageId, UserId = userId, Tag = tag, Cipher = cipher });
        }
        else
        {
            var r = await db.Reactions.FirstOrDefaultAsync(x => x.MessageId == messageId && x.UserId == userId && x.Tag == tag);
            if (r is null) return;
            db.Reactions.Remove(r);
        }
        await db.SaveChangesAsync();
        await BroadcastUpdate(msg);
    }

    public async Task MarkReadAsync(Guid userId, Guid channelId, long lastId)
    {
        await MemberTextChannel(userId, channelId);
        var rs = await db.ReadStates.FirstOrDefaultAsync(r => r.UserId == userId && r.ChannelId == channelId);
        if (rs is null) db.ReadStates.Add(new ReadState { UserId = userId, ChannelId = channelId, LastReadId = lastId });
        else if (lastId > rs.LastReadId) rs.LastReadId = lastId;
        else return;
        await db.SaveChangesAsync();
        await rt.ToUser(userId, "ReadState", new { channelId, lastReadId = lastId });
    }

    public async Task<List<object>> HistoryAsync(Guid userId, Guid channelId, long? before, long? after, int limit)
    {
        var ch = await MemberTextChannel(userId, channelId);
        var q = db.Messages.AsNoTracking().Where(m => m.ChannelId == channelId);
        if (ch.Kind == ChannelKind.GroupDm)
        {
            // Someone added to a group later never gets what was said before (their key does not open it either).
            var since = await db.ChannelMembers.Where(m => m.ChannelId == channelId && m.UserId == userId).Select(m => m.AddedAt).FirstAsync();
            q = q.Where(m => m.CreatedAt >= since.AddSeconds(-1));
        }
        if (before is { } b) q = q.Where(m => m.Id < b);
        if (after is { } a) q = q.Where(m => m.Id > a);
        limit = Math.Clamp(limit, 1, 100);
        var page = after is not null
            ? await q.OrderBy(m => m.Id).Take(limit).ToListAsync()
            : (await q.OrderByDescending(m => m.Id).Take(limit).ToListAsync()).AsEnumerable().Reverse().ToList();
        var ids = page.Select(m => m.Id).ToList();
        var reactions = (await db.Reactions.AsNoTracking().Where(r => ids.Contains(r.MessageId)).ToListAsync()).ToLookup(r => r.MessageId);
        return page.Select(m => Dto.Message(m, reactions[m.Id])).ToList();
    }

    async Task BroadcastUpdate(Message msg)
    {
        var reactions = await db.Reactions.AsNoTracking().Where(r => r.MessageId == msg.Id).ToListAsync();
        await rt.ToChannel(msg.ChannelId, "MessageUpdate", Dto.Message(msg, reactions));
    }
}
