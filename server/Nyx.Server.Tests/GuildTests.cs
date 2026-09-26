using System.Net;
using Nyx.Server.Data;

namespace Nyx.Server.Tests;

public class GuildTests : IClassFixture<TestApp>
{
    readonly TestApp app;
    public GuildTests(TestApp app) { this.app = app; }

    // Permission bits (mirror of Perm)
    const long Send = 1 << 1, Kick = 1 << 11, Ban = 1 << 12, ManageRoles = 1 << 14, ManageChannels = 1 << 13, ManageMessages = 1 << 5, Admin = 1 << 17;

    async Task<(TestUser Owner, TestUser.GuildInfo G, TestUser Member)> Setup()
    {
        var owner = await app.Register("own");
        var g = await owner.CreateGuild();
        var member = await owner.InviteNewUser(g.Id, "mem");
        return (owner, g, member);
    }

    async Task<Guid> EveryoneRole(TestUser u, Guid guild)
    {
        var b = await u.Bootstrap();
        var gj = b.GetProperty("guilds").EnumerateArray().First(x => x.GetProperty("guild").GetProperty("id").GetGuid() == guild);
        return gj.GetProperty("roles").EnumerateArray().First(r => r.GetProperty("isEveryone").GetBoolean()).GetProperty("id").GetGuid();
    }

    async Task<Guid> MakeRole(TestUser u, Guid guild, long perms, int position)
    {
        var (s, b) = await u.Post($"/api/guilds/{guild}/roles", new { metaCipher = Fake.Blob(), permissions = perms, position });
        Assert.True(s == HttpStatusCode.OK, $"role: {s} {b}");
        return b.GetProperty("id").GetGuid();
    }

    [Fact]
    public async Task Creating_a_guild_makes_the_owner_a_member_of_its_channels_only()
    {
        var owner = await app.Register("g1");
        var stranger = await app.Register("g1s");
        var g = await owner.CreateGuild();

        var b = await owner.Bootstrap();
        var guild = b.GetProperty("guilds").EnumerateArray().Single();
        Assert.Equal(3, guild.GetProperty("channels").GetArrayLength());
        Assert.Contains(b.GetProperty("keys").EnumerateArray(), k => k.GetProperty("scopeId").GetGuid() == g.Id);

        Assert.Equal(0, (await stranger.Bootstrap()).GetProperty("guilds").GetArrayLength());
        Assert.Equal(HttpStatusCode.NotFound, (await stranger.Get($"/api/channels/{g.General}/messages")).Status);
        Assert.Equal(HttpStatusCode.NotFound, (await stranger.Send(g.General)).Status);
    }

    [Fact]
    public async Task Joining_by_invite_grants_channel_membership_and_default_permissions()
    {
        var (owner, g, member) = await Setup();
        Assert.Equal(HttpStatusCode.OK, (await member.Send(g.General)).Status);
        Assert.Equal(HttpStatusCode.OK, (await member.Get($"/api/channels/{g.General}/messages")).Status);
        // ...but ordinary members cannot administer.
        Assert.Equal(HttpStatusCode.Forbidden, (await member.Post($"/api/guilds/{g.Id}/roles", new { metaCipher = Fake.Blob(), permissions = Send, position = 1 })).Status);
        Assert.Equal(HttpStatusCode.Forbidden, (await member.Delete($"/api/guilds/{g.Id}")).Status);
        Assert.Equal(HttpStatusCode.Forbidden, (await member.Put($"/api/guilds/{g.Id}", new { metaCipher = Fake.Blob() })).Status);
    }

    [Fact]
    public async Task Invite_limits_and_expiry_are_enforced()
    {
        var owner = await app.Register("inv");
        var g = await owner.CreateGuild();
        var one = await owner.GuildInvite(g.Id, maxUses: 1);
        var a = await app.Register("ia", one);           // consumes the single use
        var (s, _) = await Nyx.Server.Tests.Http.Send(app.CreateClient(), HttpMethod.Post, "/api/auth/register", new
        {
            username = TestApp.UniqueName("ib"), displayName = "b", kdfSalt = Fake.Salt(), authKey = Fake.Key(),
            identityPublicKey = Fake.Key(), agreementPublicKey = Fake.Key(), encryptedKeyBackup = Fake.Blob(64), inviteCode = one,
        });
        Assert.Equal(HttpStatusCode.BadRequest, s);

        var other = await app.Register("ic");
        Assert.Equal(HttpStatusCode.BadRequest, (await other.Post($"/api/invites/{one}/join")).Status); // used up
        var many = await owner.GuildInvite(g.Id);
        Assert.Equal(HttpStatusCode.OK, (await other.Post($"/api/invites/{many}/join")).Status);
        Assert.Equal(HttpStatusCode.OK, (await other.Post($"/api/invites/{many}/join")).Status); // idempotent
        Assert.Equal(HttpStatusCode.BadRequest, (await other.Post("/api/invites/NOPE/join")).Status);
        // An invite that would only create an account cannot be used to join a server.
        Assert.Equal(HttpStatusCode.BadRequest, (await other.Post($"/api/invites/{await app.Admin().InstanceInvite()}/join")).Status);

        // Invalid invite options are refused.
        Assert.Equal(HttpStatusCode.BadRequest, (await owner.Post($"/api/guilds/{g.Id}/invites", new { maxUses = 5000, expiresHours = 1 })).Status);
        Assert.Equal(HttpStatusCode.BadRequest, (await owner.Post($"/api/guilds/{g.Id}/invites", new { maxUses = 1, expiresHours = 0 })).Status);
    }

