using System.Threading.RateLimiting;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Diagnostics;
using Microsoft.EntityFrameworkCore;
using Microsoft.IdentityModel.Tokens;
using Nyx.Server.Api;
using Nyx.Server.Data;
using Nyx.Server.Hubs;
using Nyx.Server.Security;
using Nyx.Server.Services;

var builder = WebApplication.CreateBuilder(args);

var dataDir = Path.GetFullPath(builder.Configuration["Data:Path"] ?? "data");
Directory.CreateDirectory(dataDir);
var blobStore = new BlobStore(Path.Combine(dataDir, "blobs"));
Directory.CreateDirectory(blobStore.TmpDir);
var keys = ServerKeys.LoadOrCreate(Path.Combine(dataDir, "server.key"));

builder.Services.AddSingleton(keys);
builder.Services.AddSingleton(blobStore);
builder.Services.AddSingleton<SessionService>();
builder.Services.AddSingleton<Connections>();
builder.Services.AddSingleton<Limiters>();
builder.Services.AddSingleton<VoiceRooms>();
builder.Services.AddSingleton<Realtime>();
builder.Services.AddSingleton<IPasswordHasher<User>, PasswordHasher<User>>();
builder.Services.AddHostedService<Janitor>();
builder.Services.AddDbContext<NyxDb>(o => o.UseSqlite($"Data Source={Path.Combine(dataDir, "nyx.db")}"));
builder.Services.AddScoped<Access>();
builder.Services.AddScoped<MessageService>();
builder.Services.AddScoped<GuildService>();
builder.Services.AddSignalR(o =>
{
    o.MaximumReceiveMessageSize = 512 * 1024;
    o.ClientTimeoutInterval = TimeSpan.FromSeconds(45);
    o.KeepAliveInterval = TimeSpan.FromSeconds(15);
});
builder.Services.AddAuthorization();
builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme).AddJwtBearer(o =>
{
    o.TokenValidationParameters = new()
    {
        ValidateIssuer = false,
        ValidateAudience = false,
        ValidateLifetime = true,
        ClockSkew = TimeSpan.FromSeconds(30),
        NameClaimType = "sub",
    };
    o.Events = new()
    {
        OnMessageReceived = ctx =>
        {
            // WebSockets cannot set headers, so SignalR passes the token in the query string.
            if (ctx.HttpContext.Request.Path.StartsWithSegments("/hub") && ctx.Request.Query.TryGetValue("access_token", out var t))
                ctx.Token = t;
            return Task.CompletedTask;
        },
        OnTokenValidated = ctx =>
        {
            var sessions = ctx.HttpContext.RequestServices.GetRequiredService<SessionService>();
            if (!Guid.TryParse(ctx.Principal?.FindFirst("sid")?.Value, out var sid) || sessions.IsRevoked(sid))
                ctx.Fail("Session revoked.");
            return Task.CompletedTask;
        },
    };
});
// The signing key comes from SessionService (derived from the server master key).
builder.Services.AddOptions<JwtBearerOptions>(JwtBearerDefaults.AuthenticationScheme)
    .Configure<SessionService>((o, s) => o.TokenValidationParameters.IssuerSigningKey = s.SigningKey);

