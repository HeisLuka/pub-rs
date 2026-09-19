# BATCH-ADAPTERS-01

Experiment-specific adapters для первой Publisher runtime batch.

Связанный issue: #43. Общий provenance/run layout находится в #23.

## VAL-AUTH-01

`Invoke-ValAuth01.ps1` работает с exact bound source PUB и поддерживает два policy arm по суффиксу `case_id`:

- `<fixture>--default`;
- `<fixture>--prompt`.

Для `--prompt` выставляется:

```text
HKCU\Software\Microsoft\Office\<Application.Version>\Publisher
PromptForBadFiles = DWORD 1
```

Для `--default` временный user override удаляется. Исходное registry state всегда сохраняется и восстанавливается в `finally`.

Open-error сохраняется в `oracle/val-auth-open.json` как экспериментальный результат и не считается infrastructure failure.

Adapter не пытается автоматически интерпретировать hidden Publisher error code: если он снимается UI/debugger-инструментом, его надо положить отдельным raw artifact в `logs/`.

## Paragraph alignment

`Invoke-ParagraphAlignment.ps1` требует ровно один shape:

```text
PUB_ORACLE_ID = ALIGN_TARGET
```

Поддерживаемые current-only cases:

- `align-left`;
- `align-center`;
- `align-right`;
- `align-interword`;
- `align-distribute`.

Числа 0..4 являются значениями Publisher Object Model для этого adapter и **не объявляются wire values FDPP**.

Сохраняются:

- `oracle/before.json`;
- `oracle/after.json`;
- `output/current.pub`;
- `oracle/reopen.json`.

Legacy SaveAs 2000/98 намеренно не включён: это отдельный conversion arm после current-path reconciliation.

## Linked stories

`Invoke-StoryTopology.ps1` требует ровно два tagged shapes:

```text
PUB_ORACLE_ID = STORY_A
PUB_ORACLE_ID = STORY_B
```

Cases:

- `story-unlinked`;
- `story-linked`;
- `story-link-broken`.

Используется документированный Publisher Object Model:

- `TextFrame.NextLinkedTextFrame` — read/write link;
- `TextFrame.BreakForwardLink()` — разрыв forward link;
- `Document.Stories` и `TextFrame.Story` — semantic oracle topology.

Перед Save adapter отдельно проверяет, что mutation не изменила text и геометрию A/B. Если изменила — run прекращается как не single-variable.

Microsoft reference:

- https://learn.microsoft.com/en-us/office/vba/api/publisher.textframe.nextlinkedtextframe
- https://learn.microsoft.com/en-us/office/vba/api/publisher.textframe.breakforwardlink
- https://learn.microsoft.com/en-us/office/vba/api/publisher.textframe

## Что adapters не доказывают

COM state — semantic oracle. Он не доказывает, что конкретный raw field является authoritative carrier.

После native run обязательна цепочка:

```text
bound fixture
→ semantic before
→ одна mutation
→ semantic after
→ saved PUB
→ reopen
→ offline CFB/Contents/Quill/Escher diff
→ OBS/evidence
→ claim reconciliation
```

Только после этого меняется Format Coverage Matrix.
