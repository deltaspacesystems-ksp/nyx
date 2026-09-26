using System.Net;
using System.Text.Json;
using Nyx.Server.Security;

namespace Nyx.Server.Tests;

public class AuthTests : IClassFixture<TestApp>
{
    readonly TestApp app;
    public AuthTests(TestApp app) { this.app = app; }

    Task<(HttpStatusCode Status, JsonElement Body)> Login(string name, string authKey, object? extra = null)
    {
        var http = app.CreateClient();
        var body = new Dictionary<string, object?> { ["username"] = name, ["authKey"] = authKey };
        if (extra is not null) foreach (var p in extra.GetType().GetProperties()) body[p.Name] = p.GetValue(extra);
        return Nyx.Server.Tests.Http.Send(http, HttpMethod.Post, "/api/auth/login", body);
    }

    [Fact]
    public async Task Api_requires_a_token()
    {
        var (s, _) = await Nyx.Server.Tests.Http.Send(app.CreateClient(), HttpMethod.Get, "/api/bootstrap");
        Assert.Equal(HttpStatusCode.Unauthorized, s);
        var (s2, _) = await Nyx.Server.Tests.Http.Send(app.CreateClient(), HttpMethod.Get, "/api/channels/" + Guid.NewGuid() + "/messages");
        Assert.Equal(HttpStatusCode.Unauthorized, s2);
    }

    [Fact]
    public async Task Register_needs_a_valid_invite_and_sane_key_material()
    {
        
        var http = app.CreateClient();
        object Body(string name, string invite, string? key = null) => new
        {
            username = name, displayName = name, kdfSalt = Fake.Salt(), authKey = key ?? Fake.Key(),
            identityPublicKey = Fake.Key(), agreementPublicKey = Fake.Key(), encryptedKeyBackup = Fake.Blob(64), inviteCode = invite,
        };

        var (s, _) = await Nyx.Server.Tests.Http.Send(http, HttpMethod.Post, "/api/auth/register", Body("nobody1", "NOTACODE"));
        Assert.Equal(HttpStatusCode.BadRequest, s);

        var invite = await app.Admin().InstanceInvite();
        (s, _) = await Nyx.Server.Tests.Http.Send(http, HttpMethod.Post, "/api/auth/register", Body("x", invite)); // username too short
        Assert.Equal(HttpStatusCode.BadRequest, s);
        (s, _) = await Nyx.Server.Tests.Http.Send(http, HttpMethod.Post, "/api/auth/register", Body("bad name!", invite));
        Assert.Equal(HttpStatusCode.BadRequest, s);
        (s, _) = await Nyx.Server.Tests.Http.Send(http, HttpMethod.Post, "/api/auth/register", Body("okname", invite, "not-base64!!"));
        Assert.Equal(HttpStatusCode.BadRequest, s);

        (s, _) = await Nyx.Server.Tests.Http.Send(http, HttpMethod.Post, "/api/auth/register", Body("okname", invite));
        Assert.Equal(HttpStatusCode.OK, s);
        (s, _) = await Nyx.Server.Tests.Http.Send(http, HttpMethod.Post, "/api/auth/register", Body("second", invite)); // single use
        Assert.Equal(HttpStatusCode.BadRequest, s);
    }

    [Fact]
    public async Task Only_the_instance_admin_can_create_registration_invites()
    {
        var admin = app.Admin();
        var other = await app.Register("plain");
        Assert.Equal(HttpStatusCode.Forbidden, (await other.Post("/api/invites")).Status);
        Assert.Equal(HttpStatusCode.OK, (await admin.Post("/api/invites")).Status);
    }

