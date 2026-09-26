using System.Net;
using System.Text.Json;

namespace Nyx.Server.Tests;

public class MessagingTests : IClassFixture<TestApp>
{
    readonly TestApp app;
    public MessagingTests(TestApp app) { this.app = app; }

    static object Keys(params TestUser[] users) => users.Select(u => new { userId = u.Id, @sealed = Fake.Blob() }).ToArray();

    async Task<Guid> Dm(TestUser a, TestUser b)
    {
        var (s, r) = await a.Post("/api/dms", new { userIds = new[] { b.Id }, keys = Keys(a, b) });
        Assert.Equal(HttpStatusCode.OK, s);
        return r.GetProperty("channel").GetProperty("id").GetGuid();
    }

    async Task<Guid> Group(TestUser owner, params TestUser[] others)
    {
        var (s, r) = await owner.Post("/api/dms", new { userIds = others.Select(o => o.Id).ToArray(), keys = Keys([owner, .. others]), metaCipher = Fake.Blob() });
        Assert.Equal(HttpStatusCode.OK, s);
        return r.GetProperty("channel").GetProperty("id").GetGuid();
    }

    // ------------------------------------------------------------------ direct messages

    [Fact]
    public async Task Two_people_share_exactly_one_dm()
    {
        var a = await app.Register("da"); var b = await app.Register("db");
        var first = await Dm(a, b);
        var (s, r) = await b.Post("/api/dms", new { userIds = new[] { a.Id }, keys = Keys(a, b) });
        Assert.Equal(HttpStatusCode.OK, s);
        Assert.True(r.GetProperty("existing").GetBoolean());
        Assert.Equal(first, r.GetProperty("channel").GetProperty("id").GetGuid());
        Assert.Contains((await b.Bootstrap()).GetProperty("dms").EnumerateArray(), d => d.GetProperty("id").GetGuid() == first);
    }

    [Fact]
    public async Task Dm_validation()
    {
        var a = await app.Register("dv"); var b = await app.Register("dvb");
        Assert.Equal(HttpStatusCode.BadRequest, (await a.Post("/api/dms", new { userIds = new[] { b.Id }, keys = Keys(a) })).Status); // key missing for b
        Assert.Equal(HttpStatusCode.BadRequest, (await a.Post("/api/dms", new { userIds = new[] { Guid.NewGuid() }, keys = Keys(a) })).Status); // unknown user
        Assert.Equal(HttpStatusCode.BadRequest, (await a.Post("/api/dms", new { userIds = new[] { a.Id }, keys = Keys(a) })).Status); // yourself
        Assert.Equal(HttpStatusCode.BadRequest, (await a.Post("/api/dms", new { userIds = Array.Empty<Guid>(), keys = Keys(a) })).Status);
    }

    [Fact]
    public async Task Only_participants_can_read_write_or_react_in_a_dm()
    {
        var a = await app.Register("dp"); var b = await app.Register("dpb"); var eve = await app.Register("eve");
        var dm = await Dm(a, b);
        var id = await a.SendOk(dm);
        Assert.Equal(HttpStatusCode.OK, (await b.Get($"/api/channels/{dm}/messages")).Status);

        Assert.Equal(HttpStatusCode.NotFound, (await eve.Get($"/api/channels/{dm}/messages")).Status);
        Assert.Equal(HttpStatusCode.NotFound, (await eve.Send(dm)).Status);
        Assert.Equal(HttpStatusCode.NotFound, (await eve.Put($"/api/messages/{id}/reactions/abcdefgh1234", new { cipher = Fake.Blob() })).Status);
        Assert.Equal(HttpStatusCode.NotFound, (await eve.Delete($"/api/messages/{id}")).Status);
        Assert.Equal(HttpStatusCode.NotFound, (await eve.Put($"/api/channels/{dm}/read", new { messageId = id })).Status);
        Assert.Equal(HttpStatusCode.NotFound, (await eve.Get($"/api/channels/{dm}/pins")).Status);
        Assert.Equal(HttpStatusCode.NotFound, (await eve.Post($"/api/channels/{dm}/members", new { userIds = new[] { eve.Id }, version = 2, keys = Keys(a, b, eve) })).Status);
    }

