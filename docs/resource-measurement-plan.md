# Resource Measurement and 30k EPS Sizing Plan

Bu dokuman hot/cold/frozen stage'lerinde ayni verinin CPU, RAM, disk ve search davranisini nasil olcecegimizi tarif eder.

## Olcum Prensibi

OpenSearch CPU ve heap/RAM metriklerini index bazinda tam izole vermez. Bu yuzden index maliyetini su sekilde baglariz:

- Index disk: `_cat/indices`, `/<index>/_stats/store`.
- Shard disk ve node yerlesimi: `_cat/shards`.
- Index search/indexing/cache/segment metrikleri: `/<index>/_stats`.
- Segment sayisi ve segment memory: `/<index>/_segments?verbose=true`.
- Node CPU/RAM/disk: `_cat/nodes`, `/_nodes/stats`.
- Local Docker PoC icin container CPU/RAM: `docker stats --no-stream`.

Bu nedenle "index CPU/RAM kullandi" derken aslinda "bu indexin shard'lari su node'larda dururken node CPU/RAM ve index stats su sekilde degisti" demis oluruz.

## Scriptler

Tek stage olcumu:

```powershell
.\scripts\measure-index-stage.ps1 -Stage hot -IndexName events_2026_04_23 -IncludeDocker
.\scripts\measure-index-stage.ps1 -Stage cold -IndexName events_2026_04_23 -IncludeDocker
.\scripts\measure-index-stage.ps1 -Stage frozen -IndexName events_2026_04_23-frozen -IncludeDocker
```

Varsayilan cikti klasoru:

```text
artifacts/resource-metrics/
```

Hot/cold/frozen karsilastirma:

```powershell
.\scripts\compare-stage-resources.ps1 -MetricFiles `
  .\artifacts\resource-metrics\<hot>.json,`
  .\artifacts\resource-metrics\<cold>.json,`
  .\artifacts\resource-metrics\<frozen>.json