    [Fact]
    public async Task Removing_send_permission_from_everyone_silences_members_but_not_the_owner()
    {
        var (owner, g, member) = await Setup();
        var everyone = await EveryoneRole(owner, g.Id);
        var (s, _) = await owner.Put($"/api/guilds/{g.Id}/roles/{everyone}", new { metaCipher = Fake.Blob(), permissions = 1L, position = 0 }); // view only
        Assert.Equal(HttpStatusCode.OK, s);

        Assert.Equal(HttpStatusCode.Forbidden, (await member.Send(g.General)).Status);
        Assert.Equal(HttpStatusCode.OK, (await owner.Send(g.General)).Status);
    }

    [Fact]
    public async Task Everyone_role_can_never_be_made_administrator()
    {
        var (owner, g, member) = await Setup();
        var everyone = await EveryoneRole(owner, g.Id);
        await owner.Put($"/api/guilds/{g.Id}/roles/{everyone}", new { metaCipher = Fake.Blob(), permissions = Admin | Send, position = 0 });
        // Admin bit is stripped, so a member still cannot delete a channel.
        Assert.Equal(HttpStatusCode.Forbidden, (await member.Delete($"/api/channels/{g.Voice}")).Status);
    }

    [Fact]
    public async Task Role_hierarchy_stops_moderators_from_escalating_or_touching_their_betters()
    {
        var (owner, g, member) = await Setup();
        var mod = await MakeRole(owner, g.Id, Kick | ManageRoles | Send, position: 5);
        Assert.Equal(HttpStatusCode.NoContent, (await owner.Put($"/api/guilds/{g.Id}/members/{member.Id}/roles", new { roleIds = new[] { mod } })).Status);

        // The moderator cannot create a role at or above their own rank...
        Assert.Equal(HttpStatusCode.BadRequest, (await member.Post($"/api/guilds/{g.Id}/roles", new { metaCipher = Fake.Blob(), permissions = Send, position = 5 })).Status);
        Assert.Equal(HttpStatusCode.BadRequest, (await member.Post($"/api/guilds/{g.Id}/roles", new { metaCipher = Fake.Blob(), permissions = Send, position = 9 })).Status);
        // ...nor grant powers they do not have...
        Assert.Equal(HttpStatusCode.Forbidden, (await member.Post($"/api/guilds/{g.Id}/roles", new { metaCipher = Fake.Blob(), permissions = Admin, position = 2 })).Status);
        // ...but can make a weaker one.
        var weak = await MakeRole(member, g.Id, Send, 2);

        // Cannot kick the owner, nor themselves.
        Assert.Equal(HttpStatusCode.Forbidden, (await member.Delete($"/api/guilds/{g.Id}/members/{owner.Id}")).Status);
        Assert.Equal(HttpStatusCode.BadRequest, (await member.Delete($"/api/guilds/{g.Id}/members/{member.Id}")).Status);

        // Cannot hand themselves the owner-level role ordering or edit a role above theirs.
        var boss = await MakeRole(owner, g.Id, Kick, position: 8);
        Assert.Equal(HttpStatusCode.Forbidden, (await member.Put($"/api/guilds/{g.Id}/roles/{boss}", new { metaCipher = Fake.Blob(), permissions = Send, position = 3 })).Status);
        Assert.Equal(HttpStatusCode.Forbidden, (await member.Put($"/api/guilds/{g.Id}/members/{member.Id}/roles", new { roleIds = new[] { mod, boss } })).Status);
        Assert.Equal(HttpStatusCode.NoContent, (await member.Put($"/api/guilds/{g.Id}/members/{member.Id}/roles", new { roleIds = new[] { mod, weak } })).Status);
    }

