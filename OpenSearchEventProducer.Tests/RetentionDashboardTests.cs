using OpenSearchRetentionDashboard.Capacity;
using OpenSearchRetentionDashboard.Retention;

namespace OpenSearchEventProducer.Tests;

public sealed class RetentionDashboardTests
{
    [Theory]
    [InlineData("events_2026_01_30", "hot", "", "hot")]
    [InlineData("events_2026_01_20", "cold", "", "cold")]
    [InlineData("remote_events_2026_01_01", "frozen", "remote_snapshot", "searchable_snapshot")]
    [InlineData("events_2026_01_01-frozen", "frozen", "", "searchable_snapshot")]
    public void RetentionIndexClassifier_ClassifiesStages(string indexName, string allocationTemp, string storeType, string expected)
    {
        var classifier = new RetentionIndexClassifier();

        var stage = classifier.Classify(indexName, allocationTemp, storeType);

        Assert.Equal(expected, stage);
    }

    [Fact]
    public void CapacityCalculator_UsesRetentionInputs()
    {
        var calculator = new CapacityCalculator();

        var output = calculator.Calculate(new CapacityInput(
            EventsPerSecond: 5000,
            HotDays: 10,
            ColdDays: 10,
            SearchableSnapshotDays: 41));

        Assert.True(output.EventsPerDay > 400_000_000);
        Assert.True(output.HotTiB > 6);
        Assert.True(output.SnapshotRepositoryTiB > output.HotTiB);
        Assert.True(output.SuggestedHotDataNodes >= 1);
    }
}
