using System.Text.Json;
using Microsoft.Extensions.Options;
using OpenSearchEventProducer.Configuration;
using OpenSearchEventProducer.Generation;

namespace OpenSearchEventProducer.Tests;

public class RandomEventGeneratorTests
{
    [Fact]
    public void Generate_ShouldMutateTemplateAndProduceValidJson()
    {
        var settings = Options.Create(new ProducerSettings
        {
            BatchSize = 10,
            DuplicateGuardWindowSize = 100,
            Enabled = true,
            EventsPerSecond = 10,
            TemplateFilePath = "unused",
            DryRun = true,
            RandomSeed = 42,
        });

        var generator = new RandomEventGenerator(settings);
        using var document = JsonDocument.Parse("""
        {
          "EventID": 4625,
          "TimeCreated": "2026-04-23T00:01:05.547Z",
          "ipaddress": "192.168.1.203",
          "targetusername": "karma\\can",
          "Severity": 0
        }
        """);
        var templates = new List<JsonElement> { document.RootElement.Clone() };

        var first = generator.Generate(templates);
        var second = generator.Generate(templates);

        Assert.False(string.IsNullOrWhiteSpace(first.Json));
        Assert.NotEqual(first.Fingerprint, second.Fingerprint);

        using var generatedJson = JsonDocument.Parse(first.Json);
        Assert.True(generatedJson.RootElement.TryGetProperty("EventID", out _));
        Assert.True(generatedJson.RootElement.TryGetProperty("TimeCreated", out _));
        Assert.Equal("2026-04-23T00:01:05.547Z", generatedJson.RootElement.GetProperty("TimeCreated").GetString());
        Assert.Equal(new DateTimeOffset(2026, 4, 23, 0, 1, 5, 547, TimeSpan.Zero), first.EventTimestamp);
    }
}
