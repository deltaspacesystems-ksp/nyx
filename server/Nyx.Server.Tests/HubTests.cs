using System.Collections.Concurrent;
using System.Net;
using System.Text.Json;
using Microsoft.AspNetCore.Http.Connections;
using Microsoft.AspNetCore.SignalR;
using Microsoft.AspNetCore.SignalR.Client;

namespace Nyx.Server.Tests;

public class HubTests : IClassFixture<TestApp>
{
    readonly TestApp app;
    public HubTests(TestApp app) { this.app = app; }

    /// <summary>A connected hub client that records every event it receives.</summary>
    sealed class Live : IAsyncDisposable
    {
        public HubConnection Conn = null!;
        public readonly ConcurrentQueue<(string Event, JsonElement Data)> Events = new();

        public static async Task<Live> Connect(TestApp app, string token, params string[] listen)
        {
            var l = new Live();
            var handler = app.Server.CreateHandler();
            l.Conn = new HubConnectionBuilder()
                .WithUrl(new Uri(app.Server.BaseAddress, "/hub"), o =>
                {
                    o.AccessTokenProvider = () => Task.FromResult<string?>(token);
                    o.HttpMessageHandlerFactory = _ => handler;
                    o.Transports = HttpTransportType.LongPolling; // the in-memory test server has no WebSockets
                })
                .Build();
            foreach (var e in new[] { "MessageCreate", "MessageUpdate", "MessageDelete", "ChannelCreate", "ChannelDelete", "GuildRemoved", "MemberAdd", "MemberRemove",
                "Presence", "Ready", "Typing", "VoiceJoined", "VoiceLeft", "VoiceParticipants", "VoiceState", "Signal", "SessionRevoked", "Resync", "KeysAvailable", "UserJoined" }.Concat(listen))
                l.Conn.On<JsonElement>(e, d => l.Events.Enqueue((e, d.Clone())));
            await l.Conn.StartAsync();
            return l;
        }

        public async Task<JsonElement> Wait(string evt, Func<JsonElement, bool>? where = null, int ms = 5000)
        {
            var until = DateTime.UtcNow.AddMilliseconds(ms);
            while (DateTime.UtcNow < until)
            {
                foreach (var e in Events) if (e.Event == evt && (where is null || where(e.Data))) return e.Data;
                await Task.Delay(25);
            }
            throw new TimeoutException($"Never received {evt}; got [{string.Join(", ", Events.Select(e => e.Event))}], state {Conn.State}");
        }

        public async Task<bool> Never(string evt, Func<JsonElement, bool>? where = null, int ms = 700)
        {
            await Task.Delay(ms);
            return !Events.Any(e => e.Event == evt && (where is null || where(e.Data)));
        }

        public ValueTask DisposeAsync() => Conn.DisposeAsync();
    }

    async Task<(TestUser A, TestUser B, Guid Dm)> Pair()
    {
        var a = await app.Register("ha"); var b = await app.Register("hb");
        var (_, r) = await a.Post("/api/dms", new { userIds = new[] { b.Id }, keys = new[] { new { userId = a.Id, @sealed = Fake.Blob() }, new { userId = b.Id, @sealed = Fake.Blob() } } });
        return (a, b, r.GetProperty("channel").GetProperty("id").GetGuid());
    }

    [Fact]
    public async Task The_hub_refuses_anonymous_and_revoked_tokens()
    {
        var u = await app.Register("hh");
        await Assert.ThrowsAnyAsync<Exception>(() => Live.Connect(app, ""));
        await Assert.ThrowsAnyAsync<Exception>(() => Live.Connect(app, "not.a.jwt"));
        var token = u.Access;
        await u.Post("/api/auth/logout");
        await Assert.ThrowsAnyAsync<Exception>(() => Live.Connect(app, token));
    }

    [Fact]
    public async Task Messages_reach_members_live_and_nobody_else()
    {
        var (a, b, dm) = await Pair();
        var eve = await app.Register("he");
        await using var la = await Live.Connect(app, a.Access);
        await using var lb = await Live.Connect(app, b.Access);
        await using var le = await Live.Connect(app, eve.Access);

        var id = await la.Conn.InvokeAsync<long>("SendMessage", dm, Fake.Blob(60), 1, (long?)null);
        var got = await lb.Wait("MessageCreate", d => d.GetProperty("id").GetInt64() == id);
        Assert.Equal(a.Id, got.GetProperty("senderId").GetGuid());
        await la.Wait("MessageCreate", d => d.GetProperty("id").GetInt64() == id); // the sender's other devices see it too

        var restId = await b.SendOk(dm); // messages sent through REST are pushed as well
        await la.Wait("MessageCreate", d => d.GetProperty("id").GetInt64() == restId);

        Assert.True(await le.Never("MessageCreate"));
        // An outsider cannot post through the hub either.
        await Assert.ThrowsAsync<HubException>(() => le.Conn.InvokeAsync<long>("SendMessage", dm, Fake.Blob(), 1, (long?)null));
        await Assert.ThrowsAsync<HubException>(() => la.Conn.InvokeAsync<long>("SendMessage", dm, "", 1, (long?)null));
    }

