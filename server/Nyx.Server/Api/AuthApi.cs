using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;
using Nyx.Server.Data;
using Nyx.Server.Hubs;
using Nyx.Server.Security;
using Nyx.Server.Services;

namespace Nyx.Server.Api;

public static class AuthApi
{
    record RegisterReq(string Username, string DisplayName, string KdfSalt, string AuthKey,
        string IdentityPublicKey, string AgreementPublicKey, string EncryptedKeyBackup, string InviteCode, string? Device);
    record LoginReq(string Username, string AuthKey, string? Totp, string? RecoveryCode, string? Device);
    record RefreshReq(string RefreshToken);
    record PasswordReq(string OldAuthKey, string NewAuthKey, string NewKdfSalt, string NewEncryptedKeyBackup, string? Totp);
    record CodeReq(string Code);
    record DisableReq(string AuthKey, string Code);

    public static void Audit(NyxDb db, HttpContext ctx, Guid? user, string action, string detail = "", Guid? guild = null) =>
        db.Audit.Add(new AuditEntry { UserId = user, GuildId = guild, Action = action, Detail = detail, Ip = ctx.ClientIp() });

    static bool Base64(string? s, int min, int max)
    {
        if (s is null || s.Length < min || s.Length > max) return false;
        try { _ = Convert.FromBase64String(s); return true; } catch (FormatException) { return false; }
    }

    static string NormalizeName(string s) => s.Trim().ToLowerInvariant();

