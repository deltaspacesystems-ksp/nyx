using System.Net;
using System.Net.Http.Headers;

namespace Nyx.Server.Tests;

public class UpdatesTests : IClassFixture<TestApp>
{
    readonly TestApp app;
    public UpdatesTests(TestApp app) { this.app = app; }

    async Task Publish()
    {
        Directory.CreateDirectory(app.DownloadsDir);
        await File.WriteAllBytesAsync(Path.Combine(app.DownloadsDir, "Nyx-windows-1.1.0.zip"), Enumerable.Range(0, 3000).Select(i => (byte)i).ToArray());
        await File.WriteAllBytesAsync(Path.Combine(app.DownloadsDir, "Nyx-windows-1.2.0.zip"), Enumerable.Range(0, 4000).Select(i => (byte)(i * 7)).ToArray());
        await File.WriteAllTextAsync(Path.Combine(app.DownloadsDir, "releases.json"), """
            { "releases": [
              { "version": "1.2.0", "released": "2026-09-30", "notes": ["Friends list", "Fixed black screen share"], "files": { "windows": "Nyx-windows-1.2.0.zip" } },
              { "version": "1.1.0", "released": "2026-09-20", "notes": ["Crop avatars"], "files": { "windows": "Nyx-windows-1.1.0.zip" } },
              { "version": "1.3.0", "notes": ["Linux only"], "files": { "linux": "missing.appimage" } }
            ] }
            """);
    }

    [Fact]
    public async Task Update_check_needs_login()
    {
        Assert.Equal(HttpStatusCode.Unauthorized, (await app.CreateClient().GetAsync("/api/app/update?platform=windows&current=1.0.0")).StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, (await app.CreateClient().GetAsync("/api/app/update/file?platform=windows&version=1.2.0")).StatusCode);
    }

    [Fact]
    public async Task Reports_newest_release_with_the_changelog_since_the_current_version()
    {
        var u = await app.Register("up");
        await Publish();

        var (s, r) = await u.Get("/api/app/update?platform=windows&current=1.0.0%2B5");
        Assert.Equal(HttpStatusCode.OK, s);
        Assert.True(r.GetProperty("available").GetBoolean());
        Assert.Equal("1.2.0", r.GetProperty("version").GetString()); // 1.3.0 has no windows file
        Assert.Equal(4000, r.GetProperty("size").GetInt64());
        Assert.Matches("[0-9a-f]{64}", r.GetProperty("sha256").GetString()!);
        var log = r.GetProperty("changelog").EnumerateArray().ToList();
        Assert.Equal(new[] { "1.2.0", "1.1.0" }, log.Select(l => l.GetProperty("version").GetString()!).ToArray());
        Assert.Contains(log[0].GetProperty("notes").EnumerateArray(), n => n.GetString() == "Fixed black screen share");

        var (_, mid) = await u.Get("/api/app/update?platform=windows&current=1.1.0");
        Assert.Single(mid.GetProperty("changelog").EnumerateArray());

        Assert.False((await u.Get("/api/app/update?platform=windows&current=1.2.0")).Body.GetProperty("available").GetBoolean());
        Assert.False((await u.Get("/api/app/update?platform=windows&current=9.0.0")).Body.GetProperty("available").GetBoolean());
        Assert.False((await u.Get("/api/app/update?platform=android&current=1.0.0")).Body.GetProperty("available").GetBoolean());
        Assert.False((await u.Get("/api/app/update?platform=windows&current=garbage")).Body.GetProperty("available").GetBoolean());
        Assert.Equal(HttpStatusCode.BadRequest, (await u.Get("/api/app/update?current=1.0.0")).Status);
    }

    [Fact]
    public async Task File_is_served_only_for_listed_releases()
    {
        var u = await app.Register("uf");
        await Publish();
        u.Http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", u.Access);
        var ok = await u.Http.GetAsync("/api/app/update/file?platform=windows&version=1.2.0");
        Assert.Equal(HttpStatusCode.OK, ok.StatusCode);
        Assert.Equal(4000, (await ok.Content.ReadAsByteArrayAsync()).Length);
        Assert.Equal(HttpStatusCode.NotFound, (await u.Http.GetAsync("/api/app/update/file?platform=windows&version=9.9.9")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await u.Http.GetAsync("/api/app/update/file?platform=linux&version=1.3.0")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await u.Http.GetAsync("/api/app/update/file?platform=..%2F..%2Fx&version=1.2.0")).StatusCode);
    }

    [Fact]
    public async Task Manifest_file_itself_is_not_downloadable()
    {
        await Publish();
        Assert.Equal(HttpStatusCode.NotFound, (await app.CreateClient().GetAsync("/downloadnyx/files/releases.json")).StatusCode);
    }
}
