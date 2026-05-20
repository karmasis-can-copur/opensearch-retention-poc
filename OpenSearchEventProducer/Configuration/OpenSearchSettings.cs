using System.ComponentModel.DataAnnotations;

namespace OpenSearchEventProducer.Configuration;

public sealed class OpenSearchSettings
{
    public const string SectionName = "OpenSearchSettings";

    [Range(0, int.MaxValue)]
    public int MaxConflictRetryCount { get; init; } = 3;

    [Range(0, int.MaxValue)]
    public int NumberOfReplicas { get; init; } = 1;

    [Range(1, int.MaxValue)]
    public int NumberOfShards { get; init; } = 3;

    [Required]
    public string Url { get; init; } = string.Empty;

    [Required]
    public string Username { get; init; } = string.Empty;

    [Required]
    public string Password { get; init; } = string.Empty;

    [Range(1, int.MaxValue)]
    public int ScrollThresholdLimit { get; init; } = 5000;

    [Range(1, int.MaxValue)]
    public int RequestTimeoutSeconds { get; init; } = 180;

    [Range(1, int.MaxValue)]
    public int MaxRetryTimeoutSeconds { get; init; } = 180;

    [Range(1, int.MaxValue)]
    public int ConnectionLimit { get; init; } = 30;

    [Range(1, int.MaxValue)]
    public int ConnectionLifetimeMinutes { get; init; } = 5;

    [Range(1, int.MaxValue)]
    public int BulkChunkSize { get; init; } = 250;

    [Range(1, int.MaxValue)]
    public int BulkMaxBytes { get; init; } = 10485760;

    [Range(1, int.MaxValue)]
    public int BulkMaxConcurrency { get; init; } = 4;

    [Required]
    public string IndexPrefix { get; init; } = "events";
}