    [Fact]
    public async Task Group_dm_limits_and_key_rotation_on_join()
    {
        var owner = await app.Register("go");
        var p = new List<TestUser>();
        for (var i = 0; i < 10; i++) p.Add(await app.Register("gp"));

        // 9 others + owner = 10 is fine, 10 others is too many.
        Assert.Equal(HttpStatusCode.OK, (await owner.Post("/api/dms", new { userIds = p.Take(9).Select(x => x.Id), keys = Keys([owner, .. p.Take(9)]) })).Status);
        Assert.Equal(HttpStatusCode.BadRequest, (await owner.Post("/api/dms", new { userIds = p.Select(x => x.Id), keys = Keys([owner, .. p]) })).Status);

        var group = await Group(owner, p[0], p[1]);
        var newcomer = p[2];
        // Adding someone must come with a new key version for everyone, not just for the newcomer.
        Assert.Equal(HttpStatusCode.BadRequest, (await owner.Post($"/api/channels/{group}/members", new { userIds = new[] { newcomer.Id }, version = 1, keys = Keys(owner, p[0], p[1], newcomer) })).Status);
        Assert.Equal(HttpStatusCode.BadRequest, (await owner.Post($"/api/channels/{group}/members", new { userIds = new[] { newcomer.Id }, version = 2, keys = Keys(newcomer) })).Status);

        await owner.SendOk(group); // said before the newcomer arrived
        await Task.Delay(1200);
        Assert.Equal(HttpStatusCode.NoContent, (await owner.Post($"/api/channels/{group}/members", new { userIds = new[] { newcomer.Id }, version = 2, keys = Keys(owner, p[0], p[1], newcomer) })).Status);
        var after = await owner.SendOk(group);

        var (s, hist) = await newcomer.Get($"/api/channels/{group}/messages");
        Assert.Equal(HttpStatusCode.OK, s);
        var ids = hist.EnumerateArray().Select(m => m.GetProperty("id").GetInt64()).ToList();
        Assert.Equal([after], ids); // history from before they joined is not served to them
        Assert.Equal(2, (await owner.Bootstrap()).GetProperty("dms").EnumerateArray().First(d => d.GetProperty("id").GetGuid() == group).GetProperty("keyVersion").GetInt32());
    }

    [Fact]
    public async Task Leaving_and_removing_from_group_dm()
    {
        var owner = await app.Register("lo"); var a = await app.Register("la"); var b = await app.Register("lb");
        var group = await Group(owner, a, b);
        Assert.Equal(HttpStatusCode.Forbidden, (await a.Delete($"/api/channels/{group}/members/{b.Id}")).Status); // only the owner removes others
        Assert.Equal(HttpStatusCode.NoContent, (await a.Delete($"/api/channels/{group}/members/{a.Id}")).Status); // leaving is fine
        Assert.Equal(HttpStatusCode.NotFound, (await a.Send(group)).Status);
        Assert.Equal(HttpStatusCode.NoContent, (await owner.Delete($"/api/channels/{group}/members/{b.Id}")).Status);
        Assert.Equal(HttpStatusCode.NotFound, (await b.Get($"/api/channels/{group}/messages")).Status);

        var dm = await Dm(owner, a);
        Assert.Equal(HttpStatusCode.BadRequest, (await a.Delete($"/api/channels/{dm}/members/{a.Id}")).Status); // a 1:1 DM cannot be left
    }

    // -------------------------------------------------------------------------- messages

    [Fact]
    public async Task Send_history_edit_delete()
    {
        var a = await app.Register("ma"); var b = await app.Register("mb");
        var dm = await Dm(a, b);
        var m1 = await a.SendOk(dm);
        var m2 = await b.SendOk(dm);
        var m3 = await a.SendOk(dm);

        var (_, all) = await b.Get($"/api/channels/{dm}/messages");
        Assert.Equal([m1, m2, m3], all.EnumerateArray().Select(x => x.GetProperty("id").GetInt64()));
        var (_, before) = await b.Get($"/api/channels/{dm}/messages?before={m3}&limit=1");
        Assert.Equal([m2], before.EnumerateArray().Select(x => x.GetProperty("id").GetInt64()));
        var (_, after) = await b.Get($"/api/channels/{dm}/messages?after={m1}");
        Assert.Equal([m2, m3], after.EnumerateArray().Select(x => x.GetProperty("id").GetInt64()));

        // Only the author can edit; anyone else is refused.
        Assert.Equal(HttpStatusCode.Forbidden, (await b.Put($"/api/messages/{m1}", new { ciphertext = Fake.Blob(), keyVersion = 1 })).Status);
        Assert.Equal(HttpStatusCode.NoContent, (await a.Put($"/api/messages/{m1}", new { ciphertext = Fake.Blob(), keyVersion = 1 })).Status);
        var (_, edited) = await b.Get($"/api/channels/{dm}/messages?limit=100");
        Assert.NotEqual(JsonValueKind.Null, edited.EnumerateArray().First().GetProperty("editedAt").ValueKind);

        // In a DM you delete only your own; deleted content is wiped, not just hidden.
        Assert.Equal(HttpStatusCode.Forbidden, (await b.Delete($"/api/messages/{m1}")).Status);
        Assert.Equal(HttpStatusCode.NoContent, (await a.Delete($"/api/messages/{m1}")).Status);
        var (_, after2) = await b.Get($"/api/channels/{dm}/messages?limit=100");
        var gone = after2.EnumerateArray().First();
        Assert.True(gone.GetProperty("deleted").GetBoolean());
        Assert.Equal("", gone.GetProperty("ciphertext").GetString());
        Assert.Equal("", await app.Db(async db => db.Messages.First(x => x.Id == m1).Ciphertext));
        Assert.Equal(HttpStatusCode.Forbidden, (await a.Put($"/api/messages/{m1}", new { ciphertext = Fake.Blob(), keyVersion = 1 })).Status);
    }

