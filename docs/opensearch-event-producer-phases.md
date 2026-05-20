# OpenSearch Event Producer - Fazlı Uygulama Planı (.NET 9)

## Amaç
Config’e göre saniyede belirli adette event üretip OpenSearch’e gönderen bir `.NET 9 Console` uygulaması geliştirmek. Event içeriği, kaynak dosya `file:///C:/Users/yusuf.uzun/Downloads/Events/events_2026_04_23.json` yapısına göre rastgele ve birbirinden farklılaştırılmış şekilde üretilecek.

## Faz 0 - Analiz ve Sözleşme [x]
- Kaynak JSON dosya şemasını analiz et.
- Zorunlu alanlar, opsiyonel alanlar, tipler ve nested yapıları çıkar.
- Hangi alanların randomize edileceğini alan bazında tanımla (hedef: neredeyse tüm alanlar; şema bozulmadan).
- OpenSearch bağlantı sözleşmesini aşağıdaki `OpenSearchSettings` ile sabitle.

Çıktılar:
- `docs/event-schema.md`
- `docs/config-contract.md`

## Faz 1 - Uygulama İskeleti (.NET 9) [x]
- `.NET 9` Console projesi oluştur.
- Katmanları sade şekilde ayır:
  - `Configuration`
  - `EventTemplateLoader`
  - `RandomEventGenerator`
  - `OpenSearchPublisher`
  - `WorkerLoop`
- `appsettings.json` + environment override desteği ekle.

Çıktılar:
- Çalışan temel proje
- Config’den değer okuyup loglayan başlangıç sürümü

## Faz 2 - Günlük Indexleme Stratejisi [x]
- Index adı config’den gelsin (`IndexPrefix`).
- Gunluk index adi event `TimeCreated` tarihinden uretilecek: `<index-prefix>_yyyy_MM_dd`
- Gün değişiminde otomatik yeni index’e yazım.

Çıktılar:
- `IndexNameResolver` servisi

## Faz 3 - Template Okuma ve Random Veri Üretimi [x]
- JSON dosyasını startup’ta yükle, parse et, bellekte template havuzu oluştur.
- Her gönderimde template havuzundan random event seç.
- Neredeyse tüm alanlar için tip güvenli mutasyon uygula (şemayı bozmadan).
- Aynı event’in birebir tekrarını engellemek için duplicate guard uygula.

Çıktılar:
- `RandomEventGenerator` ve testler

## Faz 4 - OpenSearch Yayınlama [x]
- OpenSearch bulk endpoint entegrasyonu.
- Basic auth + timeout + retry/backoff.
- Hata durumunda exception ve log üretimi.

Çıktılar:
- OpenSearch’e toplu veri akışı

## Faz 5 - Saniyelik Gönderim Döngüsü ve Rate Control [x]
- `EventsPerSecond` değerine göre saniyelik üretim/gönderim.
- Drift azaltmak için pencere bazlı delay.
- Graceful shutdown.

Çıktılar:
- Ortalama hız loglama

## Faz 6 - Dockerfile ve Docker Compose [x]
- Multi-stage `Dockerfile`.
- `docker-compose.yml`.
- Volume mount ile template dosyası besleme.
- Env var override.

Çıktılar:
- `Dockerfile`
- `docker-compose.yml`
- `docker-compose.override.yml`

## Faz 7 - Test, Doğrulama ve Teslim [x]
- Unit testler.
- Build/test doğrulaması.
- Çalıştırma dökümanı.

Çıktılar:
- `OpenSearchEventProducer.Tests`
- `README.md`

## Kabul Kriterleri
- `.NET 9` üzerinde çalışmalı.
- Config değiştirerek hız, index prefix ve OpenSearch bağlantısı değiştirilebilmeli.
- Uygulama event tarihine gore gunluk index adina otomatik yazmali (`<prefix>_yyyy_MM_dd`).
- Üretilen event’ler aynı şemayı korurken içerik olarak yüksek çeşitlilikte olmalı.
- OpenSearch hata durumlarında kontrollü retry yapmalı.
- Docker Compose ile tek komutla ayağa kalkmalı.
