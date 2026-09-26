using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;

namespace Nyx.Server.Tests;

public class BlobTests : IClassFixture<TestApp>
{
    readonly TestApp app;
    public BlobTests(TestApp app) { this.app = app; }

    const int Channel = 0, Guild = 1, Profile = 2;

    static async Task<HttpStatusCode> PutPart(TestUser u, Guid upload, int part, byte[] data)
    {
        var res = await u.Http.PutAsync($"/api/blobs/uploads/{upload}/{part}", new ByteArrayContent(data) { Headers = { ContentType = new MediaTypeHeaderValue("application/octet-stream") } });
        return res.StatusCode;
    }

    async Task<(HttpStatusCode Status, Guid Id)> Start(TestUser u, int scope, Guid scopeId, long size)
    {
        var (s, b) = await u.Post("/api/blobs/uploads", new { scope, scopeId, size });
        return (s, s == HttpStatusCode.OK ? b.GetProperty("id").GetGuid() : Guid.Empty);
    }

    async Task<Guid> Upload(TestUser u, int scope, Guid scopeId, byte[] data, int parts = 2)
    {
        var (s, id) = await Start(u, scope, scopeId, data.Length);
        Assert.Equal(HttpStatusCode.OK, s);
        var size = (int)Math.Ceiling(data.Length / (double)parts);
        var n = 0;
        for (var i = 0; i < data.Length; i += size) Assert.Equal(HttpStatusCode.OK, await PutPart(u, id, n++, data[i..Math.Min(data.Length, i + size)]));
        var (cs, cb) = await u.Post($"/api/blobs/uploads/{id}/complete", new { parts = n });
        Assert.True(cs == HttpStatusCode.OK, $"complete: {cs} {cb}");
        return id;
    }

    async Task<(TestUser A, TestUser B, Guid Dm)> Pair()
    {
        var a = await app.Register("ba"); var b = await app.Register("bb");
        var (_, r) = await a.Post("/api/dms", new { userIds = new[] { b.Id }, keys = new[] { new { userId = a.Id, @sealed = Fake.Blob() }, new { userId = b.Id, @sealed = Fake.Blob() } } });
        return (a, b, r.GetProperty("channel").GetProperty("id").GetGuid());
    }

    [Fact]
    public async Task Parts_are_stitched_together_and_only_members_can_download()
    {
        var (a, b, dm) = await Pair();
        var eve = await app.Register("bx");
        var data = RandomNumberGenerator.GetBytes(120_000);
        var id = await Upload(a, Channel, dm, data, parts: 3);

        var res = await b.Http.GetAsync($"/api/blobs/{id}");
        Assert.Equal(HttpStatusCode.OK, res.StatusCode);
        Assert.Equal(data, await res.Content.ReadAsByteArrayAsync());
        Assert.Contains("private", res.Headers.CacheControl!.ToString());

        var req = new HttpRequestMessage(HttpMethod.Get, $"/api/blobs/{id}") { Headers = { Range = new RangeHeaderValue(10, 19) } };
        var part = await b.Http.SendAsync(req);
        Assert.Equal(HttpStatusCode.PartialContent, part.StatusCode);
        Assert.Equal(data[10..20], await part.Content.ReadAsByteArrayAsync());

        Assert.Equal(HttpStatusCode.NotFound, (await eve.Http.GetAsync($"/api/blobs/{id}")).StatusCode); // not even a hint that it exists
        Assert.Equal(HttpStatusCode.NotFound, (await eve.Http.GetAsync($"/api/blobs/{Guid.NewGuid()}")).StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, (await app.CreateClient().GetAsync($"/api/blobs/{id}")).StatusCode);
    }

    [Fact]
    public async Task Parts_can_arrive_out_of_order_and_be_retried()
    {
        var (a, _, dm) = await Pair();
        var data = RandomNumberGenerator.GetBytes(90_000);
        var (_, id) = await Start(a, Channel, dm, data.Length);
        Assert.Equal(HttpStatusCode.OK, await PutPart(a, id, 2, data[60_000..]));
        Assert.Equal(HttpStatusCode.OK, await PutPart(a, id, 0, data[..30_000]));
        Assert.Equal(HttpStatusCode.OK, await PutPart(a, id, 1, RandomNumberGenerator.GetBytes(30_000))); // bad attempt...
        Assert.Equal(HttpStatusCode.OK, await PutPart(a, id, 1, data[30_000..60_000]));                    // ...replaced by the retry
        var (s, _) = await a.Post($"/api/blobs/uploads/{id}/complete", new { parts = 3 });
        Assert.Equal(HttpStatusCode.OK, s);
        Assert.Equal(data, await (await a.Http.GetAsync($"/api/blobs/{id}")).Content.ReadAsByteArrayAsync());
    }