    [Fact]
    public async Task Message_input_is_validated()
    {
        var a = await app.Register("mv"); var b = await app.Register("mvb");
        var dm = await Dm(a, b);
        Assert.Equal(HttpStatusCode.BadRequest, (await a.Post($"/api/channels/{dm}/messages", new { ciphertext = "", keyVersion = 1 })).Status);
        Assert.Equal(HttpStatusCode.BadRequest, (await a.Post($"/api/channels/{dm}/messages", new { ciphertext = new string('A', 300_000), keyVersion = 1 })).Status);
        Assert.Equal(HttpStatusCode.BadRequest, (await a.Post($"/api/channels/{dm}/messages", new { ciphertext = Fake.Blob(), keyVersion = 7 })).Status); // key version that does not exist
        Assert.Equal(HttpStatusCode.BadRequest, (await a.Post($"/api/channels/{dm}/messages", new { ciphertext = Fake.Blob(), keyVersion = 0 })).Status);
        Assert.Equal(HttpStatusCode.BadRequest, (await a.Send(dm, replyTo: 999999)).Status);
        var other = await Dm(a, await app.Register("mvc"));
        var foreign = await a.SendOk(other);
        Assert.Equal(HttpStatusCode.BadRequest, (await a.Send(dm, replyTo: foreign)).Status); // cannot reply across channels
        var ok = await a.SendOk(dm);
        Assert.Equal(HttpStatusCode.OK, (await b.Send(dm, replyTo: ok)).Status);
    }

    [Fact]
    public async Task Rapid_fire_is_rate_limited()
    {
        var a = await app.Register("rf"); var b = await app.Register("rfb");
        var dm = await Dm(a, b);
        var results = new List<HttpStatusCode>();
        for (var i = 0; i < 40; i++) results.Add((await a.Send(dm)).Status);
        Assert.Contains(HttpStatusCode.TooManyRequests, results);
        Assert.Equal(HttpStatusCode.OK, results[0]);
        Assert.Equal(HttpStatusCode.OK, (await b.Send(dm)).Status); // limits are per person
    }

    [Fact]
    public async Task Reactions_are_deduplicated_aggregated_and_capped()
    {
        var a = await app.Register("ra"); var b = await app.Register("rb");
        var dm = await Dm(a, b);
        var m = await a.SendOk(dm);
        var tag = "tag-thumbs-up-1234";
        Assert.Equal(HttpStatusCode.NoContent, (await a.Put($"/api/messages/{m}/reactions/{tag}", new { cipher = Fake.Blob() })).Status);
        Assert.Equal(HttpStatusCode.NoContent, (await a.Put($"/api/messages/{m}/reactions/{tag}", new { cipher = Fake.Blob() })).Status); // same again: no-op
        Assert.Equal(HttpStatusCode.NoContent, (await b.Put($"/api/messages/{m}/reactions/{tag}", new { cipher = Fake.Blob() })).Status);

        var (_, hist) = await b.Get($"/api/channels/{dm}/messages");
        var reactions = hist.EnumerateArray().Single().GetProperty("reactions");
        Assert.Equal(1, reactions.GetArrayLength());
        Assert.Equal(2, reactions[0].GetProperty("users").GetArrayLength());

        Assert.Equal(HttpStatusCode.NoContent, (await a.Delete($"/api/messages/{m}/reactions/{tag}")).Status);
        (_, hist) = await b.Get($"/api/channels/{dm}/messages");
        Assert.Equal(1, hist.EnumerateArray().Single().GetProperty("reactions")[0].GetProperty("users").GetArrayLength());

        Assert.Equal(HttpStatusCode.BadRequest, (await a.Put($"/api/messages/{m}/reactions/short", new { cipher = Fake.Blob() })).Status);
        for (var i = 0; i < 25; i++) await a.Put($"/api/messages/{m}/reactions/emoji-tag-number-{i:D3}", new { cipher = Fake.Blob() });
        (_, hist) = await b.Get($"/api/channels/{dm}/messages");
        Assert.True(hist.EnumerateArray().Single().GetProperty("reactions").GetArrayLength() <= 20);
    }

