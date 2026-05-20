using OpenSearchRetentionDashboard.Capacity;
using OpenSearchRetentionDashboard.OpenSearch;
using OpenSearchRetentionDashboard.Retention;
using OpenSearchRetentionDashboard.Search;

var builder = WebApplication.CreateBuilder(args);

builder.Configuration.AddEnvironmentVariables();
builder.Services.Configure<OpenSearchOptions>(builder.Configuration.GetSection("OpenSearch"));
builder.Services.AddSingleton<RetentionIndexClassifier>();
builder.Services.AddSingleton<CapacityCalculator>();
builder.Services.AddSingleton<SafeSearchCatalog>();
builder.Services.AddHttpClient<OpenSearchClient>();

var app = builder.Build();

app.MapGet("/health", () => Results.Ok(new { status = "ok", service = "OpenSearchRetentionDashboard", utc = DateTimeOffset.UtcNow }));

app.MapGet("/", () => Results.Content(DashboardHtml.Content, "text/html"));

app.MapGet("/api/cluster/summary", async (OpenSearchClient client, CancellationToken cancellationToken) =>
{
    return Results.Ok(await client.GetClusterSummaryAsync(cancellationToken));
});

app.MapGet("/api/retention/indices", async (OpenSearchClient client, CancellationToken cancellationToken) =>
{
    var indices = await client.GetRetentionIndicesAsync(cancellationToken);
    var stages = indices
        .GroupBy(index => index.Stage)
        .Select(group => new
        {
            stage = group.Key,
            indexes = group.Count(),
            docs = group.Sum(item => item.Docs),
            storeBytes = group.Sum(item => item.StoreBytes)
        })
        .OrderBy(item => item.stage);

    return Results.Ok(new { indices, stages });
});

app.MapGet("/api/search/templates", (SafeSearchCatalog catalog) => Results.Ok(catalog.Templates));

app.MapPost("/api/search/run", async (SafeSearchRequest request, OpenSearchClient client, SafeSearchCatalog catalog, CancellationToken cancellationToken) =>
{
    var indices = await client.GetRetentionIndicesAsync(cancellationToken);
    var selectedIndexes = catalog.ResolveIndexes(request, indices);
    if (selectedIndexes.Length == 0)
    {
        return Results.BadRequest(new { error = "No index matched the selected stage." });
    }

    var query = catalog.BuildQuery(request);
    var response = await client.PostJsonAsync($"{string.Join(',', selectedIndexes)}/_search", query, cancellationToken);
    return Results.Ok(new { indexes = selectedIndexes, query, response });
});

app.MapPost("/api/calculator", (CapacityInput input, CapacityCalculator calculator) =>
{
    return Results.Ok(calculator.Calculate(input));
});

app.Run();

