using OpenSearchEventProducer.Indexing;

namespace OpenSearchEventProducer.Tests;

public sealed class HotWindowFilterTests
{
    [Fact]
    public void IsWithinHotWindow_AcceptsTodayAndPreviousDaysInsideWindow()
    {
        var filter = new HotWindowFilter();
        var now = new DateTimeOffset(2026, 5, 6, 12, 0, 0, TimeSpan.Zero);

        Assert.True(filter.IsWithinHotWindow(now, now, hotWindowDays: 30));
        Assert.True(filter.IsWithinHotWindow(now.AddDays(-29), now, hotWindowDays: 30));
    }

    [Fact]
    public void IsWithinHotWindow_RejectsEventsOlderThanWindow()
    {
        var filter = new HotWindowFilter();
        var now = new DateTimeOffset(2026, 5, 6, 12, 0, 0, TimeSpan.Zero);

        Assert.False(filter.IsWithinHotWindow(now.AddDays(-30), now, hotWindowDays: 30));
        Assert.False(filter.IsWithinHotWindow(now.AddMonths(-3), now, hotWindowDays: 30));
    }

    [Fact]
    public void IsWithinHotWindow_RejectsFutureDatedEvents()
    {
        var filter = new HotWindowFilter();
        var now = new DateTimeOffset(2026, 5, 6, 12, 0, 0, TimeSpan.Zero);

        Assert.False(filter.IsWithinHotWindow(now.AddDays(1), now, hotWindowDays: 30));
    }
}
