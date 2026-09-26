using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using Nyx.Server.Data;

namespace Nyx.Server.Tests;

/// <summary>A real server (real pipeline, real SQLite in a temp folder), hosted in memory.</summary>
public class TestApp : WebApplicationFactory<Program>, IAsyncLifetime
{
    public string DataDir { get; } = Path.Combine(Path.GetTempPath(), "nyx-test-" + Guid.NewGuid().ToString("N"));
    public string DownloadsDir => DataDir + "-downloads";

    protected override void ConfigureWebHost(IWebHostBuilder b)
    {
        b.UseEnvironment("Testing");
        b.UseSetting("Data:Path", DataDir);
        b.UseSetting("Downloads:Path", DataDir + "-downloads");
        b.UseSetting("RateLimits:AuthPerMinute", "100000");
        b.UseSetting("RateLimits:ApiBurst", "1000000");
        b.UseSetting("RateLimits:ApiPerSecond", "1000000");
        b.UseSetting("Limits:UserQuotaBytes", "1000000");
        b.UseSetting("Limits:MaxBlobBytes", "500000");
        b.UseSetting("Logging:LogLevel:Default", "Warning");
    }

    /// <summary>The first-user invite the server prints at startup.</summary>
    public string BootstrapInvite()
    {
        using var scope = Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<NyxDb>();
        return db.Invites.First(i => i.GuildId == null).Code;
    }

    public async Task<T> Db<T>(Func<NyxDb, Task<T>> f)
    {
        using var scope = Services.CreateScope();
        return await f(scope.ServiceProvider.GetRequiredService<NyxDb>());
    }

    static int _n;
    public static string UniqueName(string prefix) => $"{prefix}{Interlocked.Increment(ref _n)}{Random.Shared.Next(100, 999)}";

    TestUser? _admin;

    /// <summary>A dedicated instance admin (the first account), so tests that kill sessions never break invites.</summary>
    public TestUser Admin() => _admin ?? throw new InvalidOperationException("Admin not created yet.");

    public async Task InitializeAsync() => _admin = await RegisterWith("admin", BootstrapInvite());
    Task IAsyncLifetime.DisposeAsync() => Task.CompletedTask;

    public async Task<TestUser> Register(string prefix, string? invite = null) =>
        await RegisterWith(prefix, invite ?? await Admin().InstanceInvite());

    async Task<TestUser> RegisterWith(string prefix, string invite)
    {
        var name = UniqueName(prefix);
        var http = CreateClient();
        var authKey = Fake.Key();
        var (status, body) = await Http.Send(http, HttpMethod.Post, "/api/auth/register", new
        {
            username = name, displayName = name, kdfSalt = Fake.Salt(), authKey,
            identityPublicKey = Fake.Key(), agreementPublicKey = Fake.Key(), encryptedKeyBackup = Fake.Blob(64), inviteCode = invite,
        });
        Assert.True(status == HttpStatusCode.OK, $"register failed: {status} {body}");
        var u = new TestUser(this, http, name, authKey)
        {
            Id = body.GetProperty("user").GetProperty("id").GetGuid(),
            Access = body.GetProperty("accessToken").GetString()!,
            Refresh = body.GetProperty("refreshToken").GetString()!,
        };
        u.Apply();
        return u;
    }
}

public static class Http
{
    public static async Task<(HttpStatusCode Status, JsonElement Body)> Send(HttpClient http, HttpMethod method, string url, object? body = null)
    {
        var req = new HttpRequestMessage(method, url);
        if (body is not null) req.Content = JsonContent.Create(body);
        var res = await http.SendAsync(req);
        var text = await res.Content.ReadAsStringAsync();
        JsonElement json = default;
        if (!string.IsNullOrWhiteSpace(text) && (text.TrimStart().StartsWith('{') || text.TrimStart().StartsWith('[')))
            json = JsonDocument.Parse(text).RootElement.Clone();
        return (res.StatusCode, json);
    }
}

public static class Fake
{
    public static string Key() => Convert.ToBase64String(RandomNumberGenerator.GetBytes(32));
    public static string Salt() => Convert.ToBase64String(RandomNumberGenerator.GetBytes(16));
    public static string Blob(int n = 48) => Convert.ToBase64String(RandomNumberGenerator.GetBytes(n));
}

