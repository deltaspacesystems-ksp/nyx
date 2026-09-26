using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.EntityFrameworkCore;
using Nyx.Server.Data;
using Nyx.Server.Security;
using Nyx.Server.Services;

namespace Nyx.Server.Api;

/// <summary>
/// Encrypted blobs (attachments, avatars, banners, emoji). Bytes are opaque ciphertext; what the server
/// enforces is *who* may upload, *how much*, and *who* may download (members of the blob's scope only).
/// Uploads go in parts of up to 64 MB because Cloudflare rejects single requests over 100 MB.
/// </summary>
public static class BlobsApi
{
    record StartReq(int Scope, Guid ScopeId, long Size);
    record CompleteReq(int Parts);
    record UploadMeta(Guid Owner, int Scope, Guid ScopeId, long Size);

    public const long MaxPartBytes = 64L * 1024 * 1024;
    public const long SmallScopeMax = 12L * 1024 * 1024; // avatars, banners, emoji

    public static void Map(IEndpointRouteBuilder app, IConfiguration cfg, BlobStore store)
    {
        var maxFile = cfg.GetValue<long?>("Limits:MaxBlobBytes") ?? 10L * 1024 * 1024 * 1024;
        var quota = cfg.GetValue<long?>("Limits:UserQuotaBytes") ?? 50L * 1024 * 1024 * 1024;

        var api = app.MapGroup("/api/blobs").RequireAuthorization().RequireRateLimiting("upload");

        api.MapPost("/uploads", async (StartReq r, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Access access) =>
        {
            var uid = me.UserId();
            if (!Enum.IsDefined((BlobScope)r.Scope)) return Support.Bad("Bad scope.");
            var scope = (BlobScope)r.Scope;
            var limit = scope == BlobScope.Channel ? maxFile : SmallScopeMax;
            if (r.Size < 1 || r.Size > limit) return Support.Error(413, $"File too large (limit {limit / (1024 * 1024)} MB).");

            switch (scope)
            {
                case BlobScope.Channel:
                    var ch = await access.MemberChannelAsync(r.ScopeId, uid);
                    if (ch is null) return Support.NotFound();
                    if (!await access.ChannelPermAsync(ch, uid, Perm.AttachFiles)) return Support.Forbidden("You cannot attach files here.");
                    break;
                case BlobScope.Guild:
                    if (!await access.HasAsync(r.ScopeId, uid, Perm.ManageGuild) && !await access.HasAsync(r.ScopeId, uid, Perm.ManageEmojis))
                        return Support.Forbidden();
                    break;
                case BlobScope.Profile:
                    if (r.ScopeId != uid) return Support.Forbidden();
                    break;
            }

            var used = await db.Blobs.Where(b => b.OwnerId == uid).SumAsync(b => (long?)b.Size) ?? 0;
            if (used + r.Size > quota) return Support.Error(413, "Storage quota exceeded.");
            var open = Directory.Exists(store.TmpDir)
                ? Directory.GetDirectories(store.TmpDir).Count(d => File.Exists(Path.Combine(d, "meta.json")) &&
                    JsonSerializer.Deserialize<UploadMeta>(File.ReadAllText(Path.Combine(d, "meta.json")))?.Owner == uid)
                : 0;
            if (open >= 8) return Support.Error(429, "Too many uploads in progress.");

            var id = Guid.NewGuid();
            var dir = Path.Combine(store.TmpDir, id.ToString("N"));
            Directory.CreateDirectory(dir);
            await File.WriteAllTextAsync(Path.Combine(dir, "meta.json"), JsonSerializer.Serialize(new UploadMeta(uid, r.Scope, r.ScopeId, r.Size)));
            return Results.Ok(new { id });
        });

        UploadMeta? Load(Guid id, Guid uid, out string dir)
        {
            dir = Path.Combine(store.TmpDir, id.ToString("N"));
            var f = Path.Combine(dir, "meta.json");
            if (!File.Exists(f)) return null;
            var m = JsonSerializer.Deserialize<UploadMeta>(File.ReadAllText(f));
            return m?.Owner == uid ? m : null;
        }

        api.MapPut("/uploads/{id:guid}/{part:int}", async (Guid id, int part, HttpContext ctx, System.Security.Claims.ClaimsPrincipal me) =>
        {
            var meta = Load(id, me.UserId(), out var dir);
            if (meta is null) return Support.NotFound();
            if (part is < 0 or > 100_000) return Support.Bad("Bad part number.");
            // Kestrel caps request bodies at 1 MB by default; raise it for this endpoint only (absent in in-memory hosts).
            if (ctx.Features.Get<IHttpMaxRequestBodySizeFeature>() is { IsReadOnly: false } cap) cap.MaxRequestBodySize = MaxPartBytes;

            var tmp = Path.Combine(dir, $"{part}.tmp");
            long written;
            await using (var fs = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None, 81920, useAsync: true))
            {
                await ctx.Request.Body.CopyToAsync(fs, ctx.RequestAborted);
                written = fs.Length;
            }
            // Never accept more than was declared (plus nothing): stops "declare 1 MB, upload 10 GB".
            var others = Directory.GetFiles(dir, "*.part").Where(p => Path.GetFileName(p) != $"{part}.part").Sum(p => new FileInfo(p).Length);
            if (others + written > meta.Size) { File.Delete(tmp); return Support.Error(413, "More data than declared."); }
            File.Move(tmp, Path.Combine(dir, $"{part}.part"), overwrite: true);
            Directory.SetLastWriteTimeUtc(dir, DateTime.UtcNow);
            return Results.Ok(new { part, size = written });
        });

