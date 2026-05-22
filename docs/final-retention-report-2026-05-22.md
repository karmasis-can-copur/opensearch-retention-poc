# Dataskope OpenSearch Retention PoC Final Report

## Executive Summary

Bu PoC, Elasticsearch 7.16 tarafindaki hot + archive/snapshot-restore yaklasiminin OpenSearch 3.6 uzerinde ISM ile nasil karsilanabilecegini gosterdi.

Basarilan ana hedefler:

- Dataskope event semasi korunarak gercek elasticdump verisi OpenSearch'e yazildi.
- Gunluk index modeli `events_yyyy_MM_dd` olarak kuruldu.
- Backfill/historical indexlerde `index.creation_date` index adindaki gune set edilerek native ISM `min_index_age` dogru calistirildi.
- Hot, cold ve searchable snapshot katmanlari ayni cluster icinde dogrulandi.
- MinIO/S3 snapshot repository ile `convert_index_to_remote` native ISM akisi calistirildi.
- Curator'in archive/search-restore rolunun ISM + searchable snapshot ile urunlesebilir sekilde azaltilabilecegi gosterildi.
- Dashboard, safe-search, lifecycle status ve capacity calculator icin basit demo yuzeyi olusturuldu.

Ana sonuc:

```text
OpenSearch ISM, arama amacli archive/restore isini Curator'dan devralabilir.
Searchable snapshot DR backup yerine gecmez; snapshot repository yine korunmalidir.
Force-merge disk kazanimi icin zorunlu gorunmuyor ve urun icinden optional olmalidir.
```

## Tested Architecture

```text
writer / replay
  -> daily hot index: events_yyyy_MM_dd
  -> ISM hot
  -> optional cold
  -> MinIO/S3 snapshot
  -> remote_events_yyyy_MM_dd searchable snapshot
```

Node rolleri:

```text
opensearch-hot     cluster_manager,data,ingest
opensearch-cold    data
opensearch-search  warm / searchable snapshot cache
minio              S3-compatible snapshot repository
```

Urun sorumluluk ayrimi:

- Writer index adini ve `index.creation_date` degerini belirler.
- Writer ISM policy bilmez.
- Lifecycle katmani policy attach/reconcile yapar.
- Hot disina dusen veri OpenSearch'e zorla yazilmaz; kayipsiz sekilde DLQ/dump tarafina ayrilir.

## Real Data Result

Test araligi:

```text
2025-12-01 .. 2025-12-09
3 searchable snapshot + 3 cold + 3 hot
1 primary shard, 0 replica
```

Ozet:

```text
days=9
docs=99,862,203
raw=180.50 GiB
all_hot_logical_store=46.76 GiB
final_local_logical_store=40.51 GiB
snapshot_repository_size=12.64 GiB
```

Stage dagilimi:

```text
stage                    days            docs      logical_store
searchable_snapshot         3      32,249,263          12.64 GiB
cold                        3      47,109,218          18.25 GiB
hot                         3      20,503,722           9.62 GiB
```

Search dogrulamasi:

```text
hot count                  0.006s
cold count                 0.007s
searchable snapshot count  0.111s
mixed stage count          0.010s
```

## Force-Merge Finding

Bu PoC'de force-merge'in disk kazanci bekledigimiz kadar anlamli cikmadi.

Elastic 7.16 hot index boyutlari ile OpenSearch force-merged/cold boyutlari cok yakin:

```text
date          Elastic hot     OpenSearch cold / force-merged
2025-12-04    6.8gb           6.7gb
2025-12-05    7.1gb           6.9gb
2025-12-06    4.6gb           4.5gb
```

Force-merge yapilmayan OpenSearch hot indexler de Elastic hot indexlerle ayni bandda:

```text
date          Elastic hot     OpenSearch hot / no force-merge
2025-12-08    4.1gb           4.1gb
2025-12-09    3.9gb           3.8gb
```

Yorum:

- Disk kazanci varsa bile bu veri setinde kucuk.
- Hot indexler background Lucene merge sonrasinda zaten iyi sikisiyor.
- Force-merge'in esas kazanci disk degil; segment sayisini azaltmak, bazi query ve snapshot metadata overhead'lerini azaltmak olabilir.
- Buna karsilik CPU, IO, sure ve gecici disk maliyeti yuksek.

## Measured Retention Durations With Force-Merge

ISM history uzerinden olculen retention sureleri:

```text
searchable snapshot:
2025-12-01 total 19m03s  force_merge 11m02s  snapshot 3m02s
2025-12-02 total 18m04s  force_merge 10m02s  snapshot 3m01s
2025-12-03 total 14m03s  force_merge  7m02s  snapshot 2m02s

cold:
2025-12-04 total 17m02s  force_merge 14m02s
2025-12-05 total 17m01s  force_merge 14m01s
2025-12-06 total 16m01s  force_merge 13m02s
```

Gozlem:

- Sureyi belirleyen ana kalem force-merge.
- `read_only`, allocation setting, priority, delete gibi action'lar saniyelik.
- Shard relocation ISM history'de net action suresi olarak tutulmuyor; 4.5-6.9GB shard transferleri gozlemde birkac dakika bandinda tamamlandi.

