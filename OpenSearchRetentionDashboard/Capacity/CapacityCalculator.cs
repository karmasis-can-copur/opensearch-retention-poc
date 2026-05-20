namespace OpenSearchRetentionDashboard.Capacity;

public sealed record CapacityInput(
    double EventsPerSecond,
    int HotDays,
    int ColdDays,
    int SearchableSnapshotDays,
    double HotBytesPerEvent = 1606,
    double ColdBytesPerEvent = 1510,
    double SnapshotBytesPerEvent = 1510,
    double WarmCacheBytesPerEvent = 705,
    double RawBytesPerEvent = 1056,
    double ReplicaFactor = 1,
    double DiskHeadroomFactor = 1.3);

public sealed record CapacityOutput(
    double EventsPerDay,
    double RawTiB,
    double HotTiB,
    double ColdTiB,
    double SnapshotRepositoryTiB,
    double WarmCacheTiB,
    double LocalClusterTiB,
    double LocalClusterWithHeadroomTiB,
    int SuggestedHotDataNodes,
    int SuggestedColdDataNodes,
    int SuggestedWarmNodes,
    string Summary);

public sealed class CapacityCalculator
{
    private const double BytesPerTiB = 1099511627776d;
    private const double TargetUsableTiBPerHotNode = 2.5d;
    private const double TargetUsableTiBPerColdNode = 4.0d;
    private const double TargetUsableTiBPerWarmNode = 1.0d;

    public CapacityOutput Calculate(CapacityInput input)
    {
        var eventsPerDay = input.EventsPerSecond * 86400d;
        var rawBytes = eventsPerDay * (input.HotDays + input.ColdDays + input.SearchableSnapshotDays) * input.RawBytesPerEvent;
        var hotBytes = eventsPerDay * input.HotDays * input.HotBytesPerEvent * input.ReplicaFactor;
        var coldBytes = eventsPerDay * input.ColdDays * input.ColdBytesPerEvent * input.ReplicaFactor;
        var snapshotBytes = eventsPerDay * input.SearchableSnapshotDays * input.SnapshotBytesPerEvent;
        var warmCacheBytes = eventsPerDay * input.SearchableSnapshotDays * input.WarmCacheBytesPerEvent;
        var localClusterBytes = hotBytes + coldBytes + warmCacheBytes;
        var localClusterWithHeadroomBytes = localClusterBytes * input.DiskHeadroomFactor;

        var hotTiB = ToTiB(hotBytes);
        var coldTiB = ToTiB(coldBytes);
        var warmTiB = ToTiB(warmCacheBytes);

        return new CapacityOutput(
            EventsPerDay: eventsPerDay,
            RawTiB: ToTiB(rawBytes),
            HotTiB: hotTiB,
            ColdTiB: coldTiB,
            SnapshotRepositoryTiB: ToTiB(snapshotBytes),
            WarmCacheTiB: warmTiB,
            LocalClusterTiB: ToTiB(localClusterBytes),
            LocalClusterWithHeadroomTiB: ToTiB(localClusterWithHeadroomBytes),
            SuggestedHotDataNodes: Math.Max(1, (int)Math.Ceiling(hotTiB / TargetUsableTiBPerHotNode)),
            SuggestedColdDataNodes: Math.Max(1, (int)Math.Ceiling(coldTiB / TargetUsableTiBPerColdNode)),
            SuggestedWarmNodes: Math.Max(1, (int)Math.Ceiling(warmTiB / TargetUsableTiBPerWarmNode)),
            Summary: "Use the output as a first sizing estimate, then rerun with measured coefficients from the real dump load test.");
    }

    private static double ToTiB(double bytes)
    {
        return Math.Round(bytes / BytesPerTiB, 2);
    }
}
