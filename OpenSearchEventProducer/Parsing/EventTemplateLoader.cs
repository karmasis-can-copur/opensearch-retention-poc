using System.Text.Json;

namespace OpenSearchEventProducer.Parsing;

public sealed class EventTemplateLoader
{
    private readonly JsonSerializerOptions _serializerOptions = new()
    {
        PropertyNameCaseInsensitive = false,
    };

    public IReadOnlyList<JsonElement> LoadTemplates(string path)
    {
        if (!File.Exists(path))
        {
            throw new FileNotFoundException($"Template file not found: {path}");
        }

        var templates = new List<JsonElement>();

        foreach (var line in File.ReadLines(path))
        {
            if (string.IsNullOrWhiteSpace(line))
            {
                continue;
            }

            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;

            if (root.TryGetProperty("_source", out var source))
            {
                templates.Add(source.Clone());
                continue;
            }

            templates.Add(root.Clone());
        }

        if (templates.Count == 0)
        {
            throw new InvalidOperationException($"No templates parsed from path: {path}");
        }

        return templates;
    }
}
