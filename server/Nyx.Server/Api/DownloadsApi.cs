using System.Collections.Concurrent;
using System.Net;
using System.Security.Cryptography;
using System.Text;

namespace Nyx.Server.Api;

/// <summary>
/// Public download page for the apps: /downloadnyx lists what is in the downloads folder, and
/// /downloadnyx/latest always hands out the newest .zip. Dropping a new zip into the folder is the whole release process.
/// Only plain files with known extensions directly inside that folder are ever served.
/// </summary>
public static class DownloadsApi
{
    static readonly string[] Allowed = [".zip", ".msi", ".appimage", ".apk", ".ipa"];
    static readonly ConcurrentDictionary<string, (long Size, DateTime Time, string Sha)> HashCache = new();

    internal record Item(string Name, long Size, DateTime Time, string Sha, string Platform);

    static string PlatformOf(string name)
    {
        var n = name.ToLowerInvariant();
        if (n.EndsWith(".apk")) return "Android";
        if (n.EndsWith(".ipa")) return "iOS";
        if (n.EndsWith(".appimage")) return "Linux";
        if (n.Contains("linux")) return "Linux";
        if (n.Contains("mac")) return "macOS";
        return "Windows";
    }

    internal static List<Item> List(string dir)
    {
        if (!Directory.Exists(dir)) return [];
        var items = new List<Item>();
        foreach (var path in Directory.GetFiles(dir))
        {
            var name = Path.GetFileName(path);
            if (!Allowed.Contains(Path.GetExtension(name).ToLowerInvariant())) continue;
            var fi = new FileInfo(path);
            if (!HashCache.TryGetValue(path, out var c) || c.Size != fi.Length || c.Time != fi.LastWriteTimeUtc)
            {
                using var fs = File.OpenRead(path);
                c = (fi.Length, fi.LastWriteTimeUtc, Convert.ToHexString(SHA256.HashData(fs)).ToLowerInvariant());
                HashCache[path] = c;
            }
            items.Add(new Item(name, fi.Length, fi.LastWriteTimeUtc, c.Sha, PlatformOf(name)));
        }
        return [.. items.OrderByDescending(i => i.Time)];
    }

    static string Size(long b) => b switch
    {
        < 1024 * 1024 => $"{b / 1024.0:0.#} KB",
        < 1024L * 1024 * 1024 => $"{b / 1024.0 / 1024:0.#} MB",
        _ => $"{b / 1024.0 / 1024 / 1024:0.##} GB",
    };