builder.Services.AddRateLimiter(o =>
{
    o.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    static string Who(HttpContext c) => c.User.Identity?.IsAuthenticated == true ? "u:" + c.User.FindFirst("sub")?.Value : "ip:" + c.Connection.RemoteIpAddress;
    var authPerMinute = builder.Configuration.GetValue<int?>("RateLimits:AuthPerMinute") ?? 20;
    var apiBurst = builder.Configuration.GetValue<int?>("RateLimits:ApiBurst") ?? 200;
    var apiPerSecond = builder.Configuration.GetValue<int?>("RateLimits:ApiPerSecond") ?? 20;
    o.AddPolicy("auth", c => RateLimitPartition.GetSlidingWindowLimiter("ip:" + c.Connection.RemoteIpAddress,
        _ => new SlidingWindowRateLimiterOptions { PermitLimit = authPerMinute, Window = TimeSpan.FromMinutes(1), SegmentsPerWindow = 6 }));
    o.AddPolicy("api", c => RateLimitPartition.GetTokenBucketLimiter(Who(c),
        _ => new TokenBucketRateLimiterOptions { TokenLimit = apiBurst, TokensPerPeriod = apiPerSecond, ReplenishmentPeriod = TimeSpan.FromSeconds(1), QueueLimit = 0 }));
    o.AddPolicy("upload", c => RateLimitPartition.GetTokenBucketLimiter(Who(c),
        _ => new TokenBucketRateLimiterOptions { TokenLimit = apiBurst + 100, TokensPerPeriod = apiPerSecond + 10, ReplenishmentPeriod = TimeSpan.FromSeconds(1), QueueLimit = 0 }));
});
builder.Services.Configure<ForwardedHeadersOptions>(o =>
{
    o.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
    o.KnownIPNetworks.Clear();
    o.KnownProxies.Clear(); // only our own nginx can reach Kestrel (bound to loopback)
});
builder.WebHost.ConfigureKestrel(k =>
{
    k.AddServerHeader = false;
    k.Limits.MaxRequestBodySize = 1024 * 1024; // endpoints that take files raise it explicitly
    k.Limits.MaxRequestHeadersTotalSize = 32 * 1024;
    k.Limits.RequestHeadersTimeout = TimeSpan.FromSeconds(20);
    k.Limits.MinRequestBodyDataRate = new Microsoft.AspNetCore.Server.Kestrel.Core.MinDataRate(1024, TimeSpan.FromSeconds(30));
});

var app = builder.Build();

app.UseExceptionHandler(e => e.Run(async ctx =>
{
    var ex = ctx.Features.Get<IExceptionHandlerFeature>()?.Error;
    if (ex is ApiError api)
    {
        ctx.Response.StatusCode = api.Status;
        await ctx.Response.WriteAsJsonAsync(new { error = api.Message });
        return;
    }
    if (ex is not (OperationCanceledException or BadHttpRequestException))
        ctx.RequestServices.GetRequiredService<ILogger<Program>>().LogError(ex, "Unhandled error on {Path}", ctx.Request.Path);
    ctx.Response.StatusCode = ex is BadHttpRequestException b ? b.StatusCode : 500;
    await ctx.Response.WriteAsJsonAsync(new { error = ctx.Response.StatusCode == 500 ? "Something went wrong." : "Bad request." });
}));
app.UseForwardedHeaders();
app.Use(async (ctx, next) =>
{
    var h = ctx.Response.Headers;
    h["X-Content-Type-Options"] = "nosniff";
    h["X-Frame-Options"] = "DENY";
    h["Referrer-Policy"] = "no-referrer";
    h["Cross-Origin-Opener-Policy"] = "same-origin";
    h["Permissions-Policy"] = "camera=(), geolocation=(), microphone=(self), display-capture=(self)";
    if (!ctx.Request.Path.StartsWithSegments("/api") && !ctx.Request.Path.StartsWithSegments("/hub"))
        h["Content-Security-Policy"] =
            "default-src 'self'; script-src 'self' 'wasm-unsafe-eval' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; " +
            "img-src 'self' data: blob:; media-src 'self' blob:; font-src 'self' data: https://fonts.gstatic.com; worker-src 'self' blob:; " +
            "connect-src 'self' blob: data: wss: ws: https://fonts.gstatic.com; frame-ancestors 'none'; base-uri 'self'; form-action 'self'";
    else
        h["Cache-Control"] = "no-store"; // API answers are per-user; never let anything cache them
    await next();
});
app.UseRateLimiter();
app.UseAuthentication();
app.UseAuthorization();
app.UseDefaultFiles();
// Flutter web build is deployed into wwwroot. no-cache = revalidate with ETag every time, so a
// new version is picked up immediately and unchanged files still cost only a 304.
app.UseStaticFiles(new StaticFileOptions { OnPrepareResponse = c => c.Context.Response.Headers.CacheControl = "no-cache" });