    [Fact]
    public async Task Refresh_rotates_and_reuse_of_an_old_token_kills_the_session()
    {
        var u = await app.Register("rot");
        var oldRefresh = u.Refresh;
        var oldAccess = u.Access;

        var (s, b) = await u.Post("/api/auth/refresh", new { refreshToken = oldRefresh });
        Assert.Equal(HttpStatusCode.OK, s);
        var newRefresh = b.GetProperty("refreshToken").GetString()!;
        Assert.NotEqual(oldRefresh, newRefresh);

        // Replaying the already-used token means it leaked: everything for that session dies.
        (s, _) = await u.Post("/api/auth/refresh", new { refreshToken = oldRefresh });
        Assert.Equal(HttpStatusCode.Unauthorized, s);
        (s, _) = await u.Post("/api/auth/refresh", new { refreshToken = newRefresh });
        Assert.Equal(HttpStatusCode.Unauthorized, s);
        u.Access = oldAccess; u.Apply();
        Assert.Equal(HttpStatusCode.Unauthorized, (await u.Get("/api/bootstrap")).Status);
    }

    [Fact]
    public async Task Garbage_refresh_tokens_are_rejected()
    {
        var u = await app.Register("garb");
        foreach (var t in new[] { "", "x", "a.b", Guid.NewGuid().ToString("N") + ".AAAA", "....", new string('z', 5000) })
            Assert.Equal(HttpStatusCode.Unauthorized, (await u.Post("/api/auth/refresh", new { refreshToken = t })).Status);
    }

    [Fact]
    public async Task Logout_revokes_the_access_token_immediately()
    {
        var u = await app.Register("bye");
        Assert.Equal(HttpStatusCode.OK, (await u.Get("/api/bootstrap")).Status);
        Assert.Equal(HttpStatusCode.NoContent, (await u.Post("/api/auth/logout")).Status);
        Assert.Equal(HttpStatusCode.Unauthorized, (await u.Get("/api/bootstrap")).Status);
    }

