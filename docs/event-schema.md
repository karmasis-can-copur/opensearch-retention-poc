# Event Şeması (Kaynak: events_2026_04_23.json)

Kaynak dosya NDJSON formatında ve her satır bağımsız JSON dokümanı.

Kayıt yapısı:
- `_index` (string)
- `_type` (string)
- `_id` (string)
- `_score` (number)
- `_source` (object) -> OpenSearch'e gönderilecek ana payload

`_source` içinde tespit edilen temel alanlar (örnek):
- `EventID` (number)
- `Name` (string)
- `MachineName` (string)
- `UserName` (string)
- `Severity` (number)
- `TimeCreated` (ISO datetime string)
- `TimeInserted` (ISO datetime string)
- `EventSource` (string)
- `Level` (number)
- `DataLabel` (number)
- `Channel` (string)
- `Category` (string)
- `Keywords` (string)
- `Hash` (string)
- `subjectusersid` (string)
- `subjectusername` (string)
- `subjectdomainname` (string)
- `subjectlogonid` (string)
- `targetusersid` (string)
- `targetusername` (string)
- `targetdomainname` (string)
- `status` (string)
- `failurereason` (string)
- `substatus` (string)
- `logontype` (string)
- `logonprocessname` (string)
- `authenticationpackagename` (string)
- `workstationname` (string)
- `transmittedservices` (string)
- `lmpackagename` (string)
- `keylength` (string)
- `processid` (string)
- `processname` (string)
- `ipaddress` (string)
- `ipport` (string)
- `_hash_alg` (string)
- `_hash_ver` (string/number varyantı olabilir)

Notlar:
- Üretici `_source` alanını template olarak alır.
- Şema korunur, değerler tip uyumlu olacak şekilde randomize edilir.
