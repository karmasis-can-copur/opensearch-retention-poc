using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using OpenSearchEventProducer.Configuration;
using OpenSearchEventProducer.Generation;
using OpenSearchEventProducer.Indexing;
using OpenSearchEventProducer.Parsing;
using OpenSearchEventProducer.Publishing;

namespace OpenSearchEventProducer.Worker;

public sealed class ProducerWorker : BackgroundService
{
    private readonly ProducerSettings _producerSettings;
    private readonly OpenSearchSettings _openSearchSettings;
    private readonly EventTemplateLoader _templateLoader;
    private readonly ElasticDumpEventParser _elasticDumpEventParser;
    private readonly RandomEventGenerator _eventGenerator;
    private readonly DailyIndexNameResolver _indexResolver;
    private readonly HotWindowFilter _hotWindowFilter;
    private readonly OpenSearchPublisher _publisher;
    private readonly IHostApplicationLifetime _hostApplicationLifetime;
    private readonly ILogger<ProducerWorker> _logger;

    public ProducerWorker(
        IOptions<ProducerSettings> producerSettings,
        IOptions<OpenSearchSettings> openSearchSettings,
        EventTemplateLoader templateLoader,
        ElasticDumpEventParser elasticDumpEventParser,
        RandomEventGenerator eventGenerator,
        DailyIndexNameResolver indexResolver,
        HotWindowFilter hotWindowFilter,
        OpenSearchPublisher publisher,
        IHostApplicationLifetime hostApplicationLifetime,
        ILogger<ProducerWorker> logger)
    {
        _producerSettings = producerSettings.Value;
        _openSearchSettings = openSearchSettings.Value;
        _templateLoader = templateLoader;
        _elasticDumpEventParser = elasticDumpEventParser;
        _eventGenerator = eventGenerator;
        _indexResolver = indexResolver;
        _hotWindowFilter = hotWindowFilter;
        _publisher = publisher;
        _hostApplicationLifetime = hostApplicationLifetime;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!_producerSettings.Enabled)
        {
            _logger.LogWarning("Producer is disabled by configuration.");
            return;
        }

        if (_producerSettings.DropEventsOutsideHotWindow &&
            !_producerSettings.DryRun &&
            string.IsNullOrWhiteSpace(_producerSettings.RejectedEventsDumpFilePath))
        {
            throw new InvalidOperationException(
                "Producer:RejectedEventsDumpFilePath is required when Producer:DropEventsOutsideHotWindow=true. Refusing to drop out-of-window events without a durable dump file.");
        }

        await WaitForOpenSearchAsync(stoppingToken);

        if (_producerSettings.ReplayInputFile)
        {
            await RunReplayInputFileAsync(stoppingToken);
            return;
        }

        var templates = _templateLoader.LoadTemplates(_producerSettings.TemplateFilePath);
        _logger.LogInformation("Loaded template count: {TemplateCount}", templates.Count);

        var sentTotal = 0L;
        var rejectedTotal = 0L;
        var startedAt = DateTimeOffset.UtcNow;
        var lastCountLoggedAt = DateTimeOffset.MinValue;
        StreamWriter? rejectedWriter = null;

