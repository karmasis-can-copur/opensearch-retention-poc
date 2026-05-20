namespace OpenSearchEventProducer.Generation;

public sealed record GeneratedEvent(DateTimeOffset EventTimestamp, string Fingerprint, string Json);
