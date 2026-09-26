using Microsoft.EntityFrameworkCore;
using Nyx.Server.Data;
using Nyx.Server.Hubs;
using Nyx.Server.Security;

namespace Nyx.Server.Api;

/// <summary>Friends list, friend requests and blocking. Purely social metadata: nothing here is message content.</summary>
public static class FriendsApi
{
    record AddReq(string? Username);

    public static async Task<object> ForAsync(NyxDb db, Guid uid)
    {
        var mine = await db.Relations.AsNoTracking().Where(r => r.UserId == uid || r.TargetId == uid).ToListAsync();
        return new
        {
            friends = mine.Where(r => r.Kind == RelationKind.Friend && r.UserId == uid).Select(r => r.TargetId).ToList(),
            incoming = mine.Where(r => r.Kind == RelationKind.Pending && r.TargetId == uid).Select(r => r.UserId).ToList(),
            outgoing = mine.Where(r => r.Kind == RelationKind.Pending && r.UserId == uid).Select(r => r.TargetId).ToList(),
            blocked = mine.Where(r => r.Kind == RelationKind.Blocked && r.UserId == uid).Select(r => r.TargetId).ToList(),
        };
    }

    static async Task Clear(NyxDb db, Guid a, Guid b)
    {
        var rows = await db.Relations.Where(r => ((r.UserId == a && r.TargetId == b) || (r.UserId == b && r.TargetId == a)) && r.Kind != RelationKind.Blocked).ToListAsync();
        db.Relations.RemoveRange(rows);
    }

    static Task Notify(Realtime rt, params Guid[] users) => Task.WhenAll(users.Distinct().Select(u => rt.ToUser(u, "FriendsChanged", new { })));

    public static void Map(IEndpointRouteBuilder app)
    {
        var api = app.MapGroup("/api").RequireAuthorization().RequireRateLimiting("api");

        api.MapGet("/friends", async (System.Security.Claims.ClaimsPrincipal me, NyxDb db) => Results.Ok(await ForAsync(db, me.UserId())));

        // By username, so nobody has to know an id. Two people asking each other simply become friends.
        api.MapPost("/friends", async (AddReq r, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Realtime rt) =>
        {
            var uid = me.UserId();
            var name = (r.Username ?? "").Trim().TrimStart('@').ToLowerInvariant();
            if (name.Length is 0 or > 40) return Support.Bad("Enter a username.");
            var other = await db.Users.AsNoTracking().FirstOrDefaultAsync(u => u.Username == name);
            if (other is null) return Support.NotFound("Nobody has that username.");
            if (other.Id == uid) return Support.Bad("You cannot add yourself.");
            if (await db.Relations.AnyAsync(x => x.Kind == RelationKind.Blocked && x.UserId == uid && x.TargetId == other.Id))
                return Support.Bad("You blocked this person. Unblock them first.");
            // Someone who blocked you looks exactly like someone who ignores you.
            if (await db.Relations.AnyAsync(x => x.Kind == RelationKind.Blocked && x.UserId == other.Id && x.TargetId == uid))
                return Results.Ok(new { status = "pending" });
            if (await db.Relations.CountAsync(x => x.UserId == uid && x.Kind == RelationKind.Pending) >= 100)
                return Support.Bad("Too many pending requests.");

            var status = "pending";
            if (await db.Relations.AnyAsync(x => x.UserId == uid && x.TargetId == other.Id && x.Kind == RelationKind.Friend)) status = "friends";
            else if (await db.Relations.AnyAsync(x => x.UserId == other.Id && x.TargetId == uid && x.Kind == RelationKind.Pending))
            {
                await Clear(db, uid, other.Id);
                db.Relations.Add(new Relation { UserId = uid, TargetId = other.Id, Kind = RelationKind.Friend });
                db.Relations.Add(new Relation { UserId = other.Id, TargetId = uid, Kind = RelationKind.Friend });
                status = "friends";
            }
            else if (!await db.Relations.AnyAsync(x => x.UserId == uid && x.TargetId == other.Id))
                db.Relations.Add(new Relation { UserId = uid, TargetId = other.Id, Kind = RelationKind.Pending });
            await db.SaveChangesAsync();
            await Notify(rt, uid, other.Id);
            return Results.Ok(new { status });
        });

        api.MapPost("/friends/{id:guid}/accept", async (Guid id, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Realtime rt) =>
        {
            var uid = me.UserId();
            var req = await db.Relations.FirstOrDefaultAsync(x => x.UserId == id && x.TargetId == uid && x.Kind == RelationKind.Pending);
            if (req is null) return Support.NotFound("No such request.");
            await Clear(db, uid, id);
            db.Relations.Add(new Relation { UserId = uid, TargetId = id, Kind = RelationKind.Friend });
            db.Relations.Add(new Relation { UserId = id, TargetId = uid, Kind = RelationKind.Friend });
            await db.SaveChangesAsync();
            await Notify(rt, uid, id);
            return Results.NoContent();
        });

        // Unfriend, decline or cancel a request.
        api.MapDelete("/friends/{id:guid}", async (Guid id, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Realtime rt) =>
        {
            var uid = me.UserId();
            await Clear(db, uid, id);
            await db.SaveChangesAsync();
            await Notify(rt, uid, id);
            return Results.NoContent();
        });

        api.MapPost("/users/{id:guid}/block", async (Guid id, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Realtime rt) =>
        {
            var uid = me.UserId();
            if (id == uid) return Support.Bad("You cannot block yourself.");
            if (!await db.Users.AnyAsync(u => u.Id == id)) return Support.NotFound("Unknown user.");
            await Clear(db, uid, id);
            if (!await db.Relations.AnyAsync(x => x.UserId == uid && x.TargetId == id && x.Kind == RelationKind.Blocked))
                db.Relations.Add(new Relation { UserId = uid, TargetId = id, Kind = RelationKind.Blocked });
            await db.SaveChangesAsync();
            await Notify(rt, uid, id);
            return Results.NoContent();
        });

        api.MapDelete("/users/{id:guid}/block", async (Guid id, System.Security.Claims.ClaimsPrincipal me, NyxDb db, Realtime rt) =>
        {
            var uid = me.UserId();
            var row = await db.Relations.FirstOrDefaultAsync(x => x.UserId == uid && x.TargetId == id && x.Kind == RelationKind.Blocked);
            if (row is not null) { db.Relations.Remove(row); await db.SaveChangesAsync(); }
            await Notify(rt, uid);
            return Results.NoContent();
        });
    }
}
