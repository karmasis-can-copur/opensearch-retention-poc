using OpenSearchEventProducer.Parsing;

namespace OpenSearchEventProducer.Tests;

public class EventTemplateLoaderTests
{
    [Fact]
    public void LoadTemplates_ShouldReadNdjsonAndPreferSource()
    {
        var filePath = Path.GetTempFileName();
        File.WriteAllText(filePath, "{\"_source\":{\"a\":1}}\n{\"b\":2}\n");

        var loader = new EventTemplateLoader();
        var templates = loader.LoadTemplates(filePath);

        Assert.Equal(2, templates.Count);
        Assert.Equal(1, templates[0].GetProperty("a").GetInt32());
        Assert.Equal(2, templates[1].GetProperty("b").GetInt32());
    }
}
