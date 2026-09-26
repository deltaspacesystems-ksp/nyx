using System.Collections.Concurrent;
using System.Security.Claims;
using Microsoft.EntityFrameworkCore;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;
using Nyx.Server.Data;

namespace Nyx.Server.Security;

public record TokenPair(string AccessToken, string RefreshToken, int ExpiresIn);

/// <summary>
/// Access tokens are short-lived JWTs bound to a session id. Refresh tokens are opaque, stored only as
/// hashes, and rotate on every use; presenting an already-rotated token means it was stolen, so the whole
/// session is revoked. Revoked sessions are rejected immediately (see <see cref="IsRevoked"/>).
/// </summary>
public sealed class SessionService(ServerKeys keys)
{
    public static readonly TimeSpan AccessLifetime = TimeSpan.FromMinutes(15);
    public static readonly TimeSpan RefreshLifetime = TimeSpan.FromDays(60);

    readonly SymmetricSecurityKey _signing = new(keys.Derive("jwt-signing", 64));
    readonly ConcurrentDictionary<Guid, byte> _revoked = new();

    public SymmetricSecurityKey SigningKey => _signing;

    public void LoadRevoked(NyxDb db)
    {
        foreach (var id in db.Sessions.Where(s => s.Revoked || s.ExpiresAt < DateTime.UtcNow).Select(s => s.Id))
            _revoked[id] = 0;
    }

    public bool IsRevoked(Guid sessionId) => _revoked.ContainsKey(sessionId);

    public event Action<Guid, Guid>? SessionRevoked; // (userId, sessionId)

    public async Task<TokenPair> CreateAsync(NyxDb db, User user, string device, string ip)
    {
        var secret = Hashing.RandomToken();
        var s = new Session
        {
            UserId = user.Id,
            Device = Trim(device, 120),
            Ip = ip,
            RefreshHash = Hashing.Sha256(secret),
            ExpiresAt = DateTime.UtcNow + RefreshLifetime,
        };
        db.Sessions.Add(s);
        await db.SaveChangesAsync();
        return new TokenPair(Issue(user.Id, s.Id), $"{s.Id:N}.{secret}", (int)AccessLifetime.TotalSeconds);
    }

    /// <summary>Returns null when the refresh token is unknown, expired or was reused.</summary>
    public async Task<(TokenPair Tokens, Guid UserId)?> RefreshAsync(NyxDb db, string token, string ip)
    {
        var parts = token.Split('.', 2);
        if (parts.Length != 2 || !Guid.TryParseExact(parts[0], "N", out var sid)) return null;
        var s = await db.Sessions.FirstOrDefaultAsync(x => x.Id == sid);
        if (s is null || s.Revoked || s.ExpiresAt < DateTime.UtcNow) return null;

        var hash = Hashing.Sha256(parts[1]);
        if (s.PrevRefreshHash is not null && Hashing.ConstantTimeEquals(s.PrevRefreshHash, hash))
        {
            await RevokeAsync(db, s, "refresh token reuse detected");
            return null;
        }
        if (!Hashing.ConstantTimeEquals(s.RefreshHash, hash)) return null;

        var next = Hashing.RandomToken();
        s.PrevRefreshHash = s.RefreshHash;
        s.RefreshHash = Hashing.Sha256(next);
        s.LastSeen = DateTime.UtcNow;
        s.Ip = ip;
        s.ExpiresAt = DateTime.UtcNow + RefreshLifetime;
        await db.SaveChangesAsync();
        return (new TokenPair(Issue(s.UserId, s.Id), $"{s.Id:N}.{next}", (int)AccessLifetime.TotalSeconds), s.UserId);
    }

    public async Task RevokeAsync(NyxDb db, Session s, string reason)
    {
        s.Revoked = true;
        _revoked[s.Id] = 0;
        db.Audit.Add(new AuditEntry { UserId = s.UserId, Action = "session.revoked", Detail = reason, Ip = s.Ip });
        await db.SaveChangesAsync();
        SessionRevoked?.Invoke(s.UserId, s.Id);
    }

    public async Task RevokeAllExceptAsync(NyxDb db, Guid userId, Guid? keep, string reason)
    {
        var list = await db.Sessions.Where(s => s.UserId == userId && !s.Revoked && s.Id != keep).ToListAsync();
        foreach (var s in list) await RevokeAsync(db, s, reason);
    }

    string Issue(Guid userId, Guid sessionId) => new JsonWebTokenHandler().CreateToken(new SecurityTokenDescriptor
    {
        Subject = new ClaimsIdentity([new Claim("sub", userId.ToString()), new Claim("sid", sessionId.ToString())]),
        Expires = DateTime.UtcNow + AccessLifetime,
        SigningCredentials = new(_signing, SecurityAlgorithms.HmacSha256),
    });

    static string Trim(string s, int max) => s.Length <= max ? s : s[..max];
}

/// <summary>Which SignalR connections belong to which user/session, so the server can manage groups itself.</summary>
public sealed class Connections
{
    readonly ConcurrentDictionary<string, (Guid User, Guid Session)> _byConn = new();
    readonly ConcurrentDictionary<Guid, ConcurrentDictionary<string, byte>> _byUser = new();

    public void Add(string conn, Guid user, Guid session)
    {
        _byConn[conn] = (user, session);
        _byUser.GetOrAdd(user, _ => new())[conn] = 0;
    }

    /// <returns>true when this was the user's last connection.</returns>
    public bool Remove(string conn, out Guid user)
    {
        user = default;
        if (!_byConn.TryRemove(conn, out var v)) return false;
        user = v.User;
        if (!_byUser.TryGetValue(v.User, out var set)) return true;
        set.TryRemove(conn, out _);
        if (!set.IsEmpty) return false;
        _byUser.TryRemove(v.User, out _);
        return true;
    }

    public IEnumerable<string> Of(Guid user) => _byUser.TryGetValue(user, out var s) ? s.Keys : [];
    public IEnumerable<string> OfSession(Guid session) => _byConn.Where(kv => kv.Value.Session == session).Select(kv => kv.Key);
    public IReadOnlyCollection<Guid> OnlineUsers => [.. _byUser.Keys];
    public bool IsOnline(Guid user) => _byUser.ContainsKey(user);
}

/// <summary>Simple token bucket per key (messages, typing, signalling).</summary>
public sealed class Bucket(double capacity, double refillPerSecond)
{
    readonly ConcurrentDictionary<Guid, (double Tokens, DateTime At)> _state = new();

    public bool TryTake(Guid key, double cost = 1)
    {
        var now = DateTime.UtcNow;
        var ok = false;
        _state.AddOrUpdate(key,
            _ => { ok = cost <= capacity; return (capacity - (ok ? cost : 0), now); },
            (_, s) =>
            {
                var t = Math.Min(capacity, s.Tokens + (now - s.At).TotalSeconds * refillPerSecond);
                ok = t >= cost;
                return (t - (ok ? cost : 0), now);
            });
        return ok;
    }
}
