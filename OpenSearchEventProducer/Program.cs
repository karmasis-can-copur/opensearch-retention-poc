using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using OpenSearchEventProducer.Configuration;
using OpenSearchEventProducer.Generation;
using OpenSearchEventProducer.Indexing;
using OpenSearchEventProducer.Parsing;
using OpenSearchEventProducer.Publishing;
using OpenSearchEventProducer.Worker;

var builder = Host.CreateApplicationBuilder(args);

builder.Configuration
    .AddJsonFile("appsettings.json", optional: false, reloadOnChange: true)
    .AddJsonFile($"appsettings.{builder.Environment.EnvironmentName}.json", optional: true, reloadOnChange: true)
    .AddEnvironmentVariables();

builder.Services
    .AddOptions<OpenSearchSettings>()
    .Bind(builder.Configuration.GetSection(OpenSearchSettings.SectionName))
    .ValidateDataAnnotations()
    .ValidateOnStart();

builder.Services
    .AddOptions<ProducerSettings>()
    .Bind(builder.Configuration.GetSection(ProducerSettings.SectionName))
    .ValidateDataAnnotations()
    .ValidateOnStart();

builder.Services.AddHttpClient();
builder.Services.AddSingleton<EventTemplateLoader>();
builder.Services.AddSingleton<ElasticDumpEventParser>();
builder.Services.AddSingleton<DailyIndexNameResolver>();
builder.Services.AddSingleton<HotWindowFilter>();
builder.Services.AddSingleton<RandomEventGenerator>();
builder.Services.AddSingleton<OpenSearchPublisher>();
builder.Services.AddHostedService<ProducerWorker>();

await builder.Build().RunAsync();