public class TestUser(TestApp app, HttpClient http, string name, string authKey)
{
    public TestApp App { get; } = app;
    public HttpClient Http { get; } = http;
    public string Name { get; } = name;
    public string AuthKey { get; } = authKey;
    public Guid Id { get; set; }
    public string Access { get; set; } = "";
    public string Refresh { get; set; } = "";

    public void Apply() => Http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", Access);

    public Task<(HttpStatusCode Status, JsonElement Body)> Get(string url) => Nyx.Server.Tests.Http.Send(Http, HttpMethod.Get, url);
    public Task<(HttpStatusCode Status, JsonElement Body)> Post(string url, object? body = null) => Nyx.Server.Tests.Http.Send(Http, HttpMethod.Post, url, body ?? new { });
    public Task<(HttpStatusCode Status, JsonElement Body)> Put(string url, object? body = null) => Nyx.Server.Tests.Http.Send(Http, HttpMethod.Put, url, body ?? new { });
    public Task<(HttpStatusCode Status, JsonElement Body)> Delete(string url) => Nyx.Server.Tests.Http.Send(Http, HttpMethod.Delete, url);

    public async Task<string> InstanceInvite()
    {
        var (s, b) = await Post("/api/invites");
        Assert.Equal(HttpStatusCode.OK, s);
        return b.GetProperty("code").GetString()!;
    }

    // ---- higher level helpers used by many tests ----

    public record GuildInfo(Guid Id, Guid General, Guid Voice, Guid Category);

    public async Task<GuildInfo> CreateGuild()
    {
        var general = Guid.NewGuid();
        var voice = Guid.NewGuid();
        var cat = Guid.NewGuid();
        var (s, b) = await Post("/api/guilds", new
        {
            metaCipher = Fake.Blob(), everyoneMeta = Fake.Blob(), ownerKey = Fake.Blob(),
            channels = new object[]
            {
                new { id = cat, kind = 2, metaCipher = Fake.Blob(), position = 0 },
                new { id = general, kind = 0, parentId = cat, metaCipher = Fake.Blob(), position = 1, keys = new[] { new { userId = Id, @sealed = Fake.Blob() } } },
                new { id = voice, kind = 1, parentId = cat, metaCipher = Fake.Blob(), position = 2, keys = new[] { new { userId = Id, @sealed = Fake.Blob() } } },
            },
        });
        Assert.True(s == HttpStatusCode.OK, $"create guild failed: {s} {b}");
        return new GuildInfo(b.GetProperty("guild").GetProperty("id").GetGuid(), general, voice, cat);
    }

    public async Task<string> GuildInvite(Guid guild, int maxUses = 0)
    {
        var (s, b) = await Post($"/api/guilds/{guild}/invites", new { maxUses, expiresHours = 24 });
        Assert.Equal(HttpStatusCode.OK, s);
        return b.GetProperty("code").GetString()!;
    }

    /// <summary>Registers a brand-new account through a guild invite (joins the guild on the way in).</summary>
    public async Task<TestUser> InviteNewUser(Guid guild, string prefix = "u") => await App.Register(prefix, await GuildInvite(guild, 0));

    public Task<(HttpStatusCode Status, JsonElement Body)> Send(Guid channel, int keyVersion = 1, long? replyTo = null) =>
        Post($"/api/channels/{channel}/messages", new { ciphertext = Fake.Blob(80), keyVersion, replyTo });

    public async Task<long> SendOk(Guid channel)
    {
        var (s, b) = await Send(channel);
        Assert.True(s == HttpStatusCode.OK, $"send failed: {s} {b}");
        return b.GetProperty("id").GetInt64();
    }

    /// <summary>Seals the current key of a scope to a member (as an existing member's client would).</summary>
    public Task<(HttpStatusCode Status, JsonElement Body)> SealTo(Guid scope, Guid user, int version = 1) =>
        Post("/api/keys", new { shares = new[] { new { scopeId = scope, version, userId = user, @sealed = Fake.Blob() } } });

    public async Task<JsonElement> Bootstrap()
    {
        var (s, b) = await Get("/api/bootstrap");
        Assert.Equal(HttpStatusCode.OK, s);
        return b;
    }
}
