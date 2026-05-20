using OpenSearchRetentionDashboard.Retention;

namespace OpenSearchRetentionDashboard.Search;

public sealed record SafeSearchRequest(string TemplateId, string Stage = "all", string? From = null, string? To = null);

public sealed record SafeSearchTemplate(string Id, string Name, string Description);

public sealed class SafeSearchCatalog
{
    public IReadOnlyList<SafeSearchTemplate> Templates { get; } =
    [
        new("count", "Count documents", "size=0 count-style search with track_total_hits."),
        new("top_event_ids", "Top EventID values", "Small terms aggregation on EventID."),
        new("sample_recent", "Recent sample", "Returns up to 25 documents sorted by TimeCreated descending.")
    ];

    public object BuildQuery(SafeSearchRequest request)
    {
        var filter = BuildDateFilter(request);
        return request.TemplateId switch
        {
            "top_event_ids" => new
            {
                size = 0,
                timeout = "30s",
                query = filter,
                aggs = new
                {
                    event_ids = new
                    {
                        terms = new
                        {
                            field = "EventID",
                            size = 10
                        }
                    }
                }
            },
            "sample_recent" => new
            {
                size = 25,
                timeout = "30s",
                track_total_hits = false,
                sort = new object[]
                {
                    new Dictionary<string, object>
                    {
                        ["TimeCreated"] = new
                        {
                            order = "desc",
                            unmapped_type = "date"
                        }
                    }
                },
                query = filter
            },
            _ => new
            {
                size = 0,
                timeout = "30s",
                track_total_hits = true,
                query = filter
            }
        };
    }

    public string[] ResolveIndexes(SafeSearchRequest request, IReadOnlyList<RetentionIndex> indices)
    {
        var stage = string.IsNullOrWhiteSpace(request.Stage) ? "all" : request.Stage.Trim().ToLowerInvariant();
        var selected = stage == "all"
            ? indices
            : indices.Where(index => index.Stage.Equals(stage, StringComparison.OrdinalIgnoreCase));

        return selected
            .Select(index => index.Name)
            .OrderBy(name => name, StringComparer.Ordinal)
            .ToArray();
    }

    private static object BuildDateFilter(SafeSearchRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.From) && string.IsNullOrWhiteSpace(request.To))
        {
            return new
            {
                match_all = new { }
            };
        }

        var range = new Dictionary<string, object>();
        if (!string.IsNullOrWhiteSpace(request.From))
        {
            range["gte"] = request.From;
        }

        if (!string.IsNullOrWhiteSpace(request.To))
        {
            range["lte"] = request.To;
        }

        return new
        {
            range = new Dictionary<string, object>
            {
                ["TimeCreated"] = range
            }
        };
    }
}
