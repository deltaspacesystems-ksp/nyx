using System.Collections.Concurrent;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;
using Nyx.Server.Data;
using Nyx.Server.Security;
using Nyx.Server.Services;

namespace Nyx.Server.Hubs;

public record ActivityInfo(string Name, string? Details, string? State, long Since);
public record VoiceUser(bool Muted, bool Deafened, bool Streaming, bool Camera = false);

/// <summary>Who is in which call. Media itself is peer-to-peer; the server only tracks membership/state.</summary>
public sealed class VoiceRooms
{
    public const int MaxPeers = 10; // P2P mesh: every participant connects to every other one

    readonly ConcurrentDictionary<Guid, ConcurrentDictionary<Guid, VoiceUser>> _rooms = new();
    readonly ConcurrentDictionary<Guid, Guid> _userRoom = new();

    public Guid? RoomOf(Guid user) => _userRoom.TryGetValue(user, out var c) ? c : null;

    public bool TryJoin(Guid channel, Guid user)
    {
        var room = _rooms.GetOrAdd(channel, _ => new());
        if (!room.ContainsKey(user) && room.Count >= MaxPeers) return false;
        room[user] = new VoiceUser(false, false, false);
        _userRoom[user] = channel;
        return true;
    }

    public bool Leave(Guid user, out Guid channel)
    {
        channel = default;
        if (!_userRoom.TryRemove(user, out var c)) return false;
        channel = c;
        if (_rooms.TryGetValue(c, out var room) && room.TryRemove(user, out _) && room.IsEmpty) _rooms.TryRemove(c, out _);
        return true;
    }

    public VoiceUser StateOf(Guid channel, Guid user) =>
        _rooms.TryGetValue(channel, out var room) && room.TryGetValue(user, out var st) ? st : new VoiceUser(false, false, false);

    public void SetState(Guid channel, Guid user, VoiceUser state)
    {
        if (_rooms.TryGetValue(channel, out var room) && room.ContainsKey(user)) room[user] = state;
    }

    public bool InSameRoom(Guid a, Guid b, Guid channel) =>
        _rooms.TryGetValue(channel, out var r) && r.ContainsKey(a) && r.ContainsKey(b);

    public object Snapshot(Guid channel) => new
    {
        channelId = channel,
        users = _rooms.TryGetValue(channel, out var r)
            ? r.Select(kv => new { userId = kv.Key, muted = kv.Value.Muted, deafened = kv.Value.Deafened, streaming = kv.Value.Streaming, camera = kv.Value.Camera }).ToArray()
            : [],
    };

    public IEnumerable<Guid> Users(Guid channel) => _rooms.TryGetValue(channel, out var r) ? r.Keys : [];
}