using (var scope = app.Services.CreateScope())
{
    var db = scope.ServiceProvider.GetRequiredService<NyxDb>();
    db.Database.EnsureCreated();
    // EnsureCreated does not add tables to an existing database, so newer tables are created here when missing.
    db.Database.ExecuteSqlRaw("""CREATE TABLE IF NOT EXISTS "Relations" ("UserId" TEXT NOT NULL, "TargetId" TEXT NOT NULL, "Kind" INTEGER NOT NULL, "CreatedAt" TEXT NOT NULL, CONSTRAINT "PK_Relations" PRIMARY KEY ("UserId","TargetId"));""");
    db.Database.ExecuteSqlRaw("""CREATE INDEX IF NOT EXISTS "IX_Relations_TargetId" ON "Relations" ("TargetId");""");
    db.Database.ExecuteSqlRaw("PRAGMA journal_mode=WAL;");
    app.Services.GetRequiredService<SessionService>().LoadRevoked(db);
    if (!db.Users.Any() && !db.Invites.Any(i => i.GuildId == null && i.ExpiresAt > DateTime.UtcNow))
    {
        var code = Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(6));
        db.Invites.Add(new Invite { Code = code, MaxUses = 1, ExpiresAt = DateTime.UtcNow.AddDays(7) });
        db.SaveChanges();
        app.Logger.LogWarning("No users yet. First-user invite code: {Code}", code);
    }
}

var realtime = app.Services.GetRequiredService<Realtime>();
app.Services.GetRequiredService<SessionService>().SessionRevoked += (_, sessionId) => realtime.Disconnect(sessionId);

AuthApi.Map(app);
UsersApi.Map(app);
GuildsApi.Map(app);
ChannelsApi.Map(app);
FriendsApi.Map(app);
BlobsApi.Map(app, app.Configuration, blobStore);
RtcApi.Map(app, app.Configuration);
var downloadsDir = Path.GetFullPath(app.Configuration["Downloads:Path"] ?? Path.Combine(dataDir, "..", "downloads"));
DownloadsApi.Map(app, downloadsDir);
UpdatesApi.Map(app, downloadsDir);
GifsApi.Map(app, app.Configuration);
app.MapHub<NyxHub>("/hub");
app.MapGet("/health", () => "ok");
app.MapFallbackToFile("index.html", new StaticFileOptions { OnPrepareResponse = c => c.Context.Response.Headers.CacheControl = "no-cache" });

app.Run();

public partial class Program;

/// <summary>Removes what is no longer needed: dead sessions, stale invites, abandoned uploads, old audit rows.</summary>
sealed class Janitor(IServiceScopeFactory scopes, BlobStore blobs, ILogger<Janitor> log) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stop)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromHours(1));
        do
        {
            try
            {
                using var scope = scopes.CreateScope();
                var db = scope.ServiceProvider.GetRequiredService<NyxDb>();
                var now = DateTime.UtcNow;
                db.Sessions.RemoveRange(db.Sessions.Where(s => s.ExpiresAt < now.AddDays(-7) || (s.Revoked && s.LastSeen < now.AddDays(-30))));
                db.Invites.RemoveRange(db.Invites.Where(i => i.ExpiresAt < now.AddDays(-1)));
                db.Audit.RemoveRange(db.Audit.Where(a => a.At < now.AddDays(-90)));
                await db.SaveChangesAsync(stop);
                foreach (var d in Directory.GetDirectories(blobs.TmpDir).Where(d => Directory.GetLastWriteTimeUtc(d) < now.AddDays(-1)))
                    Directory.Delete(d, true);
            }
            catch (Exception e) when (e is not OperationCanceledException) { log.LogWarning(e, "Cleanup failed"); }
        } while (await timer.WaitForNextTickAsync(stop));
    }
}
