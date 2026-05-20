using OpenSearchEventProducer.Parsing;

namespace OpenSearchEventProducer.Tests;

public sealed class ElasticDumpEventParserTests
{
    [Fact]
    public void TryParseLine_UsesSourcePayloadAndTimeCreated()
    {
        var parser = new ElasticDumpEventParser();
        var line = """
                   {"_index":"events_2025_12_01","_id":"42","_source":{"TimeCreated":"2025-12-01T12:13:14.000Z","EventID":4624,"Message":"ok"}}
                   """;

        var parsed = parser.TryParseLine(line, DateTimeOffset.UnixEpoch, out var generatedEvent, out var error);

        Assert.True(parsed, error);
        Assert.Equal(DateTimeOffset.Parse("2025-12-01T12:13:14.000Z"), generatedEvent.EventTimestamp);
        Assert.Contains("\"EventID\":4624", generatedEvent.Json);
        Assert.DoesNotContain("\"_index\"", generatedEvent.Json);
    }

    [Fact]
    public void TryParseLine_FallsBackWhenTimestampIsMissing()
    {
        var parser = new ElasticDumpEventParser();
        var fallback = DateTimeOffset.Parse("2026-01-30T00:00:00Z");

        var parsed = parser.TryParseLine("""{"EventID":1}""", fallback, out var generatedEvent, out var error);

        Assert.True(parsed, error);
        Assert.Equal(fallback, generatedEvent.EventTimestamp);
    }
}
