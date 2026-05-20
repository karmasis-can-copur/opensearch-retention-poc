namespace OpenSearchRetentionDashboard.Retention;

public sealed record RetentionIndex(
    string Name,
    string Stage,
    long Docs,
    long StoreBytes,
    long PrimaryStoreBytes,
    string Health,
    string Status,
    string AllocationTemp,
    string StoreType);

public sealed class RetentionIndexClassifier
{
    public string Classify(string indexName, string allocationTemp, string storeType)
    {
        if (indexName.StartsWith("remote_", StringComparison.OrdinalIgnoreCase) ||
            indexName.EndsWith("-frozen", StringComparison.OrdinalIgnoreCase) ||
            storeType.Equals("remote_snapshot", StringComparison.OrdinalIgnoreCase))
        {
            return "searchable_snapshot";
        }

        if (allocationTemp.Equals("cold", StringComparison.OrdinalIgnoreCase))
        {
            return "cold";
        }

        return "hot";
    }
}
