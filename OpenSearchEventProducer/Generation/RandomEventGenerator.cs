using System.Collections.Concurrent;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using OpenSearchEventProducer.Configuration;

namespace OpenSearchEventProducer.Generation;

public sealed class RandomEventGenerator
{
    private const int MinPort = 1024;
    private const int MaxPort = 65535;

    private readonly Random _random;
    private readonly ConcurrentQueue<string> _recentFingerprints = new();
    private readonly HashSet<string> _fingerprintSet = [];
    private readonly object _fingerprintLock = new();
    private readonly ProducerSettings _settings;

    public RandomEventGenerator(Microsoft.Extensions.Options.IOptions<ProducerSettings> producerOptions)
    {
        _settings = producerOptions.Value;
        _random = _settings.RandomSeed.HasValue ? new Random(_settings.RandomSeed.Value) : Random.Shared;
    }

    public GeneratedEvent Generate(IReadOnlyList<JsonElement> templates)
    {
        if (templates.Count == 0)
        {
            throw new InvalidOperationException("Template list is empty.");
        }

        var selectedTemplate = templates[_random.Next(templates.Count)];
        var now = DateTimeOffset.UtcNow;
        using var stream = new MemoryStream();
        using var writer = new Utf8JsonWriter(stream);

        writer.WriteStartObject();
        foreach (var property in selectedTemplate.EnumerateObject())
        {
            WriteMutatedProperty(writer, property, now);
        }
        writer.WriteEndObject();
        writer.Flush();

        var payload = Encoding.UTF8.GetString(stream.ToArray());
        var eventTimestamp = ResolveEventTimestamp(payload, now);
        var fingerprint = ComputeFingerprint(payload);

        lock (_fingerprintLock)
        {
            if (_fingerprintSet.Contains(fingerprint))
            {
                payload = AddCollisionBreaker(payload);
                fingerprint = ComputeFingerprint(payload);
            }

            _fingerprintSet.Add(fingerprint);
            _recentFingerprints.Enqueue(fingerprint);
            while (_recentFingerprints.Count > _settings.DuplicateGuardWindowSize && _recentFingerprints.TryDequeue(out var old))
            {
                _fingerprintSet.Remove(old);
            }
        }

        return new GeneratedEvent(eventTimestamp, fingerprint, payload);
    }

    private void WriteMutatedProperty(Utf8JsonWriter writer, JsonProperty property, DateTimeOffset now)
    {
        writer.WritePropertyName(property.Name);
        WriteMutatedValue(writer, property.Name, property.Value, now);
    }

    private void WriteMutatedValue(Utf8JsonWriter writer, string propertyName, JsonElement value, DateTimeOffset now)
    {
        switch (value.ValueKind)
        {
            case JsonValueKind.Object:
                writer.WriteStartObject();
                foreach (var nested in value.EnumerateObject())
                {
                    writer.WritePropertyName(nested.Name);
                    WriteMutatedValue(writer, nested.Name, nested.Value, now);
                }
                writer.WriteEndObject();
                break;
            case JsonValueKind.Array:
                writer.WriteStartArray();
                var items = value.EnumerateArray().ToList();
                if (items.Count > 1)
                {
                    items = items.OrderBy(_ => _random.Next()).ToList();
                }

                foreach (var item in items)
                {
                    WriteMutatedValue(writer, propertyName, item, now);
                }

                writer.WriteEndArray();
                break;
            case JsonValueKind.String:
                writer.WriteStringValue(MutateString(propertyName, value.GetString(), now));
                break;
            case JsonValueKind.Number:
                WriteMutatedNumber(writer, propertyName, value);
                break;
            case JsonValueKind.True:
            case JsonValueKind.False:
                writer.WriteBooleanValue(_random.NextDouble() >= 0.5);
                break;
            case JsonValueKind.Null:
            case JsonValueKind.Undefined:
                writer.WriteNullValue();
                break;
            default:
                value.WriteTo(writer);
                break;
        }
    }

