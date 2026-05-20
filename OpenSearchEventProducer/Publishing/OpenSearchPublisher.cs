using System.Net.Http.Headers;
using System.Collections.Concurrent;
using System.Globalization;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Options;
using OpenSearchEventProducer.Configuration;
using OpenSearchEventProducer.Generation;
using OpenSearchEventProducer.Indexing;

namespace OpenSearchEventProducer.Publishing;

public sealed class OpenSearchPublisher
{
    private const int RetryBaseDelayMilliseconds = 200;

    private readonly HttpClient _httpClient;
    private readonly OpenSearchSettings _settings;
    private readonly DailyIndexNameResolver _indexNameResolver;
    private readonly ConcurrentDictionary<string, byte> _ensuredIndexes = [];
    private readonly SemaphoreSlim _ensureIndexLock = new(1, 1);

    public OpenSearchPublisher(
        IHttpClientFactory httpClientFactory,
        IOptions<OpenSearchSettings> settings,
        DailyIndexNameResolver indexNameResolver)
    {
        _settings = settings.Value;
        _indexNameResolver = indexNameResolver;
        _httpClient = httpClientFactory.CreateClient(nameof(OpenSearchPublisher));
        _httpClient.BaseAddress = new Uri(_settings.Url);
        _httpClient.Timeout = TimeSpan.FromSeconds(_settings.RequestTimeoutSeconds);

        var credentials = Convert.ToBase64String(Encoding.UTF8.GetBytes($"{_settings.Username}:{_settings.Password}"));
        _httpClient.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Basic", credentials);
    }

    public async Task PublishBulkAsync(
        string indexName,
        IReadOnlyList<GeneratedEvent> events,
        CancellationToken cancellationToken)
    {
        if (events.Count == 0)
        {
            return;
        }

        await EnsureIndexAsync(indexName, cancellationToken);

        var payload = BuildBulkPayload(indexName, events);
        var attempt = 0;

        while (true)
        {
            attempt++;
            using var requestContent = new StringContent(payload, Encoding.UTF8, "application/x-ndjson");
            using var response = await _httpClient.PostAsync("/_bulk", requestContent, cancellationToken);

            if (response.IsSuccessStatusCode)
            {
                var body = await response.Content.ReadAsStringAsync(cancellationToken);
                if (HasErrors(body))
                {
                    throw new InvalidOperationException("OpenSearch bulk response contains item errors.");
                }

                return;
            }

            if (attempt > _settings.MaxConflictRetryCount)
            {
                var error = await response.Content.ReadAsStringAsync(cancellationToken);
                throw new HttpRequestException($"OpenSearch bulk request failed after retries. Status={(int)response.StatusCode}, Body={error}");
            }

            var delayMs = RetryBaseDelayMilliseconds * (int)Math.Pow(2, attempt - 1);
            await Task.Delay(delayMs, cancellationToken);
        }
    }

    private async Task EnsureIndexAsync(string indexName, CancellationToken cancellationToken)
    {
        if (_ensuredIndexes.ContainsKey(indexName))
        {
            return;
        }

        await _ensureIndexLock.WaitAsync(cancellationToken);
        try
        {
            if (_ensuredIndexes.ContainsKey(indexName))
            {
                return;
            }

            using var createContent = BuildCreateIndexContent(indexName);
            using var createResponse = await _httpClient.PutAsync($"/{indexName}", createContent, cancellationToken);
            if (!createResponse.IsSuccessStatusCode)
            {
                var createError = await createResponse.Content.ReadAsStringAsync(cancellationToken);
                if (!createError.Contains("resource_already_exists_exception", StringComparison.OrdinalIgnoreCase))
                {
                    throw new HttpRequestException($"OpenSearch index ensure failed. Index={indexName}, Status={(int)createResponse.StatusCode}, Body={createError}");
                }
            }

            _ensuredIndexes.TryAdd(indexName, 0);
        }
        finally
        {
            _ensureIndexLock.Release();
        }
    }

    private StringContent? BuildCreateIndexContent(string indexName)
    {
        if (!_indexNameResolver.TryResolveDate(indexName, _settings.IndexPrefix, out var indexDate))
        {
            return null;
        }

        var creationDate = _indexNameResolver.ResolveCreationDateEpochMilliseconds(indexDate);
        var body = JsonSerializer.Serialize(new
        {
            settings = new Dictionary<string, string>
            {
                ["index.creation_date"] = creationDate.ToString(CultureInfo.InvariantCulture)
            }
        });

        return new StringContent(body, Encoding.UTF8, "application/json");
    }

    public async Task<bool> CanConnectAsync(CancellationToken cancellationToken)
    {
        using var response = await _httpClient.GetAsync("/", cancellationToken);
        return response.IsSuccessStatusCode;
    }

    public async Task<long?> GetDocumentCountAsync(string indexName, CancellationToken cancellationToken)
    {
        using var response = await _httpClient.GetAsync($"/{indexName}/_count", cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return null;
        }

        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        using var document = JsonDocument.Parse(body);
        if (!document.RootElement.TryGetProperty("count", out var countElement))
        {
            return null;
        }

        return countElement.GetInt64();
    }

    private static string BuildBulkPayload(string indexName, IReadOnlyList<GeneratedEvent> events)
    {
        var sb = new StringBuilder(events.Count * 256);

        foreach (var item in events)
        {
            sb.Append("{\"index\":{\"_index\":\"");
            sb.Append(indexName);
            sb.Append("\"}}\n");
            sb.Append(item.Json);
            sb.Append('\n');
        }

        return sb.ToString();
    }

    private static bool HasErrors(string body)
    {
        using var document = JsonDocument.Parse(body);
        if (document.RootElement.TryGetProperty("errors", out var errors))
        {
            return errors.ValueKind == JsonValueKind.True;
        }

        return false;
    }
}
