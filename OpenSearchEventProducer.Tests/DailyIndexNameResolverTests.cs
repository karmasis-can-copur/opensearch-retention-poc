using OpenSearchEventProducer.Indexing;

namespace OpenSearchEventProducer.Tests;

public class DailyIndexNameResolverTests
{
    [Fact]
    public void Resolve_ShouldReturnDailyIndexName()
    {
        var resolver = new DailyIndexNameResolver();
        var timestamp = new DateTimeOffset(2026, 4, 30, 12, 0, 0, TimeSpan.Zero);

        var index = resolver.Resolve("events", timestamp);

        Assert.Equal("events_2026_04_30", index);
    }

    [Fact]
    public void TryResolveDate_ShouldParseDailyIndexName()
    {
        var resolver = new DailyIndexNameResolver();

        var resolved = resolver.TryResolveDate("events_2026_01_01", "events", out var indexDate);

        Assert.True(resolved);
        Assert.Equal(new DateOnly(2026, 1, 1), indexDate);
    }

    [Fact]
    public void TryResolveDate_ShouldRejectNonDailyIndexName()
    {
        var resolver = new DailyIndexNameResolver();

        var resolved = resolver.TryResolveDate("events_2026_01_01-frozen", "events", out _);

        Assert.False(resolved);
    }

    [Fact]
    public void ResolveCreationDateEpochMilliseconds_ShouldUseUtcMidnight()
    {
        var resolver = new DailyIndexNameResolver();

        var epochMillis = resolver.ResolveCreationDateEpochMilliseconds(new DateOnly(2026, 1, 1));

        Assert.Equal(1767225600000, epochMillis);
    }
}