## Estimated Durations Without Force-Merge

Asagidaki sureler yeni bir A/B run degildir; mevcut ISM history'den force-merge adimlari cikarilarak ve relocation gozlemi eklenerek hesaplanan tahmindir.

```text
hot -> cold, force_merge=false
expected: 2-5 dakika / index
dominant cost: ISM job tick + shard relocation

hot/cold -> searchable snapshot, force_merge=false
expected: 5-8 dakika / index
dominant cost: snapshot repository write + convert_index_to_remote + ISM ticks
```

Mevcut olcumle karsilastirma:

```text
cold with force_merge:                 16-17 dakika
cold without force_merge estimate:      2-5 dakika

searchable snapshot with force_merge:  14-19 dakika
searchable snapshot without estimate:   5-8 dakika
```

Bu nedenle force-merge kapatildiginda retention gecis maliyetinin ciddi dusmesini bekliyoruz.

## Risks When Force-Merge Is Disabled

Force-merge kapatmanin riskleri:

- Segment sayisi daha yuksek kalabilir.
- Search latency bazi sorgu tiplerinde artabilir.
- Searchable snapshot ilk sorgu/cache-warm davranisi daha dalgali olabilir.
- Snapshot repository daha fazla segment/file metadata tutabilir.
- Restore veya remote snapshot acilisinda daha fazla dosya/metadata okunabilir.
- Uzun sure cok segmentli index tutulursa heap/file-handle/segment metadata baskisi artabilir.

Bu risklerin bu PoC'deki agirligi dusuk gorunuyor, cunku:

- Hot indexler force-merge olmadan Elastic 7.16 boyutlariyla ayni bandda.
- Count/query smoke testleri hot, cold ve searchable snapshot icin basarili.
- Disk kazanci neredeyse yokken force-merge maliyeti yuksek.

## Risks When Force-Merge Is Enabled

Force-merge acik kalirsa riskler:

- Retention gecisi dakika/saat seviyesine uzayabilir.
- Hot node CPU/IO baskisi artar.
- Merge sirasinda gecici disk piki final shard boyutundan cok yuksek olabilir.
- 2025-12-04 orneginde final `6.7gb`, merge sirasinda yaklasik `14.1gb` goruldu.
- Buyuk sistemde ayni anda cok index force-merge olursa hot ingest etkilenebilir.
- 300K EPS olceginde lifecycle concurrency mutlaka sinirlanmalidir.

## Product Configuration Recommendation

OpenSearch ISM policy JSON statiktir; action seviyesinde runtime variable yoktur. Bu nedenle urun, policy olustururken veya guncellerken force-merge action'larini policy JSON'a koyup koymamaya karar vermelidir.

Onerilen urun ayarlari:

```text
Retention.ForceMerge.Mode = none | cold | snapshot | both
Retention.ForceMerge.MaxNumSegments = 1
Retention.ForceMerge.OnlyOffPeak = true
Retention.ForceMerge.MinFreeDiskPercent = 30
Retention.ForceMerge.MaxConcurrentIndexes = 1
```

Onerilen default:

```text
Retention.ForceMerge.Mode = none
```

Neden:

- Bu real-data PoC'de disk kazanci anlamli degil.
- Sure ve transient disk maliyeti yuksek.
- Buyuk olcekte availability ve ingest stability diskten daha kritik.

Opsiyonel kullanim:

- Snapshot repository cok fazla dosya/metadata uretirse `snapshot` modunu test et.
- Cold query latency segment sayisi yuzunden kotulesirse `cold` modunu test et.
- Kucuk/orta olcekte off-peak maintenance varsa `both` uygulanabilir.

## Implemented PoC Support

Window policy generator artik force-merge modunu destekler:

```bash
python3 scripts/make-window-policy.py \
  --from-date 2025-12-01 \
  --to-date 2025-12-09 \
  --hot-days 3 \
  --cold-days 3 \
  --force-merge none \
  --out opensearch/lifecycle/dataskope-ism-policy.window.poc.json
```

Desteklenen modlar:

```text
both      cold ve snapshot_ready icinde force_merge tutar
cold      sadece cold icinde force_merge tutar
snapshot  sadece snapshot_ready icinde force_merge tutar
none      force_merge action'larini kaldirir
```

## Final Recommendation

Dataskope icin hedef mimari:

```text
hot writable local index
  -> cold read-only local index, force_merge optional
  -> searchable snapshot, force_merge optional
  -> source delete after remote index is searchable
```

Nihai karar onerisi:

- Curator archive/search-restore akisini OpenSearch ISM + searchable snapshot ile degistir.
- Force-merge'i default kapali getir.
- Force-merge'i urun icinden policy seviyesinde opsiyonel yap.
- 300K EPS hedefinde lifecycle concurrency, disk headroom ve snapshot repository throughput'u ayri guardrail olarak yonet.
- DR backup ihtiyacini searchable snapshot'tan ayri tut.

Bu sekilde asil kazanc, Lucene segmentlerini zorla kucultmekten degil; eski veriyi hot local diskten MinIO/S3 repository'ye tasiyip restore beklemeden aranabilir tutmaktan gelir.