        api.MapPost("/uploads/{id:guid}/complete", async (Guid id, CompleteReq r, System.Security.Claims.ClaimsPrincipal me, NyxDb db) =>
        {
            var uid = me.UserId();
            var meta = Load(id, uid, out var dir);
            if (meta is null) return Support.NotFound();
            if (r.Parts is < 1 or > 100_000) return Support.Bad("Bad part count.");

            var final = store.PathOf(id);
            long total = 0;
            try
            {
                await using (var output = new FileStream(final, FileMode.CreateNew, FileAccess.Write, FileShare.None, 81920, useAsync: true))
                    for (var i = 0; i < r.Parts; i++)
                    {
                        var p = Path.Combine(dir, $"{i}.part");
                        if (!File.Exists(p)) throw new InvalidOperationException($"Missing part {i}.");
                        await using var input = File.OpenRead(p);
                        await input.CopyToAsync(output);
                        total += input.Length;
                    }
                if (total != meta.Size) throw new InvalidOperationException("Size does not match what was declared.");
            }
            catch (InvalidOperationException e)
            {
                if (File.Exists(final)) File.Delete(final);
                return Support.Bad(e.Message);
            }
            Directory.Delete(dir, true);
            db.Blobs.Add(new Blob { Id = id, OwnerId = uid, Size = total, Scope = (BlobScope)meta.Scope, ScopeId = meta.ScopeId });
            await db.SaveChangesAsync();
            return Results.Ok(new { id, size = total });
        });

        api.MapDelete("/uploads/{id:guid}", (Guid id, System.Security.Claims.ClaimsPrincipal me) =>
        {
            if (Load(id, me.UserId(), out var dir) is null) return Support.NotFound();
            Directory.Delete(dir, true);
            return Results.NoContent();
        });

        api.MapGet("/{id:guid}", async (Guid id, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Access access, HttpContext ctx) =>
        {
            var uid = me.UserId();
            var b = await db.Blobs.AsNoTracking().FirstOrDefaultAsync(x => x.Id == id);
            if (b is null || !File.Exists(store.PathOf(id))) return Support.NotFound();
            var allowed = b.Scope switch
            {
                BlobScope.Channel => await access.MemberChannelAsync(b.ScopeId, uid) is not null,
                BlobScope.Guild => await access.IsGuildMemberAsync(b.ScopeId, uid),
                BlobScope.Profile => true, // ciphertext under a key only chosen viewers hold
                _ => false,
            };
            if (!allowed) return Support.NotFound(); // do not reveal that it exists
            // Immutable ciphertext under an unguessable id: safe to cache in the client, never in shared caches.
            ctx.Response.Headers.CacheControl = "private, max-age=31536000, immutable";
            return Results.File(store.PathOf(id), "application/octet-stream", enableRangeProcessing: true);
        });

        api.MapDelete("/{id:guid}", async (Guid id, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Access access) =>
        {
            var uid = me.UserId();
            var b = await db.Blobs.FirstOrDefaultAsync(x => x.Id == id);
            if (b is null) return Support.NotFound();
            var allowed = b.OwnerId == uid || b.Scope switch
            {
                BlobScope.Guild => await access.HasAsync(b.ScopeId, uid, Perm.ManageEmojis),
                BlobScope.Channel => (await db.Channels.FirstOrDefaultAsync(c => c.Id == b.ScopeId)) is { GuildId: { } g } && await access.HasAsync(g, uid, Perm.ManageMessages),
                _ => false,
            };
            if (!allowed) return Support.Forbidden();
            db.Blobs.Remove(b);
            await db.SaveChangesAsync();
            store.Delete(id);
            return Results.NoContent();
        });
    }
}

public static class RtcApi
{
    /// <summary>
    /// STUN/TURN servers with short-lived credentials (coturn "REST" scheme: username = "expiry:user",
    /// credential = base64 HMAC-SHA1 of it). Credentials expire on their own and cannot be reused after a
    /// session is revoked because this endpoint requires a valid access token.
    /// </summary>
    public static void Map(IEndpointRouteBuilder app, IConfiguration cfg)
    {
        app.MapGet("/api/rtc", (System.Security.Claims.ClaimsPrincipal me) =>
        {
            var servers = new List<object>();
            var stun = cfg.GetSection("Rtc:StunUrls").Get<string[]>() ?? ["stun:stun.l.google.com:19302"];
            servers.Add(new { urls = stun });
            var turn = cfg.GetSection("Rtc:TurnUrls").Get<string[]>();
            var secret = cfg["Rtc:TurnSecret"];
            if (turn is { Length: > 0 } && !string.IsNullOrEmpty(secret))
            {
                var user = $"{DateTimeOffset.UtcNow.AddHours(8).ToUnixTimeSeconds()}:{me.UserId()}";
                var cred = Convert.ToBase64String(HMACSHA1.HashData(Encoding.UTF8.GetBytes(secret), Encoding.UTF8.GetBytes(user)));
                servers.Add(new { urls = turn, username = user, credential = cred });
            }
            return Results.Ok(new { iceServers = servers });
        }).RequireAuthorization().RequireRateLimiting("api");
    }
}