        try
        {
            if (!string.IsNullOrWhiteSpace(_producerSettings.RejectedEventsDumpFilePath))
            {
                var dumpDirectory = Path.GetDirectoryName(_producerSettings.RejectedEventsDumpFilePath);
                if (!string.IsNullOrWhiteSpace(dumpDirectory))
                {
                    Directory.CreateDirectory(dumpDirectory);
                }

                rejectedWriter = new StreamWriter(_producerSettings.RejectedEventsDumpFilePath, append: true);
            }

            while (!stoppingToken.IsCancellationRequested)
            {
                var windowStart = DateTimeOffset.UtcNow;
                var bucket = new List<GeneratedEvent>(_producerSettings.BatchSize);

                for (var i = 0; i < _producerSettings.EventsPerSecond; i++)
                {
                    bucket.Add(_eventGenerator.Generate(templates));
                }

                var now = DateTimeOffset.UtcNow;
                var acceptedBucket = new List<GeneratedEvent>(bucket.Count);
                var rejectedBucket = new List<GeneratedEvent>();

                foreach (var item in bucket)
                {
                    if (!_producerSettings.DropEventsOutsideHotWindow ||
                        _hotWindowFilter.IsWithinHotWindow(item.EventTimestamp, now, _producerSettings.HotWindowDays))
                    {
                        acceptedBucket.Add(item);
                    }
                    else
                    {
                        rejectedBucket.Add(item);
                    }
                }

                if (rejectedBucket.Count > 0)
                {
                    rejectedTotal += rejectedBucket.Count;
                    if (rejectedWriter is not null)
                    {
                        foreach (var rejected in rejectedBucket)
                        {
                            await rejectedWriter.WriteLineAsync(rejected.Json);
                        }

                        await rejectedWriter.FlushAsync(stoppingToken);
                    }
                }

                if (_producerSettings.DryRun)
                {
                    var indexCount = acceptedBucket.Select(item => _indexResolver.Resolve(_openSearchSettings.IndexPrefix, item.EventTimestamp)).Distinct().Count();
                    _logger.LogInformation(
                        "DryRun active. Generated {GeneratedCount} events, accepted {AcceptedCount}, rejected {RejectedCount} across {IndexCount} daily indexes.",
                        bucket.Count,
                        acceptedBucket.Count,
                        rejectedBucket.Count,
                        indexCount);
                }
                else
                {
                    var groupedByIndex = acceptedBucket
                        .GroupBy(item => _indexResolver.Resolve(_openSearchSettings.IndexPrefix, item.EventTimestamp))
                        .ToList();

                    var publishTasks = new List<Task>();
                    using var concurrency = new SemaphoreSlim(_openSearchSettings.BulkMaxConcurrency);

                    foreach (var group in groupedByIndex)
                    {
                        foreach (var chunk in Chunk(group.ToList(), _openSearchSettings.BulkChunkSize))
                        {
                            await concurrency.WaitAsync(stoppingToken);
                            publishTasks.Add(PublishChunkAsync(group.Key, chunk, concurrency, stoppingToken));
                        }
                    }

                    await Task.WhenAll(publishTasks);

                    sentTotal += acceptedBucket.Count;
                    var elapsed = DateTimeOffset.UtcNow - startedAt;
                    var avgRate = sentTotal / Math.Max(1, elapsed.TotalSeconds);

                    _logger.LogInformation(
                        "Published {PublishedCount} events, rejected {RejectedCount} outside hot window across {IndexCount} daily indexes. SentTotal={SentTotal}, RejectedTotal={RejectedTotal}, AvgRate={AvgRate:F2} ev/s",
                        acceptedBucket.Count,
                        rejectedBucket.Count,
                        groupedByIndex.Count,
                        sentTotal,
                        rejectedTotal,
                        avgRate);

                    if (groupedByIndex.Count > 0 && (now - lastCountLoggedAt) >= TimeSpan.FromSeconds(10))
                    {
                        var indexName = groupedByIndex[0].Key;
                        var count = await _publisher.GetDocumentCountAsync(indexName, stoppingToken);
                        _logger.LogInformation("Index count check for {Index}: {Count}", indexName, count);
                        lastCountLoggedAt = now;
                    }

                    var processedTotal = sentTotal + rejectedTotal;
                    if (_producerSettings.StopAfterEvents.HasValue && processedTotal >= _producerSettings.StopAfterEvents.Value)
                    {
                        _logger.LogInformation(
                            "StopAfterEvents reached. ProcessedTotal={ProcessedTotal}, SentTotal={SentTotal}, StopAfterEvents={StopAfterEvents}, RejectedTotal={RejectedTotal}",
                            processedTotal,
                            sentTotal,
                            _producerSettings.StopAfterEvents.Value,
                            rejectedTotal);
                        _hostApplicationLifetime.StopApplication();
                        return;
                    }
                }

                var elapsedWindow = DateTimeOffset.UtcNow - windowStart;
                var wait = TimeSpan.FromSeconds(1) - elapsedWindow;
                if (wait > TimeSpan.Zero)
                {
                    await Task.Delay(wait, stoppingToken);
                }
            }
        }
        finally
        {
            if (rejectedWriter is not null)
            {
                await rejectedWriter.DisposeAsync();
            }
        }
    }

    private async Task RunReplayInputFileAsync(CancellationToken stoppingToken)
    {
        if (!File.Exists(_producerSettings.TemplateFilePath))
        {
            throw new FileNotFoundException($"Replay input file not found: {_producerSettings.TemplateFilePath}");
        }

        _logger.LogInformation("ReplayInputFile active. Streaming input file: {Path}", _producerSettings.TemplateFilePath);

        var sentTotal = 0L;
        var rejectedTotal = 0L;
        var parseErrorTotal = 0L;
        var processedTotal = 0L;
        var startedAt = DateTimeOffset.UtcNow;
        var lastLoggedAt = DateTimeOffset.MinValue;
        var buffers = new Dictionary<string, List<GeneratedEvent>>(StringComparer.Ordinal);
        StreamWriter? rejectedWriter = null;

        try
        {
            if (!string.IsNullOrWhiteSpace(_producerSettings.RejectedEventsDumpFilePath))
            {
                var dumpDirectory = Path.GetDirectoryName(_producerSettings.RejectedEventsDumpFilePath);
                if (!string.IsNullOrWhiteSpace(dumpDirectory))
                {
                    Directory.CreateDirectory(dumpDirectory);
                }

                rejectedWriter = new StreamWriter(_producerSettings.RejectedEventsDumpFilePath, append: true);
            }

            await foreach (var line in File.ReadLinesAsync(_producerSettings.TemplateFilePath, cancellationToken: stoppingToken))
            {
                var now = DateTimeOffset.UtcNow;
                if (!_elasticDumpEventParser.TryParseLine(line, now, out var generatedEvent, out var parseError))
                {
                    parseErrorTotal++;
                    if (parseErrorTotal <= 10 || parseErrorTotal % 1000 == 0)
                    {
                        _logger.LogWarning("Failed to parse replay input line. ParseErrorTotal={ParseErrorTotal}, Error={Error}", parseErrorTotal, parseError);
                    }

                    continue;
                }

                processedTotal++;
                if (_producerSettings.DropEventsOutsideHotWindow &&
                    !_hotWindowFilter.IsWithinHotWindow(generatedEvent.EventTimestamp, now, _producerSettings.HotWindowDays))
                {
                    rejectedTotal++;
                    if (rejectedWriter is not null)
                    {
                        await rejectedWriter.WriteLineAsync(generatedEvent.Json);
                    }
                }
                else
                {
                    var indexName = _indexResolver.Resolve(_openSearchSettings.IndexPrefix, generatedEvent.EventTimestamp);
                    if (!buffers.TryGetValue(indexName, out var buffer))
                    {
                        buffer = new List<GeneratedEvent>(_openSearchSettings.BulkChunkSize);
                        buffers[indexName] = buffer;
                    }

                    buffer.Add(generatedEvent);
                    if (buffer.Count >= _openSearchSettings.BulkChunkSize)
                    {
                        sentTotal += await PublishReplayBufferAsync(indexName, buffer, stoppingToken);
                        await ThrottleReplayAsync(sentTotal, startedAt, stoppingToken);
                    }
                }

                if (_producerSettings.StopAfterEvents.HasValue &&
                    processedTotal >= _producerSettings.StopAfterEvents.Value)
                {
                    _logger.LogInformation("Replay StopAfterEvents reached. ProcessedTotal={ProcessedTotal}, SentTotal={SentTotal}, RejectedTotal={RejectedTotal}, ParseErrorTotal={ParseErrorTotal}",
                        processedTotal,
                        sentTotal,
                        rejectedTotal,
                        parseErrorTotal);
                    break;
                }

                if ((now - lastLoggedAt) >= TimeSpan.FromSeconds(10))
                {
                    var elapsed = DateTimeOffset.UtcNow - startedAt;
                    var avgRate = processedTotal / Math.Max(1, elapsed.TotalSeconds);
                    _logger.LogInformation("Replay progress. ProcessedTotal={ProcessedTotal}, SentTotal={SentTotal}, RejectedTotal={RejectedTotal}, ParseErrorTotal={ParseErrorTotal}, AvgRate={AvgRate:F2} ev/s",
                        processedTotal,
                        sentTotal,
                        rejectedTotal,
                        parseErrorTotal,
                        avgRate);
                    lastLoggedAt = now;
                }
            }

            foreach (var (indexName, buffer) in buffers)
            {
                sentTotal += await PublishReplayBufferAsync(indexName, buffer, stoppingToken);
                await ThrottleReplayAsync(sentTotal, startedAt, stoppingToken);
            }

            if (rejectedWriter is not null)
            {
                await rejectedWriter.FlushAsync(stoppingToken);
            }

            _logger.LogInformation("Replay completed. ProcessedTotal={ProcessedTotal}, SentTotal={SentTotal}, RejectedTotal={RejectedTotal}, ParseErrorTotal={ParseErrorTotal}",
                processedTotal,
                sentTotal,
                rejectedTotal,
                parseErrorTotal);
            _hostApplicationLifetime.StopApplication();
        }
        finally
        {
            if (rejectedWriter is not null)
            {
                await rejectedWriter.DisposeAsync();
            }
        }
    }

    private async Task<long> PublishReplayBufferAsync(
        string indexName,
        List<GeneratedEvent> buffer,
        CancellationToken stoppingToken)
    {
        if (buffer.Count == 0)
        {
            return 0;
        }

        var count = buffer.Count;
        await _publisher.PublishBulkAsync(indexName, buffer, stoppingToken);
        buffer.Clear();
        return count;
    }

    private async Task ThrottleReplayAsync(long sentTotal, DateTimeOffset startedAt, CancellationToken stoppingToken)
    {
        if (_producerSettings.EventsPerSecond <= 0)
        {
            return;
        }

        var expectedElapsed = TimeSpan.FromSeconds(sentTotal / (double)_producerSettings.EventsPerSecond);
        var actualElapsed = DateTimeOffset.UtcNow - startedAt;
        var delay = expectedElapsed - actualElapsed;
        if (delay > TimeSpan.Zero)
        {
            await Task.Delay(delay, stoppingToken);
        }
    }

    private async Task WaitForOpenSearchAsync(CancellationToken stoppingToken)
    {
        const int maxAttempts = 30;
        var delay = TimeSpan.FromSeconds(2);

        for (var attempt = 1; attempt <= maxAttempts; attempt++)
        {
            try
            {
                var isConnected = await _publisher.CanConnectAsync(stoppingToken);
                if (isConnected)
                {
                    _logger.LogInformation("OpenSearch connectivity check: True (attempt {Attempt})", attempt);
                    return;
                }
            }
            catch (Exception ex) when (!stoppingToken.IsCancellationRequested)
            {
                _logger.LogWarning(ex, "OpenSearch not ready yet (attempt {Attempt}/{MaxAttempts}).", attempt, maxAttempts);
            }

            await Task.Delay(delay, stoppingToken);
        }

        throw new TimeoutException("OpenSearch was not reachable within startup retry window.");
    }

    private async Task PublishChunkAsync(
        string indexName,
        IReadOnlyList<GeneratedEvent> chunk,
        SemaphoreSlim concurrency,
        CancellationToken stoppingToken)
    {
        try
        {
            await _publisher.PublishBulkAsync(indexName, chunk, stoppingToken);
        }
        finally
        {
            concurrency.Release();
        }
    }

    private static IEnumerable<IReadOnlyList<GeneratedEvent>> Chunk(List<GeneratedEvent> source, int chunkSize)
    {
        for (var i = 0; i < source.Count; i += chunkSize)
        {
            yield return source.GetRange(i, Math.Min(chunkSize, source.Count - i));
        }
    }
}