    public static void Map(IEndpointRouteBuilder app, string dir)
    {
        var g = app.MapGroup("/downloadnyx").RequireRateLimiting("api");

        g.MapGet("", (HttpContext ctx) =>
        {
            var items = List(dir);
            Func<string, string> enc = s => WebUtility.HtmlEncode(s);
            var sb = new StringBuilder();
            sb.Append("""
                <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
                <title>Download Nyx</title>
                <style>
                :root{color-scheme:dark;--bg:#0b0b14;--card:#15151f;--fg:#ededf5;--muted:#9a9ab0;--accent:#8b7cff;--accent2:#39d0c7;--line:#26263a}
                @media (prefers-color-scheme:light){:root{color-scheme:light;--bg:#f4f2ee;--card:#fff;--fg:#1b1b26;--muted:#66667a;--line:#e3e0da}}
                *{box-sizing:border-box}body{margin:0;min-height:100vh;background:var(--bg);color:var(--fg);font:16px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;display:grid;place-items:center;padding:24px;
                background-image:radial-gradient(60vmax 60vmax at 15% 10%,color-mix(in srgb,var(--accent) 22%,transparent),transparent),radial-gradient(50vmax 50vmax at 90% 90%,color-mix(in srgb,var(--accent2) 18%,transparent),transparent)}
                main{width:min(640px,100%);background:color-mix(in srgb,var(--card) 88%,transparent);border:1px solid var(--line);border-radius:22px;padding:32px;backdrop-filter:blur(18px)}
                .logo{width:64px;height:64px;border-radius:50%;background:linear-gradient(135deg,var(--accent),var(--accent2));display:grid;place-items:center;font-size:30px;box-shadow:0 0 34px color-mix(in srgb,var(--accent) 55%,transparent);margin-bottom:14px}
                h1{margin:0 0 4px;font-size:28px}p{color:var(--muted);margin:.2em 0 1.2em}
                .btn{display:inline-block;background:linear-gradient(135deg,var(--accent),var(--accent2));color:#fff;text-decoration:none;font-weight:700;padding:13px 22px;border-radius:14px;transition:transform .15s,filter .15s}
                .btn:hover{transform:translateY(-2px);filter:brightness(1.08)}
                .row{display:flex;gap:12px;align-items:center;justify-content:space-between;padding:12px 0;border-top:1px solid var(--line);flex-wrap:wrap}
                .row b{display:block}.row small{color:var(--muted);word-break:break-all}
                a.link{color:var(--accent2);text-decoration:none;font-weight:600}
                .note{font-size:13px;color:var(--muted);margin-top:18px}
                code{background:color-mix(in srgb,var(--fg) 9%,transparent);padding:1px 6px;border-radius:6px;font-size:12px}
                </style></head><body><main>
                <div class="logo">&#9790;</div><h1>Nyx</h1>
                <p>Private, end-to-end encrypted chat with voice, screen sharing and big files.</p>
                """);
            if (items.Count == 0)
            {
                sb.Append("<p>No downloads are available yet.</p>");
            }
            else
            {
                var latest = items[0];
                sb.Append($"<a class=\"btn\" href=\"/downloadnyx/latest\">Download latest for {enc(latest.Platform)} &middot; {Size(latest.Size)}</a>");
                sb.Append("<h2 style=\"margin:28px 0 4px;font-size:18px\">All versions</h2>");
                foreach (var i in items)
                    sb.Append($"<div class=\"row\"><div><b>{enc(i.Name)}</b><small>{enc(i.Platform)}{(i.Name.EndsWith(".msi", StringComparison.OrdinalIgnoreCase) ? " installer (no admin needed)" : i.Name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase) ? " portable" : "")} &middot; {Size(i.Size)} &middot; {i.Time:yyyy-MM-dd HH:mm} UTC<br>SHA-256 <code>{i.Sha}</code></small></div><a class=\"link\" href=\"/downloadnyx/files/{Uri.EscapeDataString(i.Name)}\">Download</a></div>");
            }
            sb.Append("<p class=\"note\">Windows: run the <code>.msi</code> installer (installs for your user only, no administrator rights needed), or unpack the portable <code>.zip</code> and run <code>nyx.exe</code>. Compare the SHA-256 with the downloaded file if you want to be sure it arrived intact.</p></main></body></html>");
            ctx.Response.Headers.CacheControl = "no-cache";
            return Results.Content(sb.ToString(), "text/html; charset=utf-8");
        });

        g.MapGet("/latest", IResult (HttpContext ctx, string? platform) =>
        {
            var items = List(dir);
            var pick = (platform is null ? items : items.Where(i => i.Platform.Equals(platform, StringComparison.OrdinalIgnoreCase)).ToList()).FirstOrDefault();
            if (pick is null) return Results.NotFound(new { error = "No download available." });
            return Send(ctx, dir, pick.Name);
        });

        g.MapGet("/files/{name}", IResult (HttpContext ctx, string name) =>
        {
            // Names come from the listing only: no separators, no traversal, known extensions.
            if (name != Path.GetFileName(name) || name.Contains("..") || !List(dir).Any(i => i.Name == name))
                return Results.NotFound(new { error = "No such file." });
            return Send(ctx, dir, name);
        });
    }

    static IResult Send(HttpContext ctx, string dir, string name)
    {
        ctx.Response.Headers.CacheControl = "public, max-age=300";
        ctx.Response.Headers["X-Content-Type-Options"] = "nosniff";
        return Results.File(Path.Combine(dir, name), "application/octet-stream", fileDownloadName: name, enableRangeProcessing: true);
    }
}
