using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using OpenSearchEventProducer.Generation;

namespace OpenSearchEventProducer.Parsing;

public sealed class ElasticDumpEventParser
{
    private static readonly string[] TimestampFieldNames =
    [
        "TimeCreated",
        "@timestamp",
        "EventTime",
        "Timestamp",
        "TimeInserted"
    ];

    public bool TryParseLine(string line, DateTimeOffset fallback, out GeneratedEvent generatedEvent, out string error)
    {
        generatedEvent = default!;
        error = string.Empty;

        if (string.IsNullOrWhiteSpace(line))
        {
            error = "Line is empty.";
            return false;
        }

        try
        {
            using var document = JsonDocument.Parse(line);
            var payloadElement = document.RootElement;
            if (document.RootElement.ValueKind == JsonValueKind.Object &&
                document.RootElement.TryGetProperty("_source", out var source))
            {
                payloadElement = source;
            }

            var payload = payloadElement.GetRawText();
            if (!TryResolveEventTimestamp(payloadElement, out var timestamp))
            {
                timestamp = fallback;
            }

            generatedEvent = new GeneratedEvent(timestamp, ComputeFingerprint(payload), payload);
            return true;
        }
        catch (JsonException ex)
        {
            error = ex.Message;
            return false;
        }
    }

    private static string ComputeFingerprint(string payload)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(payload));
        return Convert.ToHexString(hash);
    }

    private static bool TryResolveEventTimestamp(JsonElement element, out DateTimeOffset timestamp)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            timestamp = default;
            return false;
        }

        foreach (var fieldName in TimestampFieldNames)
        {
            if (!element.TryGetProperty(fieldName, out var field))
            {
                continue;
            }

            if (field.ValueKind == JsonValueKind.String &&
                DateTimeOffset.TryParse(field.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out timestamp))
            {
                timestamp = timestamp.ToUniversalTime();
                return true;
            }
        }

        foreach (var property in element.EnumerateObject())
        {
            if (property.Value.ValueKind == JsonValueKind.Object &&
                TryResolveEventTimestamp(property.Value, out timestamp))
            {
                return true;
            }
        }

        timestamp = default;
        return false;
    }
}