internal static class DashboardHtml
{
    public const string Content = """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Dataskope OpenSearch Retention</title>
  <style>
    :root { color-scheme: light; --bg:#f6f7f9; --panel:#ffffff; --text:#17202a; --muted:#637083; --line:#d9dee7; --hot:#bc3b2a; --cold:#1f6f8b; --snap:#5b6f2a; }
    * { box-sizing: border-box; }
    body { margin:0; font-family: Arial, sans-serif; background:var(--bg); color:var(--text); }
    header { padding:18px 24px; border-bottom:1px solid var(--line); background:#fff; display:flex; justify-content:space-between; gap:16px; align-items:center; }
    h1 { margin:0; font-size:20px; }
    main { padding:20px 24px 40px; display:grid; gap:16px; }
    section { background:var(--panel); border:1px solid var(--line); border-radius:8px; padding:16px; }
    h2 { margin:0 0 12px; font-size:16px; }
    .grid { display:grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap:12px; }
    .metric { border:1px solid var(--line); border-radius:6px; padding:12px; min-height:82px; }
    .metric span { display:block; color:var(--muted); font-size:12px; }
    .metric strong { display:block; margin-top:8px; font-size:22px; }
    table { width:100%; border-collapse:collapse; font-size:13px; }
    th, td { border-bottom:1px solid var(--line); padding:8px; text-align:left; white-space:nowrap; }
    th { color:var(--muted); font-weight:600; }
    label { display:block; font-size:12px; color:var(--muted); margin-bottom:4px; }
    input, select, button { width:100%; padding:9px 10px; border:1px solid var(--line); border-radius:6px; background:#fff; color:var(--text); }
    button { cursor:pointer; background:#223044; color:#fff; border-color:#223044; }
    .form-grid { display:grid; grid-template-columns: repeat(6, minmax(0, 1fr)); gap:10px; align-items:end; }
    pre { margin:0; overflow:auto; max-height:360px; background:#10151f; color:#dce7f5; padding:12px; border-radius:6px; font-size:12px; }
    .pill { display:inline-block; padding:2px 8px; border-radius:999px; color:#fff; font-size:12px; }
    .hot { background:var(--hot); } .cold { background:var(--cold); } .searchable_snapshot { background:var(--snap); }
    @media (max-width: 1100px) { .grid, .form-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
    @media (max-width: 640px) { header { display:block; } main { padding:12px; } .grid, .form-grid { grid-template-columns: 1fr; } }
  </style>
</head>
<body>
  <header>
    <h1>Dataskope OpenSearch Retention PoC</h1>
    <button style="max-width:140px" onclick="refreshAll()">Refresh</button>
  </header>
  <main>
    <section>
      <h2>Cluster</h2>
      <div class="grid" id="clusterMetrics"></div>
    </section>
    <section>
      <h2>Retention Layout</h2>
      <div class="grid" id="stageMetrics"></div>
      <div style="overflow:auto;margin-top:12px"><table id="indexTable"></table></div>
    </section>
    <section>
      <h2>Safe Search</h2>
      <div class="form-grid">
        <div><label>Template</label><select id="searchTemplate"></select></div>
        <div><label>Stage</label><select id="searchStage"><option>all</option><option>hot</option><option>cold</option><option>searchable_snapshot</option></select></div>
        <div><label>From</label><input id="searchFrom" placeholder="2025-12-01T00:00:00Z"></div>
        <div><label>To</label><input id="searchTo" placeholder="2026-01-30T23:59:59Z"></div>
        <div><button onclick="runSearch()">Run safe search</button></div>
      </div>
      <p style="color:var(--muted);font-size:13px">Avoid leading-wildcard text searches, deep pagination, broad high-cardinality aggregations, and unrestricted full-source exports on cold/searchable snapshot data.</p>
      <pre id="searchResult">No search yet.</pre>
    </section>
    <section>
      <h2>Cluster Calculator</h2>
      <div class="form-grid">
        <div><label>EPS</label><input id="eps" type="number" value="5000"></div>
        <div><label>Hot days</label><input id="hotDays" type="number" value="10"></div>
        <div><label>Cold days</label><input id="coldDays" type="number" value="10"></div>
        <div><label>Snapshot days</label><input id="snapshotDays" type="number" value="41"></div>
        <div><label>Headroom</label><input id="headroom" type="number" step="0.1" value="1.3"></div>
        <div><button onclick="calculate()">Calculate</button></div>
      </div>
      <pre id="calcResult">No calculation yet.</pre>
    </section>
  </main>
  <script>
    const fmtBytes = n => {
      if (!n) return '0 B';
      const units = ['B','KiB','MiB','GiB','TiB'];
      let v = Number(n), i = 0;
      while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
      return `${v.toFixed(i ? 2 : 0)} ${units[i]}`;
    };
    const cell = (label, value) => `<div class="metric"><span>${label}</span><strong>${value}</strong></div>`;
    async function getJson(url) { const r = await fetch(url); return await r.json(); }
    async function postJson(url, body) { const r = await fetch(url, { method:'POST', headers:{'content-type':'application/json'}, body:JSON.stringify(body) }); return await r.json(); }
    async function loadCluster() {
      const data = await getJson('/api/cluster/summary');
      const health = data.health || {};
      const nodes = data.nodes || [];
      document.getElementById('clusterMetrics').innerHTML =
        cell('Health', health.status || 'unknown') +
        cell('Nodes', health.number_of_nodes ?? nodes.length ?? 0) +
        cell('Data nodes', health.number_of_data_nodes ?? '-') +
        cell('Snapshots', Array.isArray(data.snapshots) ? data.snapshots.length : 0);
    }
    async function loadRetention() {
      const data = await getJson('/api/retention/indices');
      document.getElementById('stageMetrics').innerHTML = (data.stages || []).map(s => cell(`${s.stage} (${s.indexes})`, `${s.docs.toLocaleString()} docs / ${fmtBytes(s.storeBytes)}`)).join('');
      document.getElementById('indexTable').innerHTML = '<tr><th>Index</th><th>Stage</th><th>Docs</th><th>Store</th><th>Health</th><th>Alloc</th><th>Store type</th></tr>' +
        (data.indices || []).map(i => `<tr><td>${i.name}</td><td><span class="pill ${i.stage}">${i.stage}</span></td><td>${i.docs.toLocaleString()}</td><td>${fmtBytes(i.storeBytes)}</td><td>${i.health}</td><td>${i.allocationTemp || '-'}</td><td>${i.storeType || '-'}</td></tr>`).join('');
    }
    async function loadTemplates() {
      const templates = await getJson('/api/search/templates');
      document.getElementById('searchTemplate').innerHTML = templates.map(t => `<option value="${t.id}">${t.name}</option>`).join('');
    }
    async function runSearch() {
      const body = { templateId: searchTemplate.value, stage: searchStage.value, from: searchFrom.value || null, to: searchTo.value || null };
      document.getElementById('searchResult').textContent = JSON.stringify(await postJson('/api/search/run', body), null, 2);
    }
    async function calculate() {
      const body = {
        eventsPerSecond: Number(eps.value),
        hotDays: Number(hotDays.value),
        coldDays: Number(coldDays.value),
        searchableSnapshotDays: Number(snapshotDays.value),
        diskHeadroomFactor: Number(headroom.value)
      };
      document.getElementById('calcResult').textContent = JSON.stringify(await postJson('/api/calculator', body), null, 2);
    }
    async function refreshAll() { await Promise.all([loadCluster(), loadRetention(), loadTemplates()]); }
    refreshAll().then(calculate);
  </script>
</body>
</html>
""";
}