    [Fact]
    public async Task Pinning_and_read_state()
    {
        var a = await app.Register("pa"); var b = await app.Register("pb");
        var dm = await Dm(a, b);
        var m1 = await a.SendOk(dm); var m2 = await b.SendOk(dm);
        Assert.Equal(HttpStatusCode.NoContent, (await b.Put($"/api/messages/{m1}/pin")).Status); // DM members can pin
        var (_, pins) = await a.Get($"/api/channels/{dm}/pins");
        Assert.Equal([m1], pins.EnumerateArray().Select(x => x.GetProperty("id").GetInt64()));
        Assert.Equal(HttpStatusCode.NoContent, (await a.Delete($"/api/messages/{m1}/pin")).Status);
        (_, pins) = await a.Get($"/api/channels/{dm}/pins");
        Assert.Equal(0, pins.GetArrayLength());

        Assert.Equal(HttpStatusCode.NoContent, (await a.Put($"/api/channels/{dm}/read", new { messageId = m2 })).Status);
        Assert.Equal(HttpStatusCode.NoContent, (await a.Put($"/api/channels/{dm}/read", new { messageId = m1 })).Status); // never moves backwards
        var boot = await a.Bootstrap();
        Assert.Equal(m2, boot.GetProperty("readStates").EnumerateArray().Single().GetProperty("lastReadId").GetInt64());
        Assert.Equal(m2, boot.GetProperty("lastMessageIds").EnumerateArray().Single().GetProperty("lastId").GetInt64());
    }

    [Fact]
    public async Task Moderators_can_delete_and_pin_in_servers_but_members_cannot()
    {
        var owner = await app.Register("so");
        var g = await owner.CreateGuild();
        var member = await owner.InviteNewUser(g.Id, "sm");
        var other = await owner.InviteNewUser(g.Id, "sn");
        var msg = await member.SendOk(g.General);

        Assert.Equal(HttpStatusCode.Forbidden, (await other.Delete($"/api/messages/{msg}")).Status);
        Assert.Equal(HttpStatusCode.Forbidden, (await other.Put($"/api/messages/{msg}/pin")).Status);
        Assert.Equal(HttpStatusCode.NoContent, (await owner.Put($"/api/messages/{msg}/pin")).Status);
        Assert.Equal(HttpStatusCode.NoContent, (await owner.Delete($"/api/messages/{msg}")).Status); // owner has ManageMessages
    }

    // ------------------------------------------------------------------------------ keys

    [Fact]
    public async Task Keys_can_only_be_shared_by_holders_to_members()
    {
        var owner = await app.Register("ko");
        var g = await owner.CreateGuild();
        var member = await owner.InviteNewUser(g.Id, "km");
        var outsider = await app.Register("kx");

        // The new member has channel rows but no keys yet; the server reports who is waiting.
        var pending = (await owner.Bootstrap()).GetProperty("pendingKeys").EnumerateArray()
            .Where(p => p.GetProperty("scopeId").GetGuid() == g.General).ToList();
        Assert.Single(pending);
        Assert.Contains(pending[0].GetProperty("userIds").EnumerateArray(), u => u.GetGuid() == member.Id);

        Assert.Equal(HttpStatusCode.NoContent, (await owner.SealTo(g.General, member.Id)).Status);
        Assert.Contains((await member.Bootstrap()).GetProperty("keys").EnumerateArray(), k => k.GetProperty("scopeId").GetGuid() == g.General);
        Assert.DoesNotContain((await owner.Bootstrap()).GetProperty("pendingKeys").EnumerateArray(), p => p.GetProperty("scopeId").GetGuid() == g.General);

        // Non-members never receive keys; people who do not hold a key cannot hand it out.
        await owner.SealTo(g.General, outsider.Id);
        Assert.DoesNotContain((await outsider.Bootstrap()).GetProperty("keys").EnumerateArray(), k => k.GetProperty("scopeId").GetGuid() == g.General);
        var third = await owner.InviteNewUser(g.Id, "kt");
        await outsider.SealTo(g.General, third.Id);
        Assert.DoesNotContain((await third.Bootstrap()).GetProperty("keys").EnumerateArray(), k => k.GetProperty("scopeId").GetGuid() == g.General);
    }

