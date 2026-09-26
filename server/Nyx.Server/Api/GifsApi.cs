using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Nyx.Server.Api;

/// <summary>
/// GIF search through Klipy (Tenor-compatible v2 API). Apps never talk to Klipy directly: the server searches with
/// its own key and also fetches the pictures, so Klipy never sees anybody's IP address and no key ships in the apps.
/// Only URLs that came out of a Klipy response can be fetched (no open proxy). Needs <c>Klipy:ApiKey</c>.
/// </summary>
public static class GifsApi
{
    const long MaxBytes = 16 * 1024 * 1024;
    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(20) };

    // opaque token -> url, remembered for a while after it was handed out in a search result
    static readonly ConcurrentDictionary<string, (string Url, DateTime Expires)> Known = new();

    static string Token(string url) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(url)))[..24].ToLowerInvariant();

    static string Remember(string url)
    {
        var t = Token(url);
        Known[t] = (url, DateTime.UtcNow.AddHours(2));
        if (Known.Count > 20000)
            foreach (var k in Known.Where(x => x.Value.Expires < DateTime.UtcNow).Select(x => x.Key).ToList()) Known.TryRemove(k, out _);
        return t;
    }

    static string? Str(JsonElement e, params string[] path)
    {
        foreach (var p in path)
        {
            if (e.ValueKind != JsonValueKind.Object || !e.TryGetProperty(p, out e)) return null;
        }
        return e.ValueKind == JsonValueKind.String ? e.GetString() : null;
    }

    static bool SafeUrl(string? u) => Uri.TryCreate(u, UriKind.Absolute, out var uri) && uri.Scheme == Uri.UriSchemeHttps;

    public static void Map(IEndpointRouteBuilder app, IConfiguration cfg)
    {
        var api = app.MapGroup("/api/gifs").RequireAuthorization().RequireRateLimiting("api");
        var key = cfg["Klipy:ApiKey"];

        api.MapGet("/status", () => Results.Ok(new { enabled = !string.IsNullOrWhiteSpace(key) }));

        async Task<IResult> Query(string endpoint, string? q, string? pos, string userId)
        {
            if (string.IsNullOrWhiteSpace(key)) return Support.Error(501, "GIF search is not set up on this server.");
            var url = $"https://api.klipy.com/v2/{endpoint}?key={Uri.EscapeDataString(key)}&limit=24&contentfilter=medium&media_filter=gif,tinygif,nanogif&client_key=nyx&country=US&locale=en_US"
                      + (q is null ? "" : $"&q={Uri.EscapeDataString(q)}") + (string.IsNullOrEmpty(pos) ? "" : $"&pos={Uri.EscapeDataString(pos)}");
            try
            {
                using var res = await Http.GetAsync(url);
                if (!res.IsSuccessStatusCode) return Support.Error(502, "The GIF service did not answer.");
                using var doc = JsonDocument.Parse(await res.Content.ReadAsStringAsync());
                var results = new List<object>();
                if (doc.RootElement.TryGetProperty("results", out var arr) && arr.ValueKind == JsonValueKind.Array)
                {
                    foreach (var r in arr.EnumerateArray())
                    {
                        if (!r.TryGetProperty("media_formats", out var mf)) continue;
                        var full = Str(mf, "gif", "url") ?? Str(mf, "tinygif", "url");
                        var small = Str(mf, "tinygif", "url") ?? Str(mf, "nanogif", "url") ?? full;
                        if (!SafeUrl(full) || !SafeUrl(small)) continue;
                        int w = 0, h = 0;
                        if (mf.TryGetProperty("tinygif", out var t) && t.TryGetProperty("dims", out var d) && d.GetArrayLength() == 2) { w = d[0].GetInt32(); h = d[1].GetInt32(); }
                        results.Add(new { id = Str(r, "id") ?? Token(full!), preview = Remember(small!), full = Remember(full!), w, h, title = Str(r, "content_description") ?? "" });
                    }
                }
                return Results.Ok(new { results, next = Str(doc.RootElement, "next") ?? "" });
            }
            catch (Exception) { return Support.Error(502, "The GIF service is unavailable."); }
        }

        api.MapGet("/search", (string? q, string? pos, System.Security.Claims.ClaimsPrincipal me) =>
            string.IsNullOrWhiteSpace(q) || q.Length > 80 ? Task.FromResult(Support.Bad("Type something to search for.")) : Query("search", q.Trim(), pos, ""));

        api.MapGet("/trending", (string? pos) => Query("featured", null, pos, ""));

        api.MapGet("/media/{token}", async Task<IResult> (string token, HttpContext ctx) =>
        {
            if (!Known.TryGetValue(token, out var k) || k.Expires < DateTime.UtcNow) return Support.NotFound("Unknown or expired picture.");
            try
            {
                using var res = await Http.GetAsync(k.Url, HttpCompletionOption.ResponseHeadersRead);
                if (!res.IsSuccessStatusCode) return Support.Error(502, "Could not fetch the picture.");
                if (res.Content.Headers.ContentLength > MaxBytes) return Support.Error(413, "Picture too large.");
                var type = res.Content.Headers.ContentType?.MediaType ?? "";
                if (type != "image/gif" && type != "image/webp" && type != "image/png") return Support.Error(502, "Unexpected file type.");
                using var ms = new MemoryStream();
                await using var s = await res.Content.ReadAsStreamAsync();
                var buf = new byte[81920];
                int n;
                while ((n = await s.ReadAsync(buf)) > 0)
                {
                    ms.Write(buf, 0, n);
                    if (ms.Length > MaxBytes) return Support.Error(413, "Picture too large.");
                }
                ctx.Response.Headers.CacheControl = "private, max-age=86400";
                ctx.Response.Headers["X-Content-Type-Options"] = "nosniff";
                return Results.File(ms.ToArray(), type);
            }
            catch (Exception) { return Support.Error(502, "Could not fetch the picture."); }
        });
    }
}
