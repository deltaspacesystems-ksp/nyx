using Microsoft.AspNetCore.SignalR;
using Nyx.Server.Security;

namespace Nyx.Server.Hubs;

/// <summary>
/// Server-side fan-out. The server owns group membership (it knows who belongs where), so clients never
/// have to subscribe to anything and cannot subscribe to something they are not allowed to see.
/// </summary>
public sealed class Realtime(IHubContext<NyxHub> hub, Connections conns)
{
    public static string Ch(Guid id) => $"ch:{id}";
    public static string Gu(Guid id) => $"g:{id}";
    public static string Us(Guid id) => $"u:{id}";

    public Task ToChannel(Guid channel, string evt, object payload) => hub.Clients.Group(Ch(channel)).SendAsync(evt, payload);
    public Task ToGuild(Guid guild, string evt, object payload) => hub.Clients.Group(Gu(guild)).SendAsync(evt, payload);
    public Task ToUser(Guid user, string evt, object payload) => hub.Clients.Group(Us(user)).SendAsync(evt, payload);
    public Task ToAll(string evt, object payload) => hub.Clients.All.SendAsync(evt, payload);

    public async Task JoinChannel(Guid user, Guid channel)
    {
        foreach (var c in conns.Of(user)) await hub.Groups.AddToGroupAsync(c, Ch(channel));
    }

    public async Task LeaveChannel(Guid user, Guid channel)
    {
        foreach (var c in conns.Of(user)) await hub.Groups.RemoveFromGroupAsync(c, Ch(channel));
    }

    public async Task JoinGuild(Guid user, Guid guild)
    {
        foreach (var c in conns.Of(user)) await hub.Groups.AddToGroupAsync(c, Gu(guild));
    }

    public async Task LeaveGuild(Guid user, Guid guild)
    {
        foreach (var c in conns.Of(user)) await hub.Groups.RemoveFromGroupAsync(c, Gu(guild));
    }

    public void Disconnect(Guid sessionId)
    {
        foreach (var c in conns.OfSession(sessionId)) _ = hub.Clients.Client(c).SendAsync("SessionRevoked", new { });
    }
}
