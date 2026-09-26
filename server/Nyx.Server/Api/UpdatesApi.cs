using System.Text.Json;

namespace Nyx.Server.Api;

/// <summary>
/// What the apps ask on start-up: "is there a newer version, and what changed?". The answer comes from
/// <c>releases.json</c> in the downloads folder (written by deploy/release.ps1). The file itself is served to logged-in
/// users only, so the app can update itself without knowing the download page's password.
/// </summary>
public static class UpdatesApi
{
    record Release(string Version, string? Released, List<string>? Notes, Dictionary<string, string>? Files);
    record Manifest(List<Release>? Releases);

    static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true };

    static Version? Parse(string? v) => Version.TryParse((v ?? "").Split('+', '-')[0], out var r) ? r : null;

    static Manifest Load(string dir)
    {
        try
        {
            var path = Path.Combine(dir, "releases.json");
            if (!File.Exists(path)) return new Manifest([]);
            return JsonSerializer.Deserialize<Manifest>(File.ReadAllText(path), Json) ?? new Manifest([]);
        }
        catch
        {
            return new Manifest([]);
        }
    }

    static string? FileFor(string dir, Release r, string platform)
    {
        var name = r.Files is null ? null : r.Files.FirstOrDefault(f => f.Key.Equals(platform, StringComparison.OrdinalIgnoreCase)).Value;
        if (name is null || name != Path.GetFileName(name)) return null;
        return DownloadsApi.List(dir).Any(i => i.Name == name) ? name : null;
    }

    public static void Map(IEndpointRouteBuilder app, string dir)
    {
        var api = app.MapGroup("/api/app").RequireAuthorization().RequireRateLimiting("api");

        api.MapGet("/update", IResult (string? platform, string? current) =>
        {
            platform = (platform ?? "").Trim().ToLowerInvariant();
            if (platform.Length is 0 or > 16) return Support.Bad("Unknown platform.");
            var cur = Parse(current);
            var releases = (Load(dir).Releases ?? [])
                .Select(r => (r, v: Parse(r.Version)))
                .Where(x => x.v is not null)
                .OrderByDescending(x => x.v)
                .ToList();
            // Newest release that actually has a file for this platform.
            var latest = releases.FirstOrDefault(x => FileFor(dir, x.r, platform) is not null);
            if (latest.r is null || cur is null || latest.v! <= cur) return Results.Ok(new { available = false });

            var file = FileFor(dir, latest.r, platform)!;
            var item = DownloadsApi.List(dir).First(i => i.Name == file);
            var notes = releases.Where(x => x.v! > cur && x.v! <= latest.v!)
                .Select(x => new { version = x.r.Version, released = x.r.Released, notes = x.r.Notes ?? [] });
            return Results.Ok(new
            {
                available = true,
                version = latest.r.Version,
                released = latest.r.Released,
                file,
                size = item.Size,
                sha256 = item.Sha,
                changelog = notes,
            });
        });

        api.MapGet("/update/file", IResult (HttpContext ctx, string? platform, string? version) =>
        {
            platform = (platform ?? "").Trim().ToLowerInvariant();
            var rel = (Load(dir).Releases ?? []).FirstOrDefault(r => r.Version == version);
            var name = rel is null ? null : FileFor(dir, rel, platform);
            if (name is null) return Support.NotFound("No such update.");
            ctx.Response.Headers["X-Content-Type-Options"] = "nosniff";
            return Results.File(Path.Combine(dir, name), "application/octet-stream", fileDownloadName: name, enableRangeProcessing: true);
        });
    }
}