[Authorize]
public class NyxHub(NyxDb db, Access access, Realtime rt, Connections conns, SessionService sessions,
    MessageService messages, Limiters limits, VoiceRooms voice) : Hub
{
    /// What people are playing / doing right now (memory only, gone when they disconnect).
    static readonly System.Collections.Concurrent.ConcurrentDictionary<Guid, ActivityInfo> Activities = new();

    static readonly HashSet<string> Presences = ["online", "idle", "dnd", "invisible"];

    Guid Me => Context.User!.UserId();
    Guid Sid => Context.User!.SessionId();

    static HubException Fail(ApiError e) => new(e.Message);

    public override async Task OnConnectedAsync()
    {
        if (sessions.IsRevoked(Sid)) { Context.Abort(); return; }

        var first = !conns.IsOnline(Me);
        conns.Add(Context.ConnectionId, Me, Sid);
        await Groups.AddToGroupAsync(Context.ConnectionId, Realtime.Us(Me));
        foreach (var c in await db.ChannelMembers.Where(m => m.UserId == Me).Select(m => m.ChannelId).ToListAsync())
            await Groups.AddToGroupAsync(Context.ConnectionId, Realtime.Ch(c));
        foreach (var g in await db.GuildMembers.Where(m => m.UserId == Me).Select(m => m.GuildId).ToListAsync())
            await Groups.AddToGroupAsync(Context.ConnectionId, Realtime.Gu(g));

        var online = conns.OnlineUsers;
        var presences = await db.Users.Where(u => online.Contains(u.Id)).Select(u => new { u.Id, u.Presence }).ToListAsync();
        await Clients.Caller.SendAsync("Ready", new
        {
            online = presences.Select(p => new { userId = p.Id, presence = p.Presence == "invisible" ? "offline" : p.Presence }),
            activities = presences.Where(p => p.Presence != "invisible" && Activities.ContainsKey(p.Id)).Select(p => new { userId = p.Id, activity = Activities[p.Id] }),
        });

        if (first)
        {
            var mine = await db.Users.Where(u => u.Id == Me).Select(u => u.Presence).FirstAsync();
            if (mine != "invisible") await Clients.Others.SendAsync("Presence", new { userId = Me, presence = mine });
        }
        await base.OnConnectedAsync();
    }

    public override async Task OnDisconnectedAsync(Exception? ex)
    {
        var last = conns.Remove(Context.ConnectionId, out var user);
        if (last)
        {
            await LeaveVoiceInternal(user);
            Activities.TryRemove(user, out _);
            await Clients.Others.SendAsync("Presence", new { userId = user, presence = "offline" });
        }
        await base.OnDisconnectedAsync(ex);
    }

    // ---- chat ----------------------------------------------------------------------------------

    public async Task<long> SendMessage(Guid channelId, string ciphertext, int keyVersion, long? replyTo = null)
    {
        try { return (await messages.CreateAsync(Me, channelId, ciphertext, keyVersion, replyTo)).Id; }
        catch (ApiError e) { throw Fail(e); }
    }

    public async Task Typing(Guid channelId)
    {
        if (!limits.Typing.TryTake(Me)) return;
        if (await access.MemberChannelAsync(channelId, Me) is not null)
            await Clients.OthersInGroup(Realtime.Ch(channelId)).SendAsync("Typing", new { channelId, userId = Me });
    }

    public async Task SetPresence(string presence)
    {
        if (!Presences.Contains(presence)) throw new HubException("Unknown presence.");
        var u = await db.Users.FirstAsync(x => x.Id == Me);
        u.Presence = presence;
        await db.SaveChangesAsync();
        if (presence == "invisible" && Activities.TryRemove(Me, out _)) await rt.ToAll("Activity", new { userId = Me, activity = (ActivityInfo?)null });
        await rt.ToAll("Presence", new { userId = Me, presence = presence == "invisible" ? "offline" : presence });
    }

    /// Sets (or clears, with an empty name) what I am doing. Invisible people are never announced.
    public async Task SetActivity(string? name, string? details, string? state)
    {
        name = name?.Trim();
        if (string.IsNullOrEmpty(name))
        {
            if (Activities.TryRemove(Me, out _)) await rt.ToAll("Activity", new { userId = Me, activity = (ActivityInfo?)null });
            return;
        }
        static string? Cut(string? v, int n) { v = v?.Trim(); return string.IsNullOrEmpty(v) ? null : (v.Length > n ? v[..n] : v); }
        var mine = await db.Users.Where(u => u.Id == Me).Select(u => u.Presence).FirstAsync();
        if (mine == "invisible") return;
        var info = new ActivityInfo(Cut(name, 64)!, Cut(details, 128), Cut(state, 128), Activities.TryGetValue(Me, out var old) && old.Name == name ? old.Since : DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        Activities[Me] = info;
        await rt.ToAll("Activity", new { userId = Me, activity = info });
    }

    // ---- voice / screen share ----------------------------------------------------------------

    public async Task JoinVoice(Guid channelId)
    {
        var ch = await access.MemberChannelAsync(channelId, Me) ?? throw new HubException("Channel not found.");
        if (ch.Kind is not (ChannelKind.Voice or ChannelKind.Dm or ChannelKind.GroupDm))
            throw new HubException("Not a voice channel.");
        if (ch.GuildId is { } gid && !await access.HasAsync(gid, Me, Perm.Connect))
            throw new HubException("You cannot join this voice channel.");

        if (voice.RoomOf(Me) is { } cur && cur != channelId) await LeaveVoiceInternal(Me);
        if (!voice.TryJoin(channelId, Me)) throw new HubException($"Call is full ({VoiceRooms.MaxPeers} people).");

        await rt.ToChannel(channelId, "VoiceJoined", new { channelId, userId = Me });
        await Clients.Caller.SendAsync("VoiceParticipants", new { channelId, userIds = voice.Users(channelId).ToArray() });
        await rt.ToChannel(channelId, "VoiceState", voice.Snapshot(channelId));
    }

    public Task LeaveVoice() => LeaveVoiceInternal(Me);

    public async Task SetVoiceState(bool muted, bool deafened, bool streaming)
    {
        if (voice.RoomOf(Me) is not { } ch) return;
        if (streaming && ch != Guid.Empty)
        {
            var channel = await db.Channels.AsNoTracking().FirstOrDefaultAsync(c => c.Id == ch);
            if (channel?.GuildId is { } gid && !await access.HasAsync(gid, Me, Perm.Stream))
                throw new HubException("You cannot stream in this server.");
        }
        voice.SetState(ch, Me, voice.StateOf(ch, Me) with { Muted = muted, Deafened = deafened, Streaming = streaming });
        await rt.ToChannel(ch, "VoiceState", voice.Snapshot(ch));
    }

    public async Task SetVoiceCamera(bool on)
    {
        if (voice.RoomOf(Me) is not { } ch) return;
        voice.SetState(ch, Me, voice.StateOf(ch, Me) with { Camera = on });
        await rt.ToChannel(ch, "VoiceState", voice.Snapshot(ch));
    }

    async Task LeaveVoiceInternal(Guid user)
    {
        if (!voice.Leave(user, out var ch)) return;
        await rt.ToChannel(ch, "VoiceLeft", new { channelId = ch, userId = user });
        await rt.ToChannel(ch, "VoiceState", voice.Snapshot(ch));
    }

    /// <summary>Relays an encrypted SDP/ICE blob. Only between two people who are in the same call.</summary>
    public async Task Signal(Guid toUser, Guid channelId, string payload)
    {
        if (payload.Length > 64 * 1024) throw new HubException("Signal too large.");
        if (!limits.Signals.TryTake(Me)) throw new HubException("Too many signals.");
        if (!voice.InSameRoom(Me, toUser, channelId)) throw new HubException("Not in the same call.");
        await Clients.Group(Realtime.Us(toUser)).SendAsync("Signal", new { from = Me, channelId, payload });
    }
}
