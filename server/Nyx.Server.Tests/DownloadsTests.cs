using System.Net;

namespace Nyx.Server.Tests;

public class DownloadsTests : IClassFixture<TestApp>
{
    readonly TestApp app;
    public DownloadsTests(TestApp app) { this.app = app; }

    [Fact]
    public async Task Download_page_and_latest_work_without_signing_in_and_serve_the_newest_zip()
    {
        var http = app.CreateClient();
        Assert.Equal(HttpStatusCode.NotFound, (await http.GetAsync("/downloadnyx/latest")).StatusCode); // nothing yet
        var empty = await (await http.GetAsync("/downloadnyx")).Content.ReadAsStringAsync();
        Assert.Contains("No downloads", empty);

        Directory.CreateDirectory(app.DownloadsDir);
        var old = Path.Combine(app.DownloadsDir, "Nyx-windows-1.zip");
        var cur = Path.Combine(app.DownloadsDir, "Nyx-windows-2.zip");
        await File.WriteAllBytesAsync(old, [1, 2, 3]);
        File.SetLastWriteTimeUtc(old, DateTime.UtcNow.AddDays(-2));
        await File.WriteAllBytesAsync(cur, Enumerable.Range(0, 5000).Select(i => (byte)i).ToArray());
        await File.WriteAllTextAsync(Path.Combine(app.DownloadsDir, "secret.txt"), "not a release");

        var page = await http.GetStringAsync("/downloadnyx");
        Assert.Contains("Download latest", page);
        Assert.Contains("Nyx-windows-2.zip", page);
        Assert.Contains("Nyx-windows-1.zip", page);
        Assert.DoesNotContain("secret.txt", page); // only release file types are listed
        Assert.Matches("[0-9a-f]{64}", page);      // checksum shown

        var latest = await http.GetAsync("/downloadnyx/latest");
        Assert.Equal(HttpStatusCode.OK, latest.StatusCode);
        Assert.Equal("Nyx-windows-2.zip", latest.Content.Headers.ContentDisposition!.FileName);
        Assert.Equal(5000, (await latest.Content.ReadAsByteArrayAsync()).Length);

        Assert.Equal(HttpStatusCode.OK, (await http.GetAsync("/downloadnyx/files/Nyx-windows-1.zip")).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await http.GetAsync("/downloadnyx/latest?platform=windows")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await http.GetAsync("/downloadnyx/latest?platform=android")).StatusCode);
    }

    [Theory]
    [InlineData("secret.txt")]
    [InlineData("..%2Fserver.key")]
    [InlineData("..%5Cserver.key")]
    [InlineData("%2e%2e%2fappsettings.json")]
    [InlineData("nope.zip")]
    public async Task Only_listed_release_files_can_be_fetched_and_never_by_path(string name)
    {
        Directory.CreateDirectory(app.DownloadsDir);
        await File.WriteAllTextAsync(Path.Combine(app.DownloadsDir, "secret.txt"), "private");
        var res = await app.CreateClient().GetAsync("/downloadnyx/files/" + name);
        Assert.NotEqual(HttpStatusCode.OK, res.StatusCode);
    }

    [Fact]
    public async Task Ranges_are_supported_for_large_downloads()
    {
        Directory.CreateDirectory(app.DownloadsDir);
        await File.WriteAllBytesAsync(Path.Combine(app.DownloadsDir, "Nyx-linux.zip"), new byte[1000]);
        var req = new HttpRequestMessage(HttpMethod.Get, "/downloadnyx/files/Nyx-linux.zip") { Headers = { Range = new System.Net.Http.Headers.RangeHeaderValue(0, 99) } };
        var res = await app.CreateClient().SendAsync(req);
        Assert.Equal(HttpStatusCode.PartialContent, res.StatusCode);
        Assert.Equal(100, (await res.Content.ReadAsByteArrayAsync()).Length);
    }
}