    private static bool IsDateLike(string propertyName)
    {
        return propertyName.Contains("time", StringComparison.OrdinalIgnoreCase)
               || propertyName.Contains("date", StringComparison.OrdinalIgnoreCase);
    }

    private string MutateString(string propertyName, string? original, DateTimeOffset now)
    {
        if (string.IsNullOrWhiteSpace(original))
        {
            return $"v-{Guid.NewGuid():N}";
        }

        if (propertyName.Contains("id", StringComparison.OrdinalIgnoreCase)
            || propertyName.Contains("hash", StringComparison.OrdinalIgnoreCase))
        {
            return Guid.NewGuid().ToString("N");
        }

        if (propertyName.Contains("ip", StringComparison.OrdinalIgnoreCase))
        {
            return $"10.{_random.Next(1, 255)}.{_random.Next(1, 255)}.{_random.Next(1, 255)}";
        }

        if (propertyName.Contains("port", StringComparison.OrdinalIgnoreCase))
        {
            return _random.Next(MinPort, MaxPort).ToString();
        }

        if (IsDateLike(propertyName) && DateTimeOffset.TryParse(original, out _))
        {
            if (_settings.PreserveDateFields)
            {
                return original;
            }

            return now.AddSeconds(_random.Next(-120, 120)).ToString("O");
        }

        var suffix = _random.Next(1000, 9999);
        return $"{original}_{suffix}";
    }

    private void WriteMutatedNumber(Utf8JsonWriter writer, string propertyName, JsonElement value)
    {
        if (value.TryGetInt64(out var intValue))
        {
            if (propertyName.Contains("id", StringComparison.OrdinalIgnoreCase)
                || propertyName.Contains("event", StringComparison.OrdinalIgnoreCase))
            {
                writer.WriteNumberValue(Math.Abs(intValue + _random.Next(1, 500)));
                return;
            }

            var delta = _random.Next(-25, 26);
            writer.WriteNumberValue(intValue + delta);
            return;
        }

        if (value.TryGetDouble(out var doubleValue))
        {
            var factor = 0.9 + (_random.NextDouble() * 0.2);
            writer.WriteNumberValue(doubleValue * factor);
            return;
        }

        value.WriteTo(writer);
    }

    private static string ComputeFingerprint(string payload)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(payload));
        return Convert.ToHexString(hash);
    }

    private static string AddCollisionBreaker(string payload)
    {
        using var document = JsonDocument.Parse(payload);
        using var stream = new MemoryStream();
        using var writer = new Utf8JsonWriter(stream);
        writer.WriteStartObject();

        foreach (var property in document.RootElement.EnumerateObject())
        {
            property.WriteTo(writer);
        }

        writer.WriteString("_producerNonce", Guid.NewGuid().ToString("N"));
        writer.WriteEndObject();
        writer.Flush();

        return Encoding.UTF8.GetString(stream.ToArray());
    }

    private static DateTimeOffset ResolveEventTimestamp(string payload, DateTimeOffset fallback)
    {
        using var document = JsonDocument.Parse(payload);
        if (TryResolveEventTimestamp(document.RootElement, out var timestamp))
        {
            return timestamp;
        }

        return fallback;
    }

    private static bool TryResolveEventTimestamp(JsonElement element, out DateTimeOffset timestamp)
    {
        foreach (var fieldName in new[] { "TimeCreated", "@timestamp", "EventTime", "Timestamp", "TimeInserted" })
        {
            if (!element.TryGetProperty(fieldName, out var field))
            {
                continue;
            }

            if (field.ValueKind == JsonValueKind.String
                && DateTimeOffset.TryParse(field.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out timestamp))
            {
                timestamp = timestamp.ToUniversalTime();
                return true;
            }
        }

        if (element.ValueKind == JsonValueKind.Object)
        {
            foreach (var property in element.EnumerateObject())
            {
                if (property.Value.ValueKind == JsonValueKind.Object &&
                    TryResolveEventTimestamp(property.Value, out timestamp))
                {
                    return true;
                }
            }
        }

        timestamp = default;
        return false;
    }
}
