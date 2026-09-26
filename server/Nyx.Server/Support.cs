using System.Security.Claims;
using Nyx.Server.Data;

namespace Nyx.Server;

public static class Support
{
    public static Guid UserId(this ClaimsPrincipal p) =>
        Guid.Parse(p.FindFirst("sub")?.Value ?? p.FindFirst(ClaimTypes.NameIdentifier)!.Value);

    public static Guid SessionId(this ClaimsPrincipal p) => Guid.Parse(p.FindFirst("sid")!.Value);

    public static string ClientIp(this HttpContext c) => c.Connection.RemoteIpAddress?.ToString() ?? "?";

    public static string UserAgent(this HttpContext c)
    {
        var ua = c.Request.Headers.UserAgent.ToString();
        return ua.Length > 120 ? ua[..120] : ua;
    }

    public static IResult Error(int status, string message) => Results.Json(new { error = message }, statusCode: status);
    public static IResult Forbidden(string message = "Missing permission.") => Error(403, message);
    public static IResult NotFound(string message = "Not found.") => Error(404, message);
    public static IResult Bad(string message) => Error(400, message);

    public static bool ValidCipher(string? s, int max) => !string.IsNullOrEmpty(s) && s.Length <= max;
}

/// <summary>Wire shapes. Ciphertext fields are opaque to the server.</summary>
public static class Dto
{
    public static object User(User u, bool online) => new
    {
        u.Id, u.Username, u.DisplayName, u.IdentityPublicKey, u.AgreementPublicKey,
        u.ProfileCipher, u.ProfileVersion,
        Presence = !online || u.Presence == "invisible" ? "offline" : u.Presence,
    };

    public static object Guild(Guild g) => new { g.Id, g.OwnerId, g.MetaCipher, g.KeyVersion, g.CreatedAt };

    public static object Channel(Channel c, IEnumerable<Guid>? members = null) => new
    {
        c.Id, c.GuildId, Kind = (int)c.Kind, c.ParentId, c.Position, c.MetaCipher, c.Restricted,
        c.KeyVersion, c.OwnerId, c.SlowmodeSeconds, c.CreatedAt,
        Members = members?.ToArray(),
    };

    public static object Role(Role r) => new { r.Id, r.GuildId, r.MetaCipher, r.Permissions, r.Position, r.IsEveryone };

    public static object Member(GuildMember m, IEnumerable<Guid> roleIds) => new
    {
        m.GuildId, m.UserId, m.JoinedAt, m.NickCipher, m.TimeoutUntil, RoleIds = roleIds.ToArray(),
    };

    public static object Asset(GuildAsset a) => new { a.Id, a.GuildId, a.Kind, a.MetaCipher, a.BlobId, a.CreatedBy };

    public static object Message(Message m, IEnumerable<Reaction>? reactions = null) => new
    {
        m.Id, m.ChannelId, m.SenderId,
        Ciphertext = m.Deleted ? "" : m.Ciphertext,
        m.KeyVersion, m.ReplyTo,
        CreatedAt = DateTime.SpecifyKind(m.CreatedAt, DateTimeKind.Utc),
        EditedAt = m.EditedAt is null ? (DateTime?)null : DateTime.SpecifyKind(m.EditedAt.Value, DateTimeKind.Utc),
        m.Pinned, m.Deleted,
        Reactions = (reactions ?? []).GroupBy(r => r.Tag).Select(g => new
        {
            Tag = g.Key, Cipher = g.First().Cipher, Users = g.Select(r => r.UserId).ToArray(),
        }).ToArray(),
    };
}