    [Fact]
    public async Task Kicking_removes_access_and_the_kicked_user_cannot_read_or_write_any_more()
    {
        var (owner, g, member) = await Setup();
        var victim = await owner.InviteNewUser(g.Id, "vic");
        var mod = await MakeRole(owner, g.Id, Kick, position: 5);
        await owner.Put($"/api/guilds/{g.Id}/members/{member.Id}/roles", new { roleIds = new[] { mod } });

        Assert.Equal(HttpStatusCode.OK, (await victim.Send(g.General)).Status);
        Assert.Equal(HttpStatusCode.NoContent, (await member.Delete($"/api/guilds/{g.Id}/members/{victim.Id}")).Status);

        Assert.Equal(HttpStatusCode.NotFound, (await victim.Send(g.General)).Status);
        Assert.Equal(HttpStatusCode.NotFound, (await victim.Get($"/api/channels/{g.General}/messages")).Status);
        Assert.Equal(0, (await victim.Bootstrap()).GetProperty("guilds").GetArrayLength());
        // A plain member cannot kick.
        var other = await owner.InviteNewUser(g.Id, "oth");
        Assert.Equal(HttpStatusCode.Forbidden, (await other.Delete($"/api/guilds/{g.Id}/members/{member.Id}")).Status);
    }

    [Fact]
    public async Task Banned_users_cannot_come_back_and_unbanning_lets_them()
    {
        var (owner, g, member) = await Setup();
        var victim = await owner.InviteNewUser(g.Id, "ban");
        Assert.Equal(HttpStatusCode.Forbidden, (await member.Put($"/api/guilds/{g.Id}/bans/{victim.Id}")).Status);
        Assert.Equal(HttpStatusCode.NoContent, (await owner.Put($"/api/guilds/{g.Id}/bans/{victim.Id}")).Status);

        var invite = await owner.GuildInvite(g.Id);
        Assert.Equal(HttpStatusCode.Forbidden, (await victim.Post($"/api/invites/{invite}/join")).Status);
        Assert.Equal(HttpStatusCode.NoContent, (await owner.Delete($"/api/guilds/{g.Id}/bans/{victim.Id}")).Status);
        Assert.Equal(HttpStatusCode.OK, (await victim.Post($"/api/invites/{invite}/join")).Status);
    }

    [Fact]
    public async Task Timeout_blocks_sending_until_it_ends()
    {
        var (owner, g, member) = await Setup();
        var (s, _) = await owner.Put($"/api/guilds/{g.Id}/members/{member.Id}/timeout", new { until = DateTime.UtcNow.AddMinutes(10) });
        Assert.Equal(HttpStatusCode.NoContent, s);
        Assert.Equal(HttpStatusCode.Forbidden, (await member.Send(g.General)).Status);
        (s, _) = await owner.Put($"/api/guilds/{g.Id}/members/{member.Id}/timeout", new { until = (DateTime?)null });
        Assert.Equal(HttpStatusCode.NoContent, s);
        Assert.Equal(HttpStatusCode.OK, (await member.Send(g.General)).Status);
        (s, _) = await owner.Put($"/api/guilds/{g.Id}/members/{member.Id}/timeout", new { until = DateTime.UtcNow.AddDays(60) });
        Assert.Equal(HttpStatusCode.BadRequest, s); // capped at 28 days
    }

    [Fact]
    public async Task Slowmode_limits_ordinary_members_but_not_moderators()
    {
        var (owner, g, member) = await Setup();
        Assert.Equal(HttpStatusCode.OK, (await owner.Put($"/api/channels/{g.General}", new { slowmodeSeconds = 60 })).Status);
        Assert.Equal(HttpStatusCode.OK, (await member.Send(g.General)).Status);
        Assert.Equal(HttpStatusCode.TooManyRequests, (await member.Send(g.General)).Status);
        Assert.Equal(HttpStatusCode.OK, (await owner.Send(g.General)).Status);
        Assert.Equal(HttpStatusCode.OK, (await owner.Send(g.General)).Status);
    }

    [Fact]
    public async Task Private_channels_are_only_visible_to_their_members()
    {
        var (owner, g, member) = await Setup();
        var other = await owner.InviteNewUser(g.Id, "oth");
        var id = Guid.NewGuid();
        var (s, _) = await owner.Post($"/api/guilds/{g.Id}/channels", new
        {
            id, kind = 0, metaCipher = Fake.Blob(), restricted = true, members = new[] { member.Id },
            keys = new[] { new { userId = owner.Id, @sealed = Fake.Blob() }, new { userId = member.Id, @sealed = Fake.Blob() } },
        });
        Assert.Equal(HttpStatusCode.OK, s);

        Assert.Equal(HttpStatusCode.OK, (await member.Send(id)).Status);
        Assert.Equal(HttpStatusCode.NotFound, (await other.Send(id)).Status);
        Assert.Equal(HttpStatusCode.NotFound, (await other.Get($"/api/channels/{id}/messages")).Status);
        var seen = (await other.Bootstrap()).GetProperty("guilds").EnumerateArray().Single().GetProperty("channels").EnumerateArray();
        Assert.DoesNotContain(seen, c => c.GetProperty("id").GetGuid() == id);

        // Add "other" -> visible; remove -> gone again.
        Assert.Equal(HttpStatusCode.NoContent, (await owner.Put($"/api/channels/{id}/members/{other.Id}", new { @sealed = Fake.Blob() })).Status);
        Assert.Equal(HttpStatusCode.OK, (await other.Send(id)).Status);
        Assert.Equal(HttpStatusCode.NoContent, (await owner.Delete($"/api/channels/{id}/members/{other.Id}")).Status);
        Assert.Equal(HttpStatusCode.NotFound, (await other.Send(id)).Status);
    }

