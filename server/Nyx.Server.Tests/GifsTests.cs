using System.Net;

namespace Nyx.Server.Tests;

public class GifsTests : IClassFixture<TestApp>
{
    readonly TestApp app;
    public GifsTests(TestApp app) { this.app = app; }

    [Fact]
    public async Task Gif_search_needs_login_and_reports_when_it_is_not_configured()
    {
        Assert.Equal(HttpStatusCode.Unauthorized, (await app.CreateClient().GetAsync("/api/gifs/search?q=cat")).StatusCode);
        var u = await app.Register("gif");
        Assert.False((await u.Get("/api/gifs/status")).Body.GetProperty("enabled").GetBoolean());
        Assert.Equal(HttpStatusCode.NotImplemented, (await u.Get("/api/gifs/search?q=cat")).Status);
        Assert.Equal(HttpStatusCode.NotImplemented, (await u.Get("/api/gifs/trending")).Status);
        Assert.Equal(HttpStatusCode.BadRequest, (await u.Get("/api/gifs/search")).Status);
    }

    [Fact]
    public async Task Media_proxy_only_serves_urls_that_came_from_a_search()
    {
        var u = await app.Register("gifm");
        Assert.Equal(HttpStatusCode.NotFound, (await u.Get("/api/gifs/media/0123456789abcdef01234567")).Status);
        Assert.Equal(HttpStatusCode.NotFound, (await u.Get("/api/gifs/media/https%3A%2F%2Fexample.com%2Fa.gif")).Status);
    }
}