```

## Search Seviyesi

`measure-index-stage.ps1` su sorgulari kosar:

- `match_all_size_10`
- `time_range_all`
- `eventid_range`
- `eventsource_text_match`

Her sorgu icin client-side elapsed ms, OpenSearch `took`, hit sayisi, avg/p50/p95/max raporlanir. Frozen/searchable snapshot icin ilk sorgu ve warmed sorgu farki onemlidir; script warmup sayisini `-WarmupRuns` ile kontrol eder.

## Elasticsearch Template Etkisi

Projeye eklenen `elasticsearch-template-for-dataskope.txt` legacy template'i OpenSearch 2.x composable template'e cevrildi ve `opensearch/lifecycle/dataskope-index-template.json` icine tasindi.

Onemli fark:

- Tum string alanlar `text` olarak indexlenir.
- Her string alan icin `raw` keyword subfield olusur.
- `norms=false`.
- `date_detection=false`, `numeric_detection=false`.
- `TimeCreated` ve `TimeInserted` explicit `date`.
- `EventID`, `Level`, `Severity`, `DataLabel` explicit `float`.

Bu mapping, onceki daha optimize `keyword/ip/integer` yaklasimina gore disk ve segment maliyetini artirabilir; ama Dataskope gercek davranisina daha yakindir.

## 30k EPS Kabaca Kapasite

30k event/s:

```text
30,000 * 86,400 = 2,592,000,000 event/day
```

Mevcut sample NDJSON satirlarinin ortalama boyutu yaklasik 1,056 byte. Ham JSON hacmi:

```text
2.592B * 1,056 byte ~= 2.55 TiB/day raw payload
```

OpenSearch index overhead'i mapping, analyzer, doc_values, stored fields, segment merge ve replica ile degisir. Bu template tum stringleri `text + raw keyword` yaptigi icin pratikte ham payload'in ustune ciddi disk carpani beklenir. Ilk buyuk testin amaci bu carpani gercek Dataskope payload'i ile olcmek.

Minimum baslangic tahmini:

- Hot: 1 gun aktif ingest icin en az 6-12 data node arasi denenmeli.
- Hot node disk: node basina NVMe/SSD, toplam hot usable disk en az gunluk index hacmi + merge headroom. Headroom icin en az 1.5x-2x dusun.
- Cold: 1 gun cold icin daha az CPU ama yeterli disk ve relocation bandwidth gerekir.
- Frozen/search: snapshot repository zorunlu; search node local disk cache'i remote data'nin bir fraksiyonu olur. Cache kucuk olursa first-query ve cold-query latency yukselir.
- Cluster manager: dedicated 3 node onerilir; PoC compose'daki tek cluster-manager prod icin yeterli model degildir.

Daha verimli prod modeli:

- Gunluk veri mantigini koru ama tek dev index yerine rollover/parcalama kullan: `events_2026_05_05_000001`, `events_2026_05_05_000002`.
- Hedef primary shard boyutunu performans testiyle sec. Baslangic araligi olarak 30-80 GB primary shard denenebilir.
- Hot ingest ve force-merge'i ayni anda calistirma; force-merge'i warm/cold penceresine al.
- Hot -> cold relocation'i throttle et ve off-peak pencereye koy.
- Frozen icin dedicated `search` node kullan; local cache hit ratio ve first-query latency ayri raporlanmali.

## 1 Gun Hot, 1 Gun Cold, 1 Gun Frozen Testi

Gercekci buyuk test akisi:

1. `events_YYYY_MM_DD` veya parcali gunluk indexlere 24 saat 30k EPS veri bas.
2. Hot stage sonunda resource snapshot al.
3. Index yazimini kapat, read-only/force-merge/allocation ile cold'a gecir.
4. Cold stage tamamlaninca resource snapshot ve search benchmark al.
5. Snapshot al, searchable snapshot olarak restore et.
6. Frozen stage resource snapshot, first-query ve warmed-query benchmark al.
7. Uc JSON'u `compare-stage-resources.ps1` ile raporla.

## Kabul Kriterleri

- Her stage icin docs/store/shard/node/search latency raporu uretilir.
- Cold stage shard'lari cold node'larda baslar ve search sonuc dondurur.
- Frozen stage `index.store.type=remote_snapshot` olur, search node'larda baslar ve search sonuc dondurur.
- Hot/cold/frozen icin disk ve search latency farki raporlanir.
- Node CPU/RAM kullanimi shard placement ile birlikte raporlanir.

## 2026-05-05 Ilk Sunucu Kalibrasyonu

`docker-os-cls` uzerinde 1.02M dokumanlik uc gun verisi ile ilk kalibrasyon tamamlandi. Detay:

- `docs/loadtest-2026-05-05.md`
- `artifacts/resource-metrics/20260505-hot-cold-frozen-comparison.md`

Kaba sonuc:

- Hot stable: 1.02M docs, 1.72 GB logical primary store, 54-61 ms warmed search.
- Hot immediate post-ingest: ayni veri icin 2.16 GB goruldu; bu merge headroom ihtiyacini gosterir.
- Cold: 1.02M docs, 1.52 GB force-merged store, 58-64 ms warmed search.
- Frozen: 1.02M docs, 1.52 GB logical store, search-node volume 299 MB, repo 1.5 GB, 60-63 ms warmed search.

Tek producer container 30k EPS hedefte 11k-11.4k EPS effective throughput verdi. Performans fazina gecmeden once producer paralelligi ve bulk ayarlari tune edilmeli.

30k EPS tam gun lineer projeksiyon bu mapping ile multi-TB gerektiriyor:

- Hot stable 1 gun: yaklasik 4.4 TB primary store.
- Hot immediate/merge-headroom 1 gun: yaklasik 5.5 TB primary store.
- Cold 1 gun: yaklasik 3.9 TB primary store.
- Frozen repo 1 gun: yaklasik 3.8 TB.

Bu nedenle 500 GB test sunucusu full-day retention testi icin degil, lifecycle kaniti, kisa burst ve oran cikarma icin kullanilmali.