    [Fact]
    public async Task Declared_size_is_a_hard_limit_and_must_match_on_completion()
    {
        var (a, _, dm) = await Pair();
        var (_, id) = await Start(a, Channel, dm, 1000);
        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, await PutPart(a, id, 0, new byte[1001])); // more than declared
        Assert.Equal(HttpStatusCode.OK, await PutPart(a, id, 0, new byte[600]));
        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, await PutPart(a, id, 1, new byte[500]));
        Assert.Equal(HttpStatusCode.OK, await PutPart(a, id, 1, new byte[300]));
        var (s, _) = await a.Post($"/api/blobs/uploads/{id}/complete", new { parts = 2 }); // 900 != 1000
        Assert.Equal(HttpStatusCode.BadRequest, s);
        (s, _) = await a.Post($"/api/blobs/uploads/{id}/complete", new { parts = 3 }); // part 2 missing
        Assert.Equal(HttpStatusCode.BadRequest, s);
        Assert.Equal(HttpStatusCode.NotFound, (await a.Http.GetAsync($"/api/blobs/{id}")).StatusCode); // nothing was published
    }

    [Fact]
    public async Task Uploads_belong_to_the_person_who_started_them()
    {
        var (a, b, dm) = await Pair();
        var (_, id) = await Start(a, Channel, dm, 100);
        Assert.Equal(HttpStatusCode.NotFound, await PutPart(b, id, 0, new byte[100]));
        Assert.Equal(HttpStatusCode.NotFound, (await b.Post($"/api/blobs/uploads/{id}/complete", new { parts = 1 })).Status);
        Assert.Equal(HttpStatusCode.NotFound, (await b.Delete($"/api/blobs/uploads/{id}")).Status);
        Assert.Equal(HttpStatusCode.NoContent, (await a.Delete($"/api/blobs/uploads/{id}")).Status);
    }

    [Fact]
    public async Task You_can_only_attach_to_channels_you_belong_to_and_may_attach_in()
    {
        var (a, _, dm) = await Pair();
        var eve = await app.Register("be");
        Assert.Equal(HttpStatusCode.NotFound, (await Start(eve, Channel, dm, 100)).Status);

        var owner = await app.Register("bo");
        var g = await owner.CreateGuild();
        var m = await owner.InviteNewUser(g.Id, "bm");
        Assert.Equal(HttpStatusCode.OK, (await Start(m, Channel, g.General, 100)).Status);
        // Take AttachFiles away from @everyone: members are refused, the owner is not.
        var boot = await owner.Bootstrap();
        var everyone = boot.GetProperty("guilds")[0].GetProperty("roles").EnumerateArray().First(r => r.GetProperty("isEveryone").GetBoolean()).GetProperty("id").GetGuid();
        await owner.Put($"/api/guilds/{g.Id}/roles/{everyone}", new { metaCipher = Fake.Blob(), permissions = 3L, position = 0 });
        Assert.Equal(HttpStatusCode.Forbidden, (await Start(m, Channel, g.General, 100)).Status);
        Assert.Equal(HttpStatusCode.OK, (await Start(owner, Channel, g.General, 100)).Status);
    }

    [Fact]
    public async Task Size_limits_and_storage_quota()
    {
        var (a, _, dm) = await Pair();
        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, (await Start(a, Channel, dm, 600_000)).Status); // over the per-file cap (500 KB in tests)
        Assert.Equal(HttpStatusCode.BadRequest, (await Start(a, 9, dm, 100)).Status);                      // bad scope
        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, (await Start(a, Channel, dm, 0)).Status);
        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, (await Start(a, Profile, a.Id, 13 * 1024 * 1024)).Status); // avatars/banners are capped at 12 MB

        await Upload(a, Channel, dm, new byte[450_000]);
        await Upload(a, Channel, dm, new byte[450_000]);
        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, (await Start(a, Channel, dm, 450_000)).Status); // 1 MB quota in tests
    }

    [Fact]
    public async Task Profile_pictures_only_for_yourself_but_anyone_signed_in_can_fetch_them()
    {
        var a = await app.Register("pa"); var b = await app.Register("pb");
        Assert.Equal(HttpStatusCode.Forbidden, (await Start(b, Profile, a.Id, 100)).Status);
        var id = await Upload(a, Profile, a.Id, RandomNumberGenerator.GetBytes(5000), parts: 1);
        Assert.Equal(HttpStatusCode.OK, (await b.Http.GetAsync($"/api/blobs/{id}")).StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, (await app.CreateClient().GetAsync($"/api/blobs/{id}")).StatusCode);
    }

    [Fact]
    public async Task Deleting_blobs_needs_ownership_or_authority_and_removes_the_file()
    {
        var (a, b, dm) = await Pair();
        var id = await Upload(a, Channel, dm, new byte[2000], parts: 1);
        Assert.Equal(HttpStatusCode.Forbidden, (await b.Delete($"/api/blobs/{id}")).Status);
        var path = Path.Combine(app.DataDir, "blobs", id.ToString("N"));
        Assert.True(File.Exists(path));
        Assert.Equal(HttpStatusCode.NoContent, (await a.Delete($"/api/blobs/{id}")).Status);
        Assert.False(File.Exists(path));
        Assert.Equal(HttpStatusCode.NotFound, (await a.Http.GetAsync($"/api/blobs/{id}")).StatusCode);
    }

    [Fact]
    public async Task Server_assets_need_permission_and_a_blob_that_belongs_to_that_server()
    {
        var owner = await app.Register("so");
        var g = await owner.CreateGuild();
        var member = await owner.InviteNewUser(g.Id, "sm");
        Assert.Equal(HttpStatusCode.Forbidden, (await Start(member, Guild, g.Id, 100)).Status);

        var blob = await Upload(owner, Guild, g.Id, new byte[3000], parts: 1);
        Assert.Equal(HttpStatusCode.Forbidden, (await member.Post($"/api/guilds/{g.Id}/assets", new { kind = "emoji", metaCipher = Fake.Blob(), blobId = blob })).Status);
        Assert.Equal(HttpStatusCode.BadRequest, (await owner.Post($"/api/guilds/{g.Id}/assets", new { kind = "virus", metaCipher = Fake.Blob(), blobId = blob })).Status);
        Assert.Equal(HttpStatusCode.BadRequest, (await owner.Post($"/api/guilds/{g.Id}/assets", new { kind = "emoji", metaCipher = Fake.Blob(), blobId = Guid.NewGuid() })).Status);
        var (s, a) = await owner.Post($"/api/guilds/{g.Id}/assets", new { kind = "emoji", metaCipher = Fake.Blob(), blobId = blob });
        Assert.Equal(HttpStatusCode.OK, s);

        Assert.Equal(HttpStatusCode.OK, (await member.Http.GetAsync($"/api/blobs/{blob}")).StatusCode); // members see the emoji
        Assert.Equal(HttpStatusCode.NotFound, (await (await app.Register("sx")).Http.GetAsync($"/api/blobs/{blob}")).StatusCode);

        Assert.Equal(HttpStatusCode.NoContent, (await owner.Delete($"/api/guilds/{g.Id}/assets/{a.GetProperty("id").GetGuid()}")).Status);
        Assert.Equal(HttpStatusCode.NotFound, (await owner.Http.GetAsync($"/api/blobs/{blob}")).StatusCode);
    }

    [Fact]
    public async Task Deleting_a_channel_removes_its_attachments_from_disk()
    {
        var owner = await app.Register("dc");
        var g = await owner.CreateGuild();
        var blob = await Upload(owner, Channel, g.General, new byte[1500], parts: 1);
        var path = Path.Combine(app.DataDir, "blobs", blob.ToString("N"));
        Assert.True(File.Exists(path));
        Assert.Equal(HttpStatusCode.NoContent, (await owner.Delete($"/api/channels/{g.General}")).Status);
        Assert.False(File.Exists(path));
    }
}
