using System.Globalization;

namespace OpenSearchEventProducer.Indexing;

public sealed class DailyIndexNameResolver
{
    public string Resolve(string indexPrefix, DateTimeOffset timestamp)
    {
        return $"{indexPrefix}_{timestamp:yyyy_MM_dd}";
    }

    public bool TryResolveDate(string indexName, string indexPrefix, out DateOnly indexDate)
    {
        var expectedPrefix = $"{indexPrefix}_";
        if (!indexName.StartsWith(expectedPrefix, StringComparison.Ordinal))
        {
            indexDate = default;
            return false;
        }

        var datePart = indexName[expectedPrefix.Length..];
        return DateOnly.TryParseExact(
            datePart,
            "yyyy_MM_dd",
            CultureInfo.InvariantCulture,
            DateTimeStyles.None,
            out indexDate);
    }

    public long ResolveCreationDateEpochMilliseconds(DateOnly indexDate)
    {
        var utcMidnight = new DateTimeOffset(indexDate.ToDateTime(TimeOnly.MinValue, DateTimeKind.Utc));
        return utcMidnight.ToUnixTimeMilliseconds();
    }
}
