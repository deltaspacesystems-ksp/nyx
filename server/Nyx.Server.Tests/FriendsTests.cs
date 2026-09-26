using System.Net;
using System.Text.Json;

namespace Nyx.Server.Tests;

public class FriendsTests : IClassFixture<TestApp>
{
    readonly TestApp app;
    public FriendsTests(TestApp app) { this.app = app; }

    static object Keys(params TestUser[] users) => users.Select(u => new { userId = u.Id, @sealed = Fake.Blob() }).ToArray();

    static bool Has(JsonElement rel, string list, Guid id) => rel.GetProperty(list).EnumerateArray().Any(x => x.GetGuid() == id);
    static async Task<JsonElement> Rel(TestUser u) => (await u.Get("/api/friends")).Body;

    [Fact]
    public async Task Request_then_accept_makes_friends()
    {
        var a = await app.Register("fa"); var b = await app.Register("fb");
        var (s, r) = await a.Post("/api/friends", new { username = "@" + b.Name });
        Assert.Equal(HttpStatusCode.OK, s);
        Assert.Equal("pending", r.GetProperty("status").GetString());
        Assert.True(Has(await Rel(a), "outgoing", b.Id));
        Assert.True(Has(await Rel(b), "incoming", a.Id));
        Assert.Equal(HttpStatusCode.NoContent, (await b.Post($"/api/friends/{a.Id}/accept")).Status);
        Assert.True(Has(await Rel(a), "friends", b.Id));
        Assert.True(Has(await Rel(b), "friends", a.Id));
        Assert.False(Has(await Rel(a), "outgoing", b.Id));
        Assert.True(Has((await b.Bootstrap()).GetProperty("relations"), "friends", a.Id));
    }

    [Fact]
    public async Task Crossing_requests_become_friends()
    {
        var a = await app.Register("fc"); var b = await app.Register("fd");
        await a.Post("/api/friends", new { username = b.Name });
        var (_, r) = await b.Post("/api/friends", new { username = a.Name });
        Assert.Equal("friends", r.GetProperty("status").GetString());
        Assert.True(Has(await Rel(a), "friends", b.Id));
    }

    [Fact]
    public async Task Only_the_receiver_can_accept_and_bad_input_is_rejected()
    {
        var a = await app.Register("fe"); var b = await app.Register("ff");
        await a.Post("/api/friends", new { username = b.Name });
        Assert.Equal(HttpStatusCode.NotFound, (await a.Post($"/api/friends/{b.Id}/accept")).Status);
        Assert.Equal(HttpStatusCode.NotFound, (await a.Post("/api/friends", new { username = "nobody-here-xyz" })).Status);
        Assert.Equal(HttpStatusCode.BadRequest, (await a.Post("/api/friends", new { username = a.Name })).Status);
        Assert.Equal(HttpStatusCode.BadRequest, (await a.Post("/api/friends", new { username = "" })).Status);
    }

    [Fact]
    public async Task Unfriend_decline_and_cancel()
    {
        var a = await app.Register("fg"); var b = await app.Register("fh");
        await a.Post("/api/friends", new { username = b.Name });
        Assert.Equal(HttpStatusCode.NoContent, (await b.Delete($"/api/friends/{a.Id}")).Status); // decline
        Assert.False(Has(await Rel(a), "outgoing", b.Id));
        await a.Post("/api/friends", new { username = b.Name });
        await b.Post($"/api/friends/{a.Id}/accept");
        Assert.Equal(HttpStatusCode.NoContent, (await a.Delete($"/api/friends/{b.Id}")).Status); // unfriend
        Assert.False(Has(await Rel(a), "friends", b.Id));
        Assert.False(Has(await Rel(b), "friends", a.Id));
    }

    [Fact]
    public async Task Blocking_removes_the_friendship_and_stops_dms()
    {
        var a = await app.Register("fi"); var b = await app.Register("fj");
        await a.Post("/api/friends", new { username = b.Name });
        await b.Post($"/api/friends/{a.Id}/accept");
        Assert.Equal(HttpStatusCode.NoContent, (await a.Post($"/api/users/{b.Id}/block")).Status);
        Assert.True(Has(await Rel(a), "blocked", b.Id));
        Assert.False(Has(await Rel(a), "friends", b.Id));
        Assert.False(Has(await Rel(b), "friends", a.Id));
        Assert.False(Has(await Rel(b), "blocked", a.Id)); // blocked person is not told

        // Neither side can open a DM, and the blocked one cannot re-request.
        Assert.Equal(HttpStatusCode.Forbidden, (await a.Post("/api/dms", new { userIds = new[] { b.Id }, keys = Keys(a, b) })).Status);
        Assert.Equal(HttpStatusCode.Forbidden, (await b.Post("/api/dms", new { userIds = new[] { a.Id }, keys = Keys(a, b) })).Status);
        Assert.Equal(HttpStatusCode.OK, (await b.Post("/api/friends", new { username = a.Name })).Status);
        Assert.False(Has(await Rel(a), "incoming", b.Id));

        Assert.Equal(HttpStatusCode.NoContent, (await a.Delete($"/api/users/{b.Id}/block")).Status);
        Assert.False(Has(await Rel(a), "blocked", b.Id));
        Assert.Equal(HttpStatusCode.OK, (await a.Post("/api/dms", new { userIds = new[] { b.Id }, keys = Keys(a, b) })).Status);
    }

    [Fact]
    public async Task Existing_dm_stops_working_after_a_block()
    {
        var a = await app.Register("fk"); var b = await app.Register("fl");
        var (_, r) = await a.Post("/api/dms", new { userIds = new[] { b.Id }, keys = Keys(a, b) });
        var dm = r.GetProperty("channel").GetProperty("id").GetGuid();
        Assert.Equal(HttpStatusCode.OK, (await b.Send(dm)).Status);
        await a.Post($"/api/users/{b.Id}/block");
        Assert.Equal(HttpStatusCode.Forbidden, (await b.Send(dm)).Status);
        Assert.Equal(HttpStatusCode.Forbidden, (await a.Send(dm)).Status);
    }

    [Fact]
    public async Task Friends_require_login()
    {
        var anon = app.CreateClient();
        Assert.Equal(HttpStatusCode.Unauthorized, (await Http.Send(anon, HttpMethod.Get, "/api/friends")).Status);
    }
}