    [Fact]
    public async Task Channel_management_needs_permission_and_validates_input()
    {
        var (owner, g, member) = await Setup();
        object NewText() => new { kind = 0, metaCipher = Fake.Blob(), keys = new[] { new { userId = owner.Id, @sealed = Fake.Blob() } } };
        Assert.Equal(HttpStatusCode.Forbidden, (await member.Post($"/api/guilds/{g.Id}/channels", NewText())).Status);
        Assert.Equal(HttpStatusCode.OK, (await owner.Post($"/api/guilds/{g.Id}/channels", NewText())).Status);
        // DMs cannot be created inside a server, and a channel needs the creator's key.
        Assert.Equal(HttpStatusCode.BadRequest, (await owner.Post($"/api/guilds/{g.Id}/channels", new { kind = 3, metaCipher = Fake.Blob() })).Status);
        Assert.Equal(HttpStatusCode.BadRequest, (await owner.Post($"/api/guilds/{g.Id}/channels", new { kind = 0, metaCipher = Fake.Blob() })).Status);
        // Parent must be a category.
        Assert.Equal(HttpStatusCode.BadRequest, (await owner.Post($"/api/guilds/{g.Id}/channels", new { kind = 0, parentId = g.General, metaCipher = Fake.Blob(), keys = new[] { new { userId = owner.Id, @sealed = Fake.Blob() } } })).Status);

        Assert.Equal(HttpStatusCode.Forbidden, (await member.Delete($"/api/channels/{g.General}")).Status);
        await owner.SendOk(g.General);
        Assert.Equal(HttpStatusCode.NoContent, (await owner.Delete($"/api/channels/{g.General}")).Status);
        Assert.Equal(HttpStatusCode.NotFound, (await owner.Get($"/api/channels/{g.General}/messages")).Status);
    }

    [Fact]
    public async Task Leaving_and_deleting_a_server()
    {
        var (owner, g, member) = await Setup();
        Assert.Equal(HttpStatusCode.BadRequest, (await owner.Post($"/api/guilds/{g.Id}/leave")).Status); // owner must transfer first
        Assert.Equal(HttpStatusCode.NoContent, (await member.Post($"/api/guilds/{g.Id}/leave")).Status);
        Assert.Equal(HttpStatusCode.NotFound, (await member.Send(g.General)).Status);

        var heir = await owner.InviteNewUser(g.Id, "heir");
        Assert.Equal(HttpStatusCode.Forbidden, (await heir.Put($"/api/guilds/{g.Id}/owner", new { userId = heir.Id })).Status);
        Assert.Equal(HttpStatusCode.NoContent, (await owner.Put($"/api/guilds/{g.Id}/owner", new { userId = heir.Id })).Status);
        Assert.Equal(HttpStatusCode.Forbidden, (await owner.Delete($"/api/guilds/{g.Id}")).Status); // no longer the owner
        Assert.Equal(HttpStatusCode.NoContent, (await heir.Delete($"/api/guilds/{g.Id}")).Status);
        Assert.Equal(HttpStatusCode.NotFound, (await heir.Get($"/api/channels/{g.General}/messages")).Status);
        Assert.Equal(0, await app.Db(async db => db.Guilds.Count(x => x.Id == g.Id)));
    }

    [Fact]
    public async Task Audit_log_is_for_people_who_manage_the_server()
    {
        var (owner, g, member) = await Setup();
        await owner.Put($"/api/guilds/{g.Id}/bans/{(await owner.InviteNewUser(g.Id, "aud")).Id}");
        var (s, b) = await owner.Get($"/api/guilds/{g.Id}/audit");
        Assert.Equal(HttpStatusCode.OK, s);
        Assert.Contains(b.EnumerateArray(), e => e.GetProperty("action").GetString() == "member.banned");
        Assert.Equal(HttpStatusCode.Forbidden, (await member.Get($"/api/guilds/{g.Id}/audit")).Status);
    }
}
