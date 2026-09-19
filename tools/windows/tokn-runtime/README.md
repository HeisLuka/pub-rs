# TOKN-RUNTIME-01

Воспроизводимый native Microsoft Publisher oracle для проверки Quill TOKN/Type12 через контролируемые поля и гиперссылки.

Связанный issue: #17.

## Зачем это нужно

Статическая часть reverse engineering уже показывает, что Type12/TOKN — общий token/field carrier, а не только структура гиперссылок. Этот harness проверяет причинную связь:

```text
semantic operation в Publisher Object Model
→ pre-save COM snapshot
→ SaveAs конкретного writer family
→ сохранённый .pub
→ reopen snapshot
→ последующий raw Quill/TOKN diff
```

Harness намеренно не пытается сам назвать on-disk поля. Его задача — создать чистый корпус, где известна точная semantic mutation.

## Требования

- Windows.
- Установленный desktop Microsoft Publisher с доступным COM ProgID `Publisher.Application`.
- Windows PowerShell 5.1 или PowerShell 7, если COM automation Publisher работает в используемой конфигурации.
- Возможность сохранять Publisher 98/2000 через установленную версию Publisher.

Linux CI этот опыт не запускает: без native Publisher такой job был бы ложным oracle.

## Запуск

Из корня репозитория:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\windows\tokn-runtime\Invoke-ToknRuntime01.ps1
```

Другой каталог результатов:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\windows\tokn-runtime\Invoke-ToknRuntime01.ps1 `
  -OutputRoot C:\pub-lab\tokn-runtime-01
```

Только PageNumber-тройка:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\windows\tokn-runtime\Invoke-ToknRuntime01.ps1 `
  -Cases page-number-field,page-number-literal,page-number-unlinked
```

Только current writer:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\windows\tokn-runtime\Invoke-ToknRuntime01.ps1 `
  -SaveFormats current
```

## Controlled cases

### PageNumber

- `page-number-field` — `TextRange.InsertPageNumber`.
- `page-number-literal` — обычный текст, равный текущему `Page.PageNumber`.
- `page-number-unlinked` — тот же field после `Field.Unlink`.

Это главный discriminator для уже наблюдаемого wire kind `-5`.

### DateTime

- `date-field` — `InsertDateTime(pbDateLong, true)`.
- `date-literal` — тот же Publisher API с `InsertAsField=false`.
- `date-unlinked` — DateTime field после `Field.Unlink`.

Здесь literal и field создаются одним API и одним форматтером Publisher, поэтому локализация даты не подменяется нашей строковой логикой.

### Hyperlink

Во всех случаях display text одинаков: `PUB-TOKN-LINK`.

- `hyperlink-plain` — обычный текст.
- `hyperlink-url` — внешний URL.
- `hyperlink-email` — email/mailto.
- `hyperlink-file` — file-path address через URL target API.
- `hyperlink-pageid` — внутренний target по `Page.PageID`.

Это позволяет проверять wire kinds external/email/internal без confounder от различного visible text.

## SaveAs matrix

Каждый semantic case создаётся заново для каждого writer family; один и тот же document не перегоняется последовательно через три формата.

Используются документированные `PbFileFormat`:

- `current = pbFilePublication = 1`;
- `publisher98 = pbFilePublisher98 = 2`;
- `publisher2000 = pbFilePublisher2000 = 3`.

Это важно: иначе предыдущий SaveAs мог бы сам изменить in-memory state перед следующим форматом.

## Результаты

Для каждого `case × writer` создаётся каталог:

```text
out/
  page-number-field--current/
    page-number-field--current.pub
    pre-save.json
    reopen.json
  ...
  manifest.json
```

`manifest.json` содержит:

- Publisher Version/Build;
- ОС и PowerShell;
- exact case/save format;
- SHA-256 и размер каждого PUB;
- пути к semantic snapshots;
- ошибки COM/SaveAs, если конкретный вариант не поддержан.

## Что сравнивать дальше

После native прогона сначала сравнить:

1. `field` ↔ `literal`;
2. `field` ↔ `unlinked`;
3. `literal` ↔ `unlinked`;
4. URL ↔ email ↔ file ↔ PageID при одинаковом display text;
5. один semantic case между current/2000/98.

Raw-анализ должен быть grammar-aware: Quill descriptor relocation, CFB packing и writer normalization не являются semantic delta сами по себе.

## Guardrails

- Публичные `PbFieldType`, `PbHlinkTargetType` и `PbFileFormat` не считаются on-disk wire enums.
- Значение third DWORD optional TOKN target-section header пока остаётся OPEN.
- Совпадающий visible text не означает одинаковую raw TOKN state.
- Reopen snapshot показывает то, что текущий Publisher прочитал из сохранённого файла; это не замена raw binary decoder.
- Результат конкретного Publisher build нельзя автоматически повышать до универсального правила всех writer generations.

## Microsoft Object Model, использованный harness

Harness опирается на документированные Publisher API:

- `Documents.Add`;
- `Pages.Add`;
- `Shapes.AddTextbox`;
- `Tags.Add`;
- `TextRange.InsertPageNumber`;
- `TextRange.InsertDateTime`;
- `Field.Unlink`;
- `Hyperlinks.Add`;
- `Document.SaveAs`;
- `Application.Open`;
- `Application.Quit`.

Числовые COM enum constants в скрипте оставлены рядом с явным комментарием, что это API namespace, а не форматный namespace.
