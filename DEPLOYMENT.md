# OpenSearch Event Producer - Deployment Runbook

Bu runbook Dataskope lifecycle PoC ortamini ayaga kaldirmak ve OpenSearch'e veri yazimini dogrulamak icindir.

## 1. On Kosullar

- Docker Desktop veya Docker Engine + Compose
- .NET 9 SDK, sadece local build/test icin
- En az onerilen kaynak: 4 CPU, 8 GB RAM
- Event dosyasi: varsayilan `./samples/dataskope-events.sample.ndjson`

## 2. Hizli Baslatma

```powershell
.\scripts\start-lifecycle-poc.ps1
```

Bu komut hot/cold/search OpenSearch node'larini, Dashboards'i, snapshot repository'yi, ISM policy'yi ve index template'i hazirlar; sonra bounded event basar.

Adresler:

- OpenSearch: http://localhost:9200
- OpenSearch Dashboards: http://localhost:5601

## 3. Lifecycle Manage Komutlari

Durum:

```powershell
.\scripts\lifecycle-list.ps1
.\scripts\lifecycle-explain.ps1 -ShowPolicy -ValidateAction
```

Gecmis tarihli indexleri calendar date'e gore cold/snapshot state'lerine ilerletmek:

```powershell
.\scripts\promote-events-by-date.ps1 -ColdAfterDays 2 -SnapshotAfterDays 30
```

Cold search dogrulama:

```powershell
.\scripts\test-cold-search.ps1 -IndexName events_2026_04_23
```

Searchable snapshot olusturma ve frozen search dogrulama:

```powershell
.\scripts\make-searchable-snapshot.ps1 -IndexName events_2026_04_23
.\scripts\test-frozen-search.ps1 -FrozenIndexName events_2026_04_23-frozen
```

Policy degisikligi:

```powershell
.\scripts\lifecycle-change-policy.ps1 -IndexPattern "events_*" -PolicyId "events-hot-cold"
```

Failed action retry:

```powershell
.\scripts\lifecycle-retry.ps1
```

Policy kaldirma:

```powershell
.\scripts\lifecycle-remove-policy.ps1
```

## 4. Servis Durumu

```powershell
docker compose ps
```

Beklenen servisler:

- `opensearch-hot`
- `opensearch-cold`
- `opensearch-search`
- `opensearch-dashboards`
- `event-producer` sadece bounded run sirasinda calisir.

## 5. Index ve Count Kontrolu

```powershell
Invoke-WebRequest -Uri "http://localhost:9200/_cat/indices/events_*?v" -UseBasicParsing
```

Count:

```powershell
$index = "events_2026_04_23"
Invoke-RestMethod -Uri "http://localhost:9200/$index/_count"
```

## 6. Temizleme

Containerlari durdur:

```powershell
docker compose down
```

Volume dahil temizle:

```powershell
docker compose down -v --remove-orphans
```

## 7. Dokumanlar

- Lifecycle detaylari: `docs/lifecycle-management.md`
- Config sozlesmesi: `docs/config-contract.md`
- Event semasi: `docs/event-schema.md`

Not: OpenSearch tarafinda lifecycle kabiliyetinin adi ISM'dir. ILM, Elasticsearch adlandirmasidir.
