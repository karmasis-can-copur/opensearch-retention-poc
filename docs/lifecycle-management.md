# Lifecycle Management

Bu PoC'de Elasticsearch ILM karsiligi OpenSearch `Index State Management (ISM)` olarak kullanilir. Hedef sade kalmaktir: writer sadece dogru gunluk indexe yazar, lifecycle kararini OpenSearch policy ve bootstrap/reconcile katmani yonetir.

## Hedef Akis

```text
elasticdump file -> writer/replay -> events_yyyy_MM_dd
events_yyyy_MM_dd -> ISM hot -> cold -> snapshot_ready
snapshot_ready -> MinIO/S3 snapshot -> remote_events_yyyy_MM_dd searchable snapshot
```

Aktif retention modeli:

- Hot: yazilabilir, local full copy, aktif search.
- Cold: read-only, force-merged, local full copy, daha dusuk oncelikli search.
- Searchable snapshot: MinIO/S3 repository uzerinden `remote_snapshot`, search node local cache/metadata tutar.

## Index Tarihi

Gunluk index adi `events_yyyy_MM_dd` formatindadir. Backfill ve gercek dump testlerinde index create edilirken `index.creation_date` index adindaki gunun UTC midnight epoch degeri olarak set edilir. Boylece ISM `min_index_age` native olarak calisir; event tarihine gore ayrica promote eden eski scriptlere ihtiyac yoktur.

Writer ISM policy bilmez. Writer sorumlulugu:

- `_source.TimeCreated` alanindan gunu bulmak.
- `events_yyyy_MM_dd` indexine yazmak.
- Index yoksa `index.creation_date` ile olusturmak.
- Hot window disindaki prod eventleri OpenSearch'e yazmamak, ama DLQ/dump dosyasina kaybetmeden append etmek.

## Aktif Dosyalar

- `docker-compose.yml`: OpenSearch hot/cold/search node'lari, MinIO, dashboard.
- `docker-compose.server.yml`: `.36` test sunucusu icin volume/path ayarlari.
- `opensearch/lifecycle/dataskope-index-template.json`: default Dataskope template.
- `opensearch/lifecycle/dataskope-index-template.loadtest.json`: yuk testi template'i.
- `opensearch/lifecycle/dataskope-index-template.window-1shard.json`: kucuk karsilastirma pencereleri icin 1-shard template.
- Real Sysmon dump verisi icin template'lerde `index.mapping.total_fields.limit=5000` bulunur. Varsayilan `1000` limit Dec08 dump'inda valid eventleri reject etti.
- `opensearch/lifecycle/dataskope-ism-policy.hot-cold-snapshot-10-10.poc.json`: asil 10 hot + 10 cold + snapshot policy.
- `opensearch/lifecycle/dataskope-ism-policy.hot-cold-snapshot-1d.poc.json`: hizli PoC policy.
- `opensearch/lifecycle/snapshot-repository.s3-minio.json`: MinIO/S3 snapshot repository.
- `scripts/poc-up.sh`: cluster'i baslatir.
- `scripts/bootstrap-lifecycle.sh`: repository, ISM policy ve index template uygular.
- `scripts/poc-status.sh`: cluster, node, index/stage durumunu basit gosterir.
- `scripts/preflight-real-dump.sh`: dump dosyasi ve storage on kontrolu.
- `scripts/make-window-policy.py`: tarih penceresi icin native `min_index_age` threshold policy uretir.
- `scripts/run-real-retention-managed-ingest.sh`: gun gun ingest eder, beklenen stage'e kadar bekler, CSV metrik yazar.
- `scripts/summarize-retention-metrics.sh`: CSV'den sade ozet cikarir.

## Basit Calistirma

```bash
cp .env.example .env
./scripts/poc-up.sh
./scripts/bootstrap-lifecycle.sh
./scripts/poc-status.sh
```

Gercek dump icin:

```bash
./scripts/preflight-real-dump.sh 2025-12-01 2025-12-09
python3 scripts/make-window-policy.py --from-date 2025-12-01 --to-date 2025-12-09 --hot-days 3 --cold-days 3 --out opensearch/lifecycle/dataskope-ism-policy.window.poc.json
ISM_POLICY_ID=events-window-3-3-3 ISM_POLICY_FILE=opensearch/lifecycle/dataskope-ism-policy.window.poc.json INDEX_TEMPLATE_FILE=opensearch/lifecycle/dataskope-index-template.window-1shard.json ./scripts/bootstrap-lifecycle.sh
ISM_POLICY_ID=events-window-3-3-3 INGEST_MODE=bulk BULK_WORKERS=6 BULK_BATCH_DOCS=5000 HOT_AFTER_DAYS=<printed> SNAPSHOT_AFTER_DAYS=<printed> ./scripts/run-real-retention-managed-ingest.sh 2025-12-01 2025-12-09 5000
./scripts/summarize-retention-metrics.sh artifacts/resource-metrics/<metrics-file>.csv
```

`HOT_AFTER_DAYS` ve `SNAPSHOT_AFTER_DAYS` degerlerini `make-window-policy.py` komutu yazdirir. `ISM_POLICY_ID` managed ingest'e de verilmelidir; script bu degerle source indexe policy attach eder ve reconciler container'ini ayni policy ile recreate eder. Bu degerler bugunun tarihine gore hesaplanir.

## ISM Action Sirasi

Policy sade native akisi kullanir:

```text
hot -> cold:
  read_only
  force_merge max_num_segments=1
  allocation require temp=cold
  index_priority 50

cold/hot -> snapshot_ready:
  read_only
  force_merge max_num_segments=1
  allocation require temp=frozen
  snapshot to dataskope_lifecycle_repo
  convert_index_to_remote as remote_$1
  delete source index
```

Adim sureleri metrik dosyasinda ve logda izlenir:

- `read_only`: genelde saniyeler.
- `force_merge`: ana maliyet; veri ve segment sayisina gore dakika/saat olabilir.
- `allocation`: shard boyutu, network ve disk throughput'a bagli.
- `snapshot`: MinIO/S3 repository throughput'a bagli.
- `convert_index_to_remote`: genelde hizli; ilk sorgular cache doldurabilir.

## 300K EPS Notu

Bu repo 300K EPS'i mevcut VM'de test etmeye calismaz. Ama her raporda su sorulara cevap aranir:

- Hot ingest node'lari lifecycle isi yuzunden boguluyor mu?
- Force-merge ve snapshot ne kadar suruyor?
- Force-merge sirasinda gecici disk piki final shard boyutundan ne kadar yuksek?
- Data transferi hot node uzerinden mi, cold/search node uzerinden mi agirlikli gidiyor?
- Searchable snapshot local cache gercekten hot diskini azaltiyor mu?
- MinIO/S3 repository diske tasindiginda local cluster disk kazanci ne kadar?

Gercek kazanc codec optimizasyonundan degil, hot local disk kopyasini azaltmaktan ve eski veriyi restore beklemeden aranabilir tutmaktan gelir.

## Backup Ayrimi

Searchable snapshot arama amacli arsiv ihtiyacini azaltabilir. DR backup yerine gecmez. MinIO/S3 repository ayri SLA ile korunmali, snapshot restore proseduru ayrica dogrulanmalidir.
