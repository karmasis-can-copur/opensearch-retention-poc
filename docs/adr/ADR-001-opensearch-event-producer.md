# ADR-001: OpenSearch Event Producer Tasarımı

## Durum
Kabul edildi.

## Karar
- Uygulama `.NET 9 Console + Generic Host` ile geliştirilecek.
- Kaynak event dosyası NDJSON olarak satır satır okunacak.
- `_source` alanı template kabul edilip şema korunarak random mutasyon uygulanacak.
- Index adi config'den `IndexPrefix` ile alinacak, event `TimeCreated` tarihine gore gunluk formatta cozulecek: `<prefix>_yyyy_MM_dd`.
- OpenSearch yazımı `_bulk` endpoint'i ile yapılacak.
- Dağıtım için multi-stage Dockerfile ve docker-compose kullanılacak.
- Template dosyası container'a host volume mount ile verilecek.

## Gerekçe
- Generic Host ile config/logging/lifecycle yönetimi sadeleşir.
- NDJSON satır bazlı okuma büyük dosyalarda memory baskısını düşürür.
- Günlük indexleme operasyon ve retention yönetimini kolaylaştırır.
- Bulk indexleme throughput için daha verimlidir.
