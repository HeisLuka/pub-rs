# Fixtures Batch 01

Этот каталог фиксирует identity/provenance для первой experimental batch Microsoft Publisher.

Связанный issue: #24.

## Статусы availability

- `pinned` — exact bytes доступны в рабочем fixture bundle и SHA-256 подтверждён.
- `bytes_pending` — SHA-256 и mutation contract уже доказаны, но bytes ещё не перенесены в репозиторий/локальный lab bundle.
- `design_only` — fixture определён экспериментальным контрактом, но exact bytes и SHA-256 ещё не созданы.

Нельзя переводить `design_only` в `pinned` только потому, что файл с похожим именем уже существует.

## Parker CR-VAL

Для baseline и CRVAL01–05 manifest содержит уже зафиксированные SHA-256. В исследовательской базе CRVAL variants хранятся как base64 text attachments. До декодирования и повторной SHA-256 проверки они остаются `bytes_pending`.

Важно: `expected_result` намеренно равен `null`. Fixture manifest не должен заранее записывать, откроет ли Publisher файл и какой validator/parser сработает.

## Остальные families

MORPH, alignment, PACK и STORY пока представлены только стабильными fixture IDs и mutation contracts. Их bytes должны быть созданы controlled harness'ом, после чего в manifest добавляются:

- размер;
- SHA-256;
- точный producer Publisher Version/Build;
- source/creation provenance;
- для CFB — отдельный structural/stream manifest, если он уже снят offline inspector'ом.

## Проверка локального bundle

`Verify-Batch01Fixtures.ps1` проверяет только entries, для которых в manifest уже указан SHA-256 и передан соответствующий локальный файл.

Пример:

```powershell
powershell -ExecutionPolicy Bypass -File .\fixtures\batch-01\Verify-Batch01Fixtures.ps1 `
  -FixtureRoot C:\pub-lab\batch-01
```

Ожидаемое соглашение имён локального bundle:

```text
C:\pub-lab\batch-01\
  VAL-PARKER-BASELINE.pub
  VAL-CRVAL01-INTERNAL-CR-TO-R.pub
  VAL-CRVAL02-TERMINAL-CR-TO-R.pub
  ...
```

Отсутствующий `bytes_pending` файл выводится как `MISSING`, но не превращается в выдуманный hash.

## Guardrail

Этот каталог — provenance layer. Он не является доказательством семантики формата, native acceptance или writer fidelity.
