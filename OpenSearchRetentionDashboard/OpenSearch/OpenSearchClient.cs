using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Extensions.Options;
using OpenSearchRetentionDashboard.Retention;

namespace OpenSearchRetentionDashboard.OpenSearch;

public sealed class OpenSearchClient
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    private readonly HttpClient _httpClient;
    private readonly OpenSearchOptions _options;
    private readonly RetentionIndexClassifier _classifier;

    public OpenSearchClient(HttpClient httpClient, IOptions<OpenSearchOptions> options, RetentionIndexClassifier classifier)
    {
        _httpClient = httpClient;
        _options = options.Value;
        _classifier = classifier;
        _httpClient.BaseAddress = new Uri(_options.Url.TrimEnd('/') + "/");

        if (!string.IsNullOrWhiteSpace(_options.Username) && _options.Password is not null)
        {
            var credentials = Convert.ToBase64String(Encoding.UTF8.GetBytes($"{_options.Username}:{_options.Password}"));
            _httpClient.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Basic", credentials);
        }
    }

    public async Task<JsonNode?> GetJsonAsync(string path, CancellationToken cancellationToken)
    {
        using var response = await _httpClient.GetAsync(path, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return new JsonObject
            {
                ["error"] = $"{(int)response.StatusCode} {response.ReasonPhrase}",
                ["path"] = path
            };
        }

        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        return await JsonNode.ParseAsync(stream, cancellationToken: cancellationToken);
    }

    public async Task<JsonNode?> PostJsonAsync(string path, object body, CancellationToken cancellationToken)
    {
        using var content = new StringContent(JsonSerializer.Serialize(body, JsonOptions), Encoding.UTF8, "application/json");
        using var response = await _httpClient.PostAsync(path, content, cancellationToken);
        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);

        if (!response.IsSuccessStatusCode)
        {
            var errorBody = await JsonNode.ParseAsync(stream, cancellationToken: cancellationToken);
            return new JsonObject
            {
                ["error"] = $"{(int)response.StatusCode} {response.ReasonPhrase}",
                ["path"] = path,
                ["body"] = errorBody
            };
        }

        return await JsonNode.ParseAsync(stream, cancellationToken: cancellationToken);
    }

    public async Task<object> GetClusterSummaryAsync(CancellationToken cancellationToken)
    {
        var health = await GetJsonAsync("_cluster/health", cancellationToken);
        var nodes = await GetJsonAsync("_cat/nodes?format=json&h=name,ip,node.role,heap.percent,ram.percent,cpu,load_1m,disk.used_percent", cancellationToken);
        var allocation = await GetJsonAsync("_cat/allocation?format=json&bytes=b&h=shards,disk.indices,disk.used,disk.avail,disk.total,disk.percent,node", cancellationToken);
        var snapshots = await GetJsonAsync($"_cat/snapshots/{_options.SnapshotRepository}?format=json&s=id", cancellationToken);

        return new
        {
            measuredAtUtc = DateTimeOffset.UtcNow,
            health,
            nodes,
            allocation,
            snapshots
        };
    }

    public async Task<IReadOnlyList<RetentionIndex>> GetRetentionIndicesAsync(CancellationToken cancellationToken)
    {
        var indices = await GetJsonAsync($"_cat/indices/{_options.IndexPattern}?format=json&bytes=b&h=health,status,index,docs.count,store.size,pri.store.size&s=index", cancellationToken);
        if (indices is not JsonArray indexRows || indexRows.Count == 0)
        {
            return [];
        }

        var names = indexRows
            .OfType<JsonObject>()
            .Select(row => GetString(row, "index"))
            .Where(name => !string.IsNullOrWhiteSpace(name))
            .ToArray();

        var settings = await GetJsonAsync($"{string.Join(',', names)}/_settings?flat_settings=true&include_defaults=false", cancellationToken);
        var result = new List<RetentionIndex>(indexRows.Count);

        foreach (var row in indexRows.OfType<JsonObject>())
        {
            var name = GetString(row, "index");
            var allocationTemp = GetSetting(settings, name, "index.routing.allocation.require.temp");
            var storeType = GetSetting(settings, name, "index.store.type");
            var stage = _classifier.Classify(name, allocationTemp, storeType);

            result.Add(new RetentionIndex(
                Name: name,
                Stage: stage,
                Docs: GetLong(row, "docs.count"),
                StoreBytes: GetLong(row, "store.size"),
                PrimaryStoreBytes: GetLong(row, "pri.store.size"),
                Health: GetString(row, "health"),
                Status: GetString(row, "status"),
                AllocationTemp: allocationTemp,
                StoreType: storeType));
        }

        return result;
    }

    private static string GetSetting(JsonNode? settings, string indexName, string settingName)
    {
        return settings?[indexName]?["settings"]?[settingName]?.GetValue<string>() ?? string.Empty;
    }

    private static string GetString(JsonObject row, string name)
    {
        return row[name]?.GetValue<string>() ?? string.Empty;
    }

    private static long GetLong(JsonObject row, string name)
    {
        var text = GetString(row, name);
        return long.TryParse(text, out var value) ? value : 0;
    }
}