    [Fact]
    public async Task Rotation_requires_the_next_version_and_exactly_the_current_members()
    {
        var owner = await app.Register("ro");
        var g = await owner.CreateGuild();
        var member = await owner.InviteNewUser(g.Id, "rm");
        object Ch(int ver, params TestUser[] who) => new[] { new { channelId = g.General, version = ver, keys = Keys(who) } };

        Assert.Equal(HttpStatusCode.Conflict, (await owner.Post($"/api/guilds/{g.Id}/rotate", new { version = 5, guildKeys = Keys(owner, member) })).Status);
        Assert.Equal(HttpStatusCode.BadRequest, (await owner.Post($"/api/guilds/{g.Id}/rotate", new { version = 2, guildKeys = Keys(owner) })).Status); // member missing
        Assert.Equal(HttpStatusCode.Forbidden, (await member.Post($"/api/guilds/{g.Id}/rotate", new { version = 2, guildKeys = Keys(owner, member) })).Status);
        Assert.Equal(HttpStatusCode.NoContent, (await owner.Post($"/api/guilds/{g.Id}/rotate", new { version = 2, guildKeys = Keys(owner, member), channels = Ch(2, owner, member) })).Status);

        var boot = await owner.Bootstrap();
        Assert.Equal(2, boot.GetProperty("guilds")[0].GetProperty("guild").GetProperty("keyVersion").GetInt32());
        // Old and new versions are both kept, so history stays readable.
        Assert.Equal(2, boot.GetProperty("keys").EnumerateArray().Count(k => k.GetProperty("scopeId").GetGuid() == g.Id));
        Assert.Equal(HttpStatusCode.OK, (await member.Send(g.General, keyVersion: 2)).Status);
        Assert.Equal(HttpStatusCode.OK, (await member.Send(g.General, keyVersion: 1)).Status);
        Assert.Equal(HttpStatusCode.BadRequest, (await member.Send(g.General, keyVersion: 3)).Status);
    }

    // --------------------------------------------------------------------------- profile

    [Fact]
    public async Task Profile_updates_are_validated_and_profile_keys_go_only_to_real_users()
    {
        var a = await app.Register("pf"); var b = await app.Register("pfb");
        Assert.Equal(HttpStatusCode.BadRequest, (await a.Put("/api/users/me", new { displayName = "" })).Status);
        Assert.Equal(HttpStatusCode.BadRequest, (await a.Put("/api/users/me", new { displayName = new string('x', 41) })).Status);
        Assert.Equal(HttpStatusCode.BadRequest, (await a.Put("/api/users/me", new { profileCipher = new string('A', 70_000) })).Status);
        Assert.Equal(HttpStatusCode.OK, (await a.Put("/api/users/me", new { displayName = "Alice", profileCipher = Fake.Blob(200), profileVersion = 3 })).Status);

        Assert.Equal(HttpStatusCode.NoContent, (await a.Post("/api/users/me/profile-keys", new[] { new { viewerId = b.Id, version = 1, @sealed = Fake.Blob() }, new { viewerId = Guid.NewGuid(), version = 1, @sealed = Fake.Blob() } })).Status);
        var boot = await b.Bootstrap();
        Assert.Single(boot.GetProperty("profileKeys").EnumerateArray().Where(k => k.GetProperty("ownerId").GetGuid() == a.Id));
        Assert.Equal("Alice", boot.GetProperty("users").EnumerateArray().First(u => u.GetProperty("id").GetGuid() == a.Id).GetProperty("displayName").GetString());
        // Once shared, b no longer shows up as someone still waiting for a's profile key.
        Assert.DoesNotContain((await a.Bootstrap()).GetProperty("pendingProfileKeys").EnumerateArray(), x => x.GetGuid() == b.Id);
    }
}
