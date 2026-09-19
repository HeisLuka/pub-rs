# OID-WATERMARK-01 — native runtime arm

Этот adapter воспроизводит уже охарактеризованный native arm на exact `example_multipage.pub`.

## Bound fixture

- SHA-256: `cabf449064f9151d279a3d8dbba777a3e18f3a8863ff60f940523ee4cd056a44`
- Publisher evidence scope: Publisher 2019 / 16.0 build 12527.
- Удаляемая страница: collection index 2, PageID `33554728`, ранее сопоставлена raw PAGE296.
- Источник Duplicate: collection index 1, PageID `33554698`.

## Единственная semantic mutation

1. открыть exact fixture;
2. удалить page index 2;
3. `Pages(1).Duplicate("", "ADD_AFTER_DELETE_PAGE")`;
4. сохранить current format;
5. закрыть и открыть output заново.

Adapter сохраняет COM snapshots и output PUB, но **не** интерпретирует raw Contents.

## Предзарегистрированный raw discriminator

Предыдущий native add-after-delete arm на том же fixture дал новой странице:

```text
PAGE330
PageID 33554762
Oid raw = 02 00 00 00 07 00 00 00
Oid = (2, 7)
```

Для `OID-WATERMARK-01` проверяется простая allocator-гипотеза:

```text
до создания новой Page: DwNextUniqueOid = 7
новая Page.Oid.DWORD1 = 7
после сохранения: DwNextUniqueOid = 8
```

До отдельного raw-разбора output PUB этот переход остаётся **предсказанием**, а не результатом.

## Запуск

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\windows\pub-runtime\Invoke-PubRuntimeCase.ps1 `
  -ExperimentId OID-WATERMARK-01 `
  -CaseId example-multipage-delete-duplicate `
  -SourcePub C:\pub-lab\fixtures\example_multipage.pub `
  -AdapterScript .\tools\windows\pub-runtime\adapters\Invoke-OidWatermark01Adapter.ps1 `
  -SnapshotId MODERN-2019-12527 `
  -Operation "Удалить page index 2 и продублировать page 1" `
  -RequirePublisher
```

## Что считать evidence

`status=ok` означает только, что native arm завершился.

Claim о `DwNextUniqueOid` можно менять лишь после raw capture как минимум:

```text
DOCUMENT.field0x23 до/после
новый PAGE seqNum
новый Page.Oid raw8
Oid.DWORD0
Oid.DWORD1
DOCUMENT.field0x02
```

Если получено не `7 -> (2,7) -> 8`, простая allocator-модель должна быть отвергнута или сужена.