    public static void Map(IEndpointRouteBuilder app)
    {
        var auth = app.MapGroup("/api/auth").RequireRateLimiting("auth");

        // The salt is public by design (the client needs it to derive its key). Unknown users get a stable
        // decoy so the endpoint cannot be used to find out which usernames exist.
        auth.MapGet("/salt", async (string username, NyxDb db, ServerKeys keys) =>
        {
            var name = NormalizeName(username);
            var u = await db.Users.AsNoTracking().FirstOrDefaultAsync(x => x.Username == name);
            var decoy = Convert.ToBase64String(HMACSHA256.HashData(keys.Derive("decoy-salt"), System.Text.Encoding.UTF8.GetBytes(name))[..16]);
            return Results.Ok(new { salt = u?.KdfSalt ?? decoy });
        });

        auth.MapPost("/register", async (RegisterReq r, HttpContext ctx, NyxDb db, IPasswordHasher<User> hasher,
            SessionService sessions, GuildService guilds, Connections conns, Realtime rt) =>
        {
            var name = NormalizeName(r.Username ?? "");
            if (name.Length is < 3 or > 32 || !name.All(c => (c < 128 && char.IsLetterOrDigit(c)) || c is '_' or '.'))
                return Support.Bad("Username must be 3-32 characters: letters, digits, _ or .");
            if (!Base64(r.KdfSalt, 16, 64) || !Base64(r.AuthKey, 32, 64) || !Base64(r.IdentityPublicKey, 40, 48) ||
                !Base64(r.AgreementPublicKey, 40, 48) || !Base64(r.EncryptedKeyBackup, 16, 8192))
                return Support.Bad("Malformed key material.");
            var display = (r.DisplayName ?? "").Trim();
            if (display.Length == 0) display = name;
            if (display.Length > 40) display = display[..40];

            var code = (r.InviteCode ?? "").Trim().ToUpperInvariant();
            await using var tx = await db.Database.BeginTransactionAsync();
            var invite = await db.Invites.FirstOrDefaultAsync(i => i.Code == code);
            if (invite is null || invite.ExpiresAt < DateTime.UtcNow || (invite.MaxUses > 0 && invite.Uses >= invite.MaxUses))
                return Support.Bad("Invalid or expired invite.");
            if (await db.Users.AnyAsync(x => x.Username == name)) return Support.Error(409, "Username taken.");

            var first = !await db.Users.AnyAsync();
            var user = new User
            {
                Username = name, DisplayName = display, KdfSalt = r.KdfSalt, IdentityPublicKey = r.IdentityPublicKey,
                AgreementPublicKey = r.AgreementPublicKey, EncryptedKeyBackup = r.EncryptedKeyBackup, IsInstanceAdmin = first,
            };
            user.AuthHash = hasher.HashPassword(user, r.AuthKey);
            invite.Uses++;
            db.Users.Add(user);
            Audit(db, ctx, user.Id, "user.registered", $"invite {code}");
            await db.SaveChangesAsync();
            await tx.CommitAsync();

            if (invite.GuildId is { } gid && await db.Guilds.FindAsync(gid) is { } guild)
                await guilds.AddMemberAsync(guild, user.Id);

            await rt.ToAll("UserJoined", new { userId = user.Id });
            var tokens = await sessions.CreateAsync(db, user, r.Device ?? ctx.UserAgent(), ctx.ClientIp());
            return Results.Ok(new { tokens.AccessToken, tokens.RefreshToken, tokens.ExpiresIn, user = Dto.User(user, true) });
        });

        auth.MapPost("/login", async (LoginReq r, HttpContext ctx, NyxDb db, IPasswordHasher<User> hasher,
            SessionService sessions, ServerKeys keys) =>
        {
            var name = NormalizeName(r.Username ?? "");
            var u = await db.Users.FirstOrDefaultAsync(x => x.Username == name);
            if (u is null)
            {
                // Burn the same time a real check would, so response time does not reveal valid usernames.
                hasher.VerifyHashedPassword(new User(), hasher.HashPassword(new User(), "decoy"), r.AuthKey ?? "");
                return Support.Error(401, "Wrong username or password.");
            }
            if (u.LockedUntil is { } until && until > DateTime.UtcNow)
            {
                var wait = (int)Math.Ceiling((until - DateTime.UtcNow).TotalSeconds);
                ctx.Response.Headers.RetryAfter = wait.ToString();
                return Support.Error(429, $"Too many failed attempts. Try again in {wait} s.");
            }

            var ok = hasher.VerifyHashedPassword(u, u.AuthHash, r.AuthKey ?? "") != PasswordVerificationResult.Failed;
            if (!ok)
            {
                u.FailedLogins++;
                if (u.FailedLogins >= 5) u.LockedUntil = DateTime.UtcNow.AddSeconds(Math.Min(900, 30 * Math.Pow(2, u.FailedLogins - 5)));
                Audit(db, ctx, u.Id, "login.failed", $"attempt {u.FailedLogins}");
                await db.SaveChangesAsync();
                return Support.Error(401, "Wrong username or password.");
            }

            if (u.TotpEnabled)
            {
                var secret = Sealed.Unprotect(keys.Derive("totp"), u.TotpSecretEnc!);
                if (!string.IsNullOrWhiteSpace(r.Totp))
                {
                    var step = Totp.Verify(secret, r.Totp.Trim(), u.TotpLastStep);
                    if (step is null) return await TwoFactorFailed(db, ctx, u);
                    u.TotpLastStep = step.Value;
                }
                else if (!string.IsNullOrWhiteSpace(r.RecoveryCode))
                {
                    var codes = JsonSerializer.Deserialize<List<string>>(u.RecoveryCodesJson ?? "[]") ?? [];
                    var h = Hashing.Sha256(r.RecoveryCode.Trim().ToUpperInvariant());
                    if (!codes.Remove(h)) return await TwoFactorFailed(db, ctx, u);
                    u.RecoveryCodesJson = JsonSerializer.Serialize(codes);
                    Audit(db, ctx, u.Id, "2fa.recovery-code-used", $"{codes.Count} left");
                }
                else return Results.Json(new { error = "Two-factor code required.", twoFactor = true }, statusCode: 401);
            }

            u.FailedLogins = 0;
            u.LockedUntil = null;
            Audit(db, ctx, u.Id, "login.ok");
            await db.SaveChangesAsync();
            var tokens = await sessions.CreateAsync(db, u, r.Device ?? ctx.UserAgent(), ctx.ClientIp());
            return Results.Ok(new { tokens.AccessToken, tokens.RefreshToken, tokens.ExpiresIn, user = Dto.User(u, true), encryptedKeyBackup = u.EncryptedKeyBackup });
        });

        auth.MapPost("/refresh", async (RefreshReq r, HttpContext ctx, NyxDb db, SessionService sessions) =>
        {
            var res = await sessions.RefreshAsync(db, r.RefreshToken ?? "", ctx.ClientIp());
            return res is null
                ? Support.Error(401, "Session expired. Please log in again.")
                : Results.Ok(new { res.Value.Tokens.AccessToken, res.Value.Tokens.RefreshToken, res.Value.Tokens.ExpiresIn });
        });

        var api = app.MapGroup("/api/auth").RequireAuthorization().RequireRateLimiting("api");

        api.MapPost("/logout", async (System.Security.Claims.ClaimsPrincipal me, NyxDb db, SessionService sessions, Realtime rt) =>
        {
            var s = await db.Sessions.FirstOrDefaultAsync(x => x.Id == me.SessionId());
            if (s is not null) { await sessions.RevokeAsync(db, s, "logout"); rt.Disconnect(s.Id); }
            return Results.NoContent();
        });

        api.MapGet("/sessions", async (System.Security.Claims.ClaimsPrincipal me, NyxDb db) =>
        {
            var uid = me.UserId();
            var list = await db.Sessions.AsNoTracking().Where(s => s.UserId == uid && !s.Revoked && s.ExpiresAt > DateTime.UtcNow)
                .OrderByDescending(s => s.LastSeen).ToListAsync();
            return list.Select(s => new { s.Id, s.Device, s.Ip, s.CreatedAt, s.LastSeen, Current = s.Id == me.SessionId() });
        });

        api.MapDelete("/sessions/{id:guid}", async (Guid id, System.Security.Claims.ClaimsPrincipal me, NyxDb db, SessionService sessions, Realtime rt) =>
        {
            var uid = me.UserId();
            var s = await db.Sessions.FirstOrDefaultAsync(x => x.Id == id && x.UserId == uid);
            if (s is null) return Support.NotFound();
            await sessions.RevokeAsync(db, s, "revoked by user");
            rt.Disconnect(s.Id);
            return Results.NoContent();
        });

        api.MapDelete("/sessions", async (System.Security.Claims.ClaimsPrincipal me, NyxDb db, SessionService sessions, Realtime rt) =>
        {
            var uid = me.UserId();
            var others = await db.Sessions.Where(s => s.UserId == uid && !s.Revoked && s.Id != me.SessionId()).Select(s => s.Id).ToListAsync();
            await sessions.RevokeAllExceptAsync(db, uid, me.SessionId(), "log out everywhere");
            foreach (var id in others) rt.Disconnect(id);
            return Results.NoContent();
        });

        api.MapPost("/password", async (PasswordReq r, HttpContext ctx, System.Security.Claims.ClaimsPrincipal me, NyxDb db,
            IPasswordHasher<User> hasher, SessionService sessions, Realtime rt, ServerKeys keys) =>
        {
            if (!Base64(r.NewAuthKey, 32, 64) || !Base64(r.NewKdfSalt, 16, 64) || !Base64(r.NewEncryptedKeyBackup, 16, 8192))
                return Support.Bad("Malformed key material.");
            var u = await db.Users.FirstAsync(x => x.Id == me.UserId());
            if (hasher.VerifyHashedPassword(u, u.AuthHash, r.OldAuthKey ?? "") == PasswordVerificationResult.Failed)
                return Support.Error(401, "Current password is wrong.");
            if (u.TotpEnabled)
            {
                var step = Totp.Verify(Sealed.Unprotect(keys.Derive("totp"), u.TotpSecretEnc!), r.Totp ?? "", u.TotpLastStep);
                if (step is null) return Support.Error(401, "Two-factor code is wrong.");
                u.TotpLastStep = step.Value;
            }
            u.KdfSalt = r.NewKdfSalt;
            u.EncryptedKeyBackup = r.NewEncryptedKeyBackup;
            u.AuthHash = hasher.HashPassword(u, r.NewAuthKey);
            Audit(db, ctx, u.Id, "password.changed");
            await db.SaveChangesAsync();
            var others = await db.Sessions.Where(s => s.UserId == u.Id && !s.Revoked && s.Id != me.SessionId()).Select(s => s.Id).ToListAsync();
            await sessions.RevokeAllExceptAsync(db, u.Id, me.SessionId(), "password changed");
            foreach (var id in others) rt.Disconnect(id);
            return Results.NoContent();
        });

        // ---- two-factor ----
        api.MapPost("/totp/setup", async (System.Security.Claims.ClaimsPrincipal me, NyxDb db, ServerKeys keys) =>
        {
            var u = await db.Users.FirstAsync(x => x.Id == me.UserId());
            if (u.TotpEnabled) return Support.Bad("Two-factor authentication is already on.");
            var secret = Totp.NewSecret();
            u.TotpSecretEnc = Sealed.Protect(keys.Derive("totp"), secret);
            await db.SaveChangesAsync();
            return Results.Ok(new { secret, uri = Totp.Uri(secret, u.Username) });
        });

        api.MapPost("/totp/enable", async (CodeReq r, HttpContext ctx, System.Security.Claims.ClaimsPrincipal me, NyxDb db, ServerKeys keys) =>
        {
            var u = await db.Users.FirstAsync(x => x.Id == me.UserId());
            if (u.TotpEnabled || u.TotpSecretEnc is null) return Support.Bad("Start setup first.");
            var step = Totp.Verify(Sealed.Unprotect(keys.Derive("totp"), u.TotpSecretEnc), r.Code ?? "");
            if (step is null) return Support.Bad("That code is not right.");
            var recovery = Enumerable.Range(0, 10).Select(_ => Hashing.RandomToken(8).ToUpperInvariant().Replace('-', 'X').Replace('_', 'Y')[..10]).ToList();
            u.TotpEnabled = true;
            u.TotpLastStep = step.Value;
            u.RecoveryCodesJson = JsonSerializer.Serialize(recovery.Select(c => Hashing.Sha256(c)));
            Audit(db, ctx, u.Id, "2fa.enabled");
            await db.SaveChangesAsync();
            return Results.Ok(new { recoveryCodes = recovery });
        });

        api.MapPost("/totp/disable", async (DisableReq r, HttpContext ctx, System.Security.Claims.ClaimsPrincipal me, NyxDb db,
            IPasswordHasher<User> hasher, ServerKeys keys) =>
        {
            var u = await db.Users.FirstAsync(x => x.Id == me.UserId());
            if (!u.TotpEnabled) return Support.Bad("Two-factor authentication is off.");
            if (hasher.VerifyHashedPassword(u, u.AuthHash, r.AuthKey ?? "") == PasswordVerificationResult.Failed)
                return Support.Error(401, "Password is wrong.");
            if (Totp.Verify(Sealed.Unprotect(keys.Derive("totp"), u.TotpSecretEnc!), r.Code ?? "", u.TotpLastStep) is null)
                return Support.Error(401, "Code is wrong.");
            u.TotpEnabled = false;
            u.TotpSecretEnc = null;
            u.RecoveryCodesJson = null;
            Audit(db, ctx, u.Id, "2fa.disabled");
            await db.SaveChangesAsync();
            return Results.NoContent();
        });

        api.MapGet("/audit", async (System.Security.Claims.ClaimsPrincipal me, NyxDb db) =>
        {
            var uid = me.UserId();
            return await db.Audit.AsNoTracking().Where(a => a.UserId == uid && a.GuildId == null)
                .OrderByDescending(a => a.Id).Take(100).Select(a => new { a.At, a.Action, a.Detail, a.Ip }).ToListAsync();
        });
    }

    static async Task<IResult> TwoFactorFailed(NyxDb db, HttpContext ctx, User u)
    {
        u.FailedLogins++;
        if (u.FailedLogins >= 5) u.LockedUntil = DateTime.UtcNow.AddSeconds(Math.Min(900, 30 * Math.Pow(2, u.FailedLogins - 5)));
        Audit(db, ctx, u.Id, "login.2fa-failed");
        await db.SaveChangesAsync();
        return Results.Json(new { error = "Wrong two-factor code.", twoFactor = true }, statusCode: 401);
    }
}
