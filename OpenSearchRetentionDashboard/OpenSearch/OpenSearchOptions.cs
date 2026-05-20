namespace OpenSearchRetentionDashboard.OpenSearch;

public sealed class OpenSearchOptions
{
    public string Url { get; init; } = "http://localhost:9200";

    public string? Username { get; init; }

    public string? Password { get; init; }

    public string IndexPattern { get; init; } = "events_*,remote_events_*";

    public string SnapshotRepository { get; init; } = "dataskope_lifecycle_repo";
}
