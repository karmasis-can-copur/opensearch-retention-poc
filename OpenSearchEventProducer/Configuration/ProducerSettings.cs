using System.ComponentModel.DataAnnotations;

namespace OpenSearchEventProducer.Configuration;

public sealed class ProducerSettings
{
    public const string SectionName = "Producer";

    public bool Enabled { get; init; } = true;

    [Range(1, 50000)]
    public int EventsPerSecond { get; init; } = 20;

    [Range(1, 10000)]
    public int BatchSize { get; init; } = 200;

    [Required]
    public string TemplateFilePath { get; init; } = string.Empty;

    public int? RandomSeed { get; init; }

    public bool DryRun { get; init; }

    public bool PreserveDateFields { get; init; } = true;

    public bool ReplayInputFile { get; init; }

    public bool DropEventsOutsideHotWindow { get; init; } = true;

    [Range(1, 3660)]
    public int HotWindowDays { get; init; } = 30;

    public string? RejectedEventsDumpFilePath { get; init; }

    [Range(1, 100000)]
    public int DuplicateGuardWindowSize { get; init; } = 5000;

    [Range(1, long.MaxValue)]
    public long? StopAfterEvents { get; init; }
}