    [Fact]
    public async Task Edits_deletes_and_reactions_are_pushed()
    {
        var (a, b, dm) = await Pair();
        await using var lb = await Live.Connect(app, b.Access);
        var m = await a.SendOk(dm);
        await lb.Wait("MessageCreate");
        await a.Put($"/api/messages/{m}", new { ciphertext = Fake.Blob(), keyVersion = 1 });
        await lb.Wait("MessageUpdate", d => d.GetProperty("editedAt").ValueKind != JsonValueKind.Null);
        await b.Put($"/api/messages/{m}/reactions/thumbs-up-tag-1", new { cipher = Fake.Blob() });
        await lb.Wait("MessageUpdate", d => d.GetProperty("reactions").GetArrayLength() == 1);
        await a.Delete($"/api/messages/{m}");
        await lb.Wait("MessageDelete", d => d.GetProperty("id").GetInt64() == m);
    }

    [Fact]
    public async Task Someone_removed_from_a_server_stops_receiving_its_traffic()
    {
        var owner = await app.Register("ko");
        var g = await owner.CreateGuild();
        var member = await owner.InviteNewUser(g.Id, "km");
        await using var lo = await Live.Connect(app, owner.Access);
        await using var lm = await Live.Connect(app, member.Access);

        await owner.SendOk(g.General);
        await lm.Wait("MessageCreate");

        await owner.Delete($"/api/guilds/{g.Id}/members/{member.Id}");
        await lm.Wait("GuildRemoved", d => d.GetProperty("reason").GetString() == "kicked");
        var before = lm.Events.Count(e => e.Event == "MessageCreate");
        await owner.SendOk(g.General);
        await lo.Wait("MessageCreate", d => d.GetProperty("channelId").GetGuid() == g.General);
        await Task.Delay(600);
        Assert.Equal(before, lm.Events.Count(e => e.Event == "MessageCreate")); // nothing new reached the kicked member
    }

    [Fact]
    public async Task New_channels_reach_only_the_people_who_may_see_them()
    {
        var owner = await app.Register("no");
        var g = await owner.CreateGuild();
        var member = await owner.InviteNewUser(g.Id, "nm");
        var other = await owner.InviteNewUser(g.Id, "nx");
        await using var lm = await Live.Connect(app, member.Access);
        await using var lx = await Live.Connect(app, other.Access);
        var secret = Guid.NewGuid();
        await owner.Post($"/api/guilds/{g.Id}/channels", new
        {
            id = secret, kind = 0, metaCipher = Fake.Blob(), restricted = true, members = new[] { member.Id },
            keys = new[] { new { userId = owner.Id, @sealed = Fake.Blob() }, new { userId = member.Id, @sealed = Fake.Blob() } },
        });
        await lm.Wait("ChannelCreate", d => d.GetProperty("id").GetGuid() == secret);
        Assert.True(await lx.Never("ChannelCreate", d => d.GetProperty("id").GetGuid() == secret));

        // Live subscription follows membership: the member gets its messages, the other person does not.
        await owner.SendOk(secret);
        await lm.Wait("MessageCreate", d => d.GetProperty("channelId").GetGuid() == secret);
        Assert.True(await lx.Never("MessageCreate", d => d.GetProperty("channelId").GetGuid() == secret, 300));
    }

    [Fact]
    public async Task Presence_is_announced_and_invisible_stays_hidden()
    {
        var (a, b, _) = await Pair();
        await using var la = await Live.Connect(app, a.Access);
        await using (var lb = await Live.Connect(app, b.Access))
        {
            await la.Wait("Presence", d => d.GetProperty("userId").GetGuid() == b.Id && d.GetProperty("presence").GetString() == "online");
            var ready = await lb.Wait("Ready");
            Assert.Contains(ready.GetProperty("online").EnumerateArray(), o => o.GetProperty("userId").GetGuid() == a.Id);
            await lb.Conn.InvokeAsync("SetPresence", "dnd");
            await la.Wait("Presence", d => d.GetProperty("userId").GetGuid() == b.Id && d.GetProperty("presence").GetString() == "dnd");
            await lb.Conn.InvokeAsync("SetPresence", "invisible");
            await la.Wait("Presence", d => d.GetProperty("userId").GetGuid() == b.Id && d.GetProperty("presence").GetString() == "offline");
            await Assert.ThrowsAsync<HubException>(() => lb.Conn.InvokeAsync("SetPresence", "hacker"));
        }
        await la.Wait("Presence", d => d.GetProperty("userId").GetGuid() == b.Id && d.GetProperty("presence").GetString() == "offline");
    }

    [Fact]
    public async Task Revoking_a_session_cuts_the_live_connection()
    {
        var u = await app.Register("rv");
        await using var live = await Live.Connect(app, u.Access);
        await live.Wait("Ready"); // the server has finished registering this connection
        await u.Post("/api/auth/logout");
        await live.Wait("SessionRevoked");
    }