    [Fact]
    public async Task Five_wrong_passwords_lock_the_account_for_a_while()
    {
        var u = await app.Register("lock");
        for (var i = 0; i < 5; i++)
            Assert.Equal(HttpStatusCode.Unauthorized, (await Login(u.Name, Fake.Key())).Status);
        var (s, b) = await Login(u.Name, u.AuthKey); // even the right password is refused now
        Assert.Equal(HttpStatusCode.TooManyRequests, s);
        Assert.Contains("try again", b.GetProperty("error").GetString(), StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task Login_does_not_reveal_whether_a_username_exists()
    {
        var u = await app.Register("real");
        var (s1, b1) = await Login(u.Name, Fake.Key());
        var (s2, b2) = await Login("does-not-exist-" + Guid.NewGuid().ToString("N")[..6], Fake.Key());
        Assert.Equal(s1, s2);
        Assert.Equal(b1.GetProperty("error").GetString(), b2.GetProperty("error").GetString());

        // Unknown users still get a salt, and it is stable (a random one would give them away).
        var http = app.CreateClient();
        var ghost = "ghost" + Guid.NewGuid().ToString("N")[..6];
        var (_, a) = await Nyx.Server.Tests.Http.Send(http, HttpMethod.Get, $"/api/auth/salt?username={ghost}");
        var (_, c) = await Nyx.Server.Tests.Http.Send(http, HttpMethod.Get, $"/api/auth/salt?username={ghost}");
        Assert.Equal(a.GetProperty("salt").GetString(), c.GetProperty("salt").GetString());
    }

    [Fact]
    public async Task Two_factor_login_and_recovery_codes()
    {
        var u = await app.Register("tfa");
        var (s, b) = await u.Post("/api/auth/totp/setup");
        Assert.Equal(HttpStatusCode.OK, s);
        var secret = b.GetProperty("secret").GetString()!;

        (s, _) = await u.Post("/api/auth/totp/enable", new { code = "000000" });
        Assert.Equal(HttpStatusCode.BadRequest, s);
        (s, b) = await u.Post("/api/auth/totp/enable", new { code = Totp.Generate(secret) });
        Assert.Equal(HttpStatusCode.OK, s);
        var recovery = b.GetProperty("recoveryCodes").EnumerateArray().Select(e => e.GetString()!).ToList();
        Assert.Equal(10, recovery.Count);

        (s, b) = await Login(u.Name, u.AuthKey);
        Assert.Equal(HttpStatusCode.Unauthorized, s);
        Assert.True(b.GetProperty("twoFactor").GetBoolean());

        (s, _) = await Login(u.Name, u.AuthKey, new { totp = "123456" });
        Assert.Equal(HttpStatusCode.Unauthorized, s);

        // The setup code was already spent; the next 30 s step is accepted, and only once (no replay).
        var next = Totp.Generate(secret, DateTimeOffset.UtcNow.AddSeconds(30));
        (s, _) = await Login(u.Name, u.AuthKey, new { totp = next });
        Assert.Equal(HttpStatusCode.OK, s);
        (s, _) = await Login(u.Name, u.AuthKey, new { totp = next });
        Assert.Equal(HttpStatusCode.Unauthorized, s);

        (s, _) = await Login(u.Name, u.AuthKey, new { recoveryCode = recovery[0] });
        Assert.Equal(HttpStatusCode.OK, s);
        (s, _) = await Login(u.Name, u.AuthKey, new { recoveryCode = recovery[0] }); // single use
        Assert.Equal(HttpStatusCode.Unauthorized, s);
    }

    [Fact]
    public async Task Changing_the_password_signs_out_other_devices()
    {
        var u = await app.Register("pw");
        var (_, login) = await Login(u.Name, u.AuthKey);
        var other = login.GetProperty("accessToken").GetString()!;

        var newKey = Fake.Key();
        var (s, _) = await u.Post("/api/auth/password", new { oldAuthKey = Fake.Key(), newAuthKey = newKey, newKdfSalt = Fake.Salt(), newEncryptedKeyBackup = Fake.Blob(64) });
        Assert.Equal(HttpStatusCode.Unauthorized, s); // wrong current password

        (s, _) = await u.Post("/api/auth/password", new { oldAuthKey = u.AuthKey, newAuthKey = newKey, newKdfSalt = Fake.Salt(), newEncryptedKeyBackup = Fake.Blob(64) });
        Assert.Equal(HttpStatusCode.NoContent, s);

        Assert.Equal(HttpStatusCode.OK, (await u.Get("/api/bootstrap")).Status); // this device stays signed in
        var http = app.CreateClient();
        http.DefaultRequestHeaders.Authorization = new("Bearer", other);
        Assert.Equal(HttpStatusCode.Unauthorized, (await Nyx.Server.Tests.Http.Send(http, HttpMethod.Get, "/api/bootstrap")).Status);

        Assert.Equal(HttpStatusCode.Unauthorized, (await Login(u.Name, u.AuthKey)).Status); // old password gone
        Assert.Equal(HttpStatusCode.OK, (await Login(u.Name, newKey)).Status);
    }

    [Fact]
    public async Task Sessions_can_be_listed_and_revoked_but_only_your_own()
    {
        var a = await app.Register("sa");
        var b = await app.Register("sb");
        var (_, login) = await Login(a.Name, a.AuthKey);
        var second = login.GetProperty("accessToken").GetString()!;

        var (s, list) = await a.Get("/api/auth/sessions");
        Assert.Equal(HttpStatusCode.OK, s);
        Assert.Equal(2, list.GetArrayLength());
        var other = list.EnumerateArray().First(x => !x.GetProperty("current").GetBoolean()).GetProperty("id").GetGuid();

        Assert.Equal(HttpStatusCode.NotFound, (await b.Delete($"/api/auth/sessions/{other}")).Status); // not b's session
        Assert.Equal(HttpStatusCode.NoContent, (await a.Delete($"/api/auth/sessions/{other}")).Status);

        var http = app.CreateClient();
        http.DefaultRequestHeaders.Authorization = new("Bearer", second);
        Assert.Equal(HttpStatusCode.Unauthorized, (await Nyx.Server.Tests.Http.Send(http, HttpMethod.Get, "/api/bootstrap")).Status);
    }
}
