# BATCH-FIXTURE-GEN-01

Controlled generator простых source fixtures первой experimental batch.

Связанный issue: #41.

## Что генерируется

- `ALIGN-EXPLICIT-PARAGRAPH-BASE.pub`;
- `STORY-UNLINKED-BASE.pub`;
- `STORY-LINKED-A-B.pub`;
- `PACK-EMBEDDED-PNG-BASE.pub`;
- `PACK-SENTINEL-PNG.png` — exact bound copy входного sentinel.

## Что намеренно не генерируется

- `ALIGN-STYLE-TOPOLOGY-BASE`: нам нужна независимая реально наблюдаемая style topology, а не искусственно похожий document.
- MORPH wizard/tracked sources: сначала нужен exact wizard/design/tracking contract.
- Parker/CRVAL: эти bytes уже существуют; их надо materialize и hash-verify, а не регенерировать.

## Запуск

    powershell -ExecutionPolicy Bypass -File .\tools\windows\pub-runtime\New-Batch01SimpleFixtures.ps1 -SentinelPng C:\pub-lab\assets\sentinel.png -OutputRoot C:\pub-lab\batch-01

Generator отказывается перезаписывать существующие artifacts.

## Alignment explicit

Создаётся один textbox с `PUB_ORACLE_ID=ALIGN_TARGET`, фиксированным текстом и `ParagraphFormat.Alignment=1`, затем current SaveAs.

После reopen generator требует тот же tag и readback Alignment=1. Это setup известного explicit path, а не новое утверждение о wire mapping.

## Story source states

Сначала создаётся unlinked source:

- `STORY_A` содержит sentinel text;
- `STORY_B` пуст;
- geometry фиксирована;
- links отсутствуют.

После сохранения exact unlinked PUB открывается заново. Единственная derivation mutation:

    STORY_A.TextFrame.NextLinkedTextFrame = STORY_B.TextFrame

Результат сохраняется как `STORY-LINKED-A-B.pub`. Generation manifest записывает SHA-256 parent unlinked fixture. Reopen должен подтвердить forward/previous link.

Это source для будущего `BreakForwardLink` arm.

## PACK embedded source

Microsoft документирует `Shapes.AddPicture(FileName, LinkToFile, SaveWithDocument, ...)`: `LinkToFile=msoFalse` означает embedded picture, а LinkToFile и SaveWithDocument должны иметь противоположные значения.

Generator использует:

- `LinkToFile=msoFalse`;
- `SaveWithDocument=msoTrue`;
- `PUB_ORACLE_ID=PACK_TARGET`;
- exact copied `PACK-SENTINEL-PNG.png`.

После reopen требуется `PictureFormat.IsLinked=false`.

Документация Microsoft: https://learn.microsoft.com/en-us/office/vba/api/publisher.shapes.addpicture

## generation-manifest.json

Содержит:

- Publisher Version/Build;
- exact sentinel source/copy SHA-256;
- SHA-256 и size generated PUB;
- setup/derivation;
- parent SHA для linked story;
- reopen verification notes.

## Pinning rule

Generator output **не** становится canonical fixture автоматически.

После Windows run:

1. проверить EnvironmentManifest;
2. проверить `generation-manifest.json`;
3. прогнать `Verify-Batch01Fixtures.ps1` после внесения SHA/local filename;
4. только затем менять `availability` на `pinned` в canonical fixture manifest.

Нельзя копировать hash в manifest, если generation был выполнен на неизвестном Publisher build или partial run.