    // -------------------------------------------------------------------------------- calls

    [Fact]
    public async Task Calls_signalling_only_flows_between_people_in_the_same_call()
    {
        var owner = await app.Register("co");
        var g = await owner.CreateGuild();
        var m1 = await owner.InviteNewUser(g.Id, "c1");
        var m2 = await owner.InviteNewUser(g.Id, "c2");
        var outsider = await app.Register("cx");
        await using var lo = await Live.Connect(app, owner.Access);
        await using var l1 = await Live.Connect(app, m1.Access);
        await using var l2 = await Live.Connect(app, m2.Access);
        await using var lx = await Live.Connect(app, outsider.Access);

        await Assert.ThrowsAsync<HubException>(() => lx.Conn.InvokeAsync("JoinVoice", g.Voice));      // not a member
        await Assert.ThrowsAsync<HubException>(() => lo.Conn.InvokeAsync("JoinVoice", g.General));    // a text channel
        await lo.Conn.InvokeAsync("JoinVoice", g.Voice);
        await l1.Conn.InvokeAsync("JoinVoice", g.Voice);
        var parts = await l1.Wait("VoiceParticipants");
        Assert.Equal(2, parts.GetProperty("userIds").GetArrayLength());
        await lo.Wait("VoiceJoined", d => d.GetProperty("userId").GetGuid() == m1.Id);

        await lo.Conn.InvokeAsync("Signal", m1.Id, g.Voice, "encrypted-offer");
        var sig = await l1.Wait("Signal");
        Assert.Equal(owner.Id, sig.GetProperty("from").GetGuid());
        Assert.Equal("encrypted-offer", sig.GetProperty("payload").GetString());

        // m2 is in the server but not in the call: cannot be signalled, cannot signal.
        await Assert.ThrowsAsync<HubException>(() => lo.Conn.InvokeAsync("Signal", m2.Id, g.Voice, "x"));
        await Assert.ThrowsAsync<HubException>(() => l2.Conn.InvokeAsync("Signal", owner.Id, g.Voice, "x"));
        await Assert.ThrowsAsync<HubException>(() => lo.Conn.InvokeAsync("Signal", m1.Id, g.Voice, new string('A', 70_000))); // oversized

        await l1.Conn.InvokeAsync("SetVoiceState", true, false, false);
        var st = await lo.Wait("VoiceState", d => d.GetProperty("users").EnumerateArray().Any(x => x.GetProperty("muted").GetBoolean()));
        Assert.Equal(2, st.GetProperty("users").GetArrayLength());

        await l1.Conn.InvokeAsync("LeaveVoice");
        await lo.Wait("VoiceLeft", d => d.GetProperty("userId").GetGuid() == m1.Id);
        await Assert.ThrowsAsync<HubException>(() => lo.Conn.InvokeAsync("Signal", m1.Id, g.Voice, "late")); // gone from the call
    }

    [Fact]
    public async Task Disconnecting_leaves_the_call_and_it_fills_up_at_ten()
    {
        var owner = await app.Register("fo");
        var g = await owner.CreateGuild();
        var users = new List<TestUser>();
        for (var i = 0; i < 10; i++) users.Add(await owner.InviteNewUser(g.Id, "f"));
        await using var lo = await Live.Connect(app, owner.Access);
        var clients = new List<Live>();
        try
        {
            await lo.Conn.InvokeAsync("JoinVoice", g.Voice);
            for (var i = 0; i < 9; i++)
            {
                var l = await Live.Connect(app, users[i].Access);
                clients.Add(l);
                await l.Conn.InvokeAsync("JoinVoice", g.Voice);
            }
            var extra = await Live.Connect(app, users[9].Access);
            clients.Add(extra);
            await Assert.ThrowsAsync<HubException>(() => extra.Conn.InvokeAsync("JoinVoice", g.Voice)); // 11th person

            await clients[0].Conn.StopAsync(); // dropping the connection frees the seat
            await lo.Wait("VoiceLeft", d => d.GetProperty("userId").GetGuid() == users[0].Id);
            await extra.Conn.InvokeAsync("JoinVoice", g.Voice);
        }
        finally { foreach (var c in clients) await c.DisposeAsync(); }
    }

    [Fact]
    public async Task Joining_a_dm_call_works_for_participants()
    {
        var (a, b, dm) = await Pair();
        await using var la = await Live.Connect(app, a.Access);
        await using var lb = await Live.Connect(app, b.Access);
        await la.Conn.InvokeAsync("JoinVoice", dm);
        await lb.Conn.InvokeAsync("JoinVoice", dm);
        await la.Wait("VoiceJoined", d => d.GetProperty("userId").GetGuid() == b.Id);
        await la.Conn.InvokeAsync("Signal", b.Id, dm, "hi");
        await lb.Wait("Signal");
    }
}
