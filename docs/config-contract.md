# Config Sozlesmesi

## OpenSearchSettings

- `MaxConflictRetryCount` (int)
- `NumberOfReplicas` (int)
- `NumberOfShards` (int)
- `Url` (string)
- `Username` (string)
- `Password` (string)
- `ScrollThresholdLimit` (int)
- `RequestTimeoutSeconds` (int)
- `MaxRetryTimeoutSeconds` (int)
- `ConnectionLimit` (int)
- `ConnectionLifetimeMinutes` (int)
- `BulkChunkSize` (int)
- `BulkMaxBytes` (int)
- `BulkMaxConcurrency` (int)
- `IndexPrefix` (string, varsayilan `events`)

Gunluk index adi runtime'da uretilir:

- `<IndexPrefix>_yyyy_MM_dd`

## Producer

- `Enabled` (bool)
- `EventsPerSecond` (int)
- `BatchSize` (int)
- `TemplateFilePath` (string)
- `RandomSeed` (int?, opsiyonel)
- `DryRun` (bool)
- `PreserveDateFields` (bool, varsayilan true; `TimeCreated` gibi tarih alanlarini sample degerinde tutar)
- `ReplayInputFile` (bool; true ise elasticdump NDJSON satirlari stream edilerek `_source` bozulmadan yazilir)
- `DropEventsOutsideHotWindow` (bool)
- `HotWindowDays` (int)
- `RejectedEventsDumpFilePath` (string?, hot pencere disi eventlerin kayipsiz dump dosyasi)
- `DuplicateGuardWindowSize` (int)
- `StopAfterEvents` (long?, opsiyonel; PoC'de producer'i kontrollu durdurmak icin)

Index tarihi event payload icindeki `TimeCreated`, `@timestamp`, `EventTime`, `Timestamp`, `TimeInserted` sirasi ile cozulur. Hicbiri parse edilemezse producer runtime zamani kullanilir.

## Environment Variable Ornekleri

- `OpenSearchSettings__Url`
- `OpenSearchSettings__Username`
- `OpenSearchSettings__Password`
- `OpenSearchSettings__IndexPrefix`
- `Producer__EventsPerSecond`
- `Producer__TemplateFilePath`
- `Producer__ReplayInputFile`
- `Producer__PreserveDateFields`
- `Producer__DropEventsOutsideHotWindow`
- `Producer__RejectedEventsDumpFilePath`
- `Producer__DryRun`
- `Producer__StopAfterEvents`
