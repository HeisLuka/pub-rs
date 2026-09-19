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


## Oracle tags и story source topology

Для runtime adapters pin'ятся не только bytes, но и locator contract:

- alignment fixtures: `PUB_ORACLE_ID=ALIGN_TARGET`;
- story fixtures: `PUB_ORACLE_ID=STORY_A` и `PUB_ORACLE_ID=STORY_B`.

Story family использует **два** pinned source states:

1. `STORY-UNLINKED-BASE` — source для unlinked control и link mutation;
2. `STORY-LINKED-A-B` — source для break mutation.

`STORY-LINK-BROKEN` — generated output class после одной `BreakForwardLink` mutation, а не третий вручную созданный source. Это уменьшает риск, что независимая ручная сборка добавит лишний binary delta.

## External pinned fixtures

`external_pinned` означает: identity fixture зафиксирована полным SHA-256, размером и immutable upstream commit/path, но bytes не vendored в `pub-rs`.

Сейчас так оформлен `ALIGN-STYLE-TOPOLOGY-BASE`:

- upstream: `aspose-pub/Aspose.PUB-for-.NET`;
- commit: `beee619f9a4b7e2c8908e0fa132f4f4650b08975`;
- path: `Examples/Data/halloween-flyer.pub`;
- Git blob SHA-1: `6610c53ff345d4e11e03b7fffd1cd128b3ae4052`;
- size: `306176`;
- SHA-256: `f079765650af152e1ae1fbfded757f679c588ceea884b77329a240c578884c25`.

Получение в lab:

```powershell
powershell -ExecutionPolicy Bypass -File .\fixtures\batch-01\Get-Batch01ExternalFixtures.ps1 `
  -FixtureRoot C:\pub-lab\batch-01
```

Downloader использует pinned commit URL и до переименования проверяет и размер, и SHA-256. Существующий локальный файл с другим hash является hard error.

### Alignment style locator

Upstream Halloween fixture не модифицируется только ради добавления нашего Tag. Для `style` family runtime adapter разрешает fallback locator только при exact source SHA выше и только если одновременно выполняются:

- Shape.Name = `Text Box 20`;
- text содержит `Children`;
- initial `ParagraphFormat.Alignment = 2`;
- match ровно один.

Это заново проверяет нужный semantic target на exact upstream bytes и не предполагает, что старый `realtest/txt-same-02/control-input.pub` byte-identical upstream-файлу.

Первый style pass теперь содержит только реальные single-mutation transitions:

- 2→1;
- 2→3;
- 2→4.

Прямой 2→2 исключён как no-op. Обратный 1→2 разрешается только после того, как output 2→1 отдельно pin'ится как новый source fixture.
