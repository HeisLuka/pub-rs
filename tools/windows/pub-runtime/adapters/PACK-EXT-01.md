# PACK-EXT-01 capture

Связанный issue: #37.

Этот слой намеренно разделяет действие Publisher UI и измерение результата. В текущем подтверждённом automation surface нет основания придумывать метод `PackAndGo()`, поэтому Graphics Manager и Pack & Go выполняются реальным UI-путём, а harness отвечает за provenance, hashes и semantic snapshot.

## Fixture contract

Exact baseline PUB должен содержать ровно один tagged picture:

`PUB_ORACLE_ID = PACK_TARGET`

Оригинальный sentinel asset передаётся отдельно через `-SentinelAsset`; общий envelope копирует и хэширует его до capture.

## Arms

- `baseline` — UI mutation отсутствует; снимается состояние exact source PUB.
- `manual-linked` — оператор выполнил Graphics Manager → Save as Linked Picture.
- `pack-commercial` — оператор выполнил commercial Pack & Go и распаковал package без изменения bytes.
- `pack-computer` — optional another-computer control.

Для non-baseline arm обязательны rewritten PUB, каталог emitted assets и operator manifest. Для Pack & Go arm дополнительно обязателен исходный package container.

## Operator manifest

Используется schema `pub-pack-ext-01/operator-action/v1`. Пример лежит рядом: `pack-operator-manifest.example.json`.

Минимально фиксируются `case_id`, время, реальный UI action, известные checkbox/options и paths. Неизвестная опция остаётся `null`; её нельзя восстанавливать по содержимому package задним числом.

Adapter проверяет, что `case_id` manifest совпадает с run case, копирует exact manifest в `meta/` и хэширует его.

## Baseline

Пример:

    powershell -ExecutionPolicy Bypass -File .\tools\windows\pub-runtime\Invoke-PackExt01Capture.ps1 -CaseId baseline -SourcePub C:\pub-lab\pack\baseline.pub -SentinelAsset C:\pub-lab\assets\sentinel.png

## Manual Graphics Manager arm

Сначала в Publisher открыть отдельную копию exact baseline и выполнить только Graphics Manager → Save as Linked Picture. Затем сохранить publication и вызвать capture:

    powershell -ExecutionPolicy Bypass -File .\tools\windows\pub-runtime\Invoke-PackExt01Capture.ps1 -CaseId manual-linked -SourcePub C:\pub-lab\pack\baseline.pub -SentinelAsset C:\pub-lab\assets\sentinel.png -OutputPub C:\pub-lab\manual\manual-linked.pub -EmittedAssetsRoot C:\pub-lab\manual\assets -OperatorManifest C:\pub-lab\manual\operator.json

`SourcePub` остаётся baseline; `OutputPub` — post-action publication. Так provenance хранит обе стороны.

## Commercial Pack & Go

После UI Pack & Go package распаковывается обычным container tooling без повторного открытия/импорта assets. Затем:

    powershell -ExecutionPolicy Bypass -File .\tools\windows\pub-runtime\Invoke-PackExt01Capture.ps1 -CaseId pack-commercial -SourcePub C:\pub-lab\pack\baseline.pub -SentinelAsset C:\pub-lab\assets\sentinel.png -OutputPub C:\pub-lab\pack-out\PublicationPNG.pub -EmittedAssetsRoot C:\pub-lab\pack-out\assets -PackageFile C:\pub-lab\pack-out\package.zip -OperatorManifest C:\pub-lab\pack-out\operator.json

Extension package может быть `.puz`, `.zip` или иной реально полученный container; harness не переименовывает его в semantic format.

## Semantic snapshot

Для `PACK_TARGET` снимаются:

- Shape.ID / Name / Type / PageID;
- geometry;
- PictureFormat.IsLinked;
- PictureFormat.FileName;
- PictureFormat.FileSize;
- PictureFormat.OriginalFileSize;
- PictureFormat.ImageFormat.

Каждое PictureFormat property читается отдельно через safe-value wrapper. COM error/unsupported property остаётся observation.

## Artifacts

- exact baseline PUB;
- original sentinel asset;
- rewritten PUB;
- recursive emitted assets с relative path/size/SHA-256;
- package file, если есть;
- operator manifest;
- source/rewritten semantic snapshots.

Output files копируются в immutable run directory и сверяются по hash после копирования.

## Что этот adapter не решает сам

- остался ли embedded BStore/EscherDelay payload;
- является ли link authoritative;
- Pack & Go destructive или dual-state;
- сделал ли Publisher canonical conversion image bytes;
- соответствует ли Graphics Manager path Pack & Go path.

Эти выводы разрешаются только после offline binary diff и сравнения emitted asset hash с original sentinel.

## Reference COM states

`Shapes.AddPicture(FileName, LinkToFile, SaveWithDocument, ...)` можно использовать в отдельном PICSTATE-01 для controlled embedded/linked reference states. Такие states нельзя называть результатом Graphics Manager или Pack & Go.

## Guardrails

- Никакого фиктивного Pack & Go COM automation.
- Operator action — часть provenance и хранится как exact JSON.
- Unknown checkbox остаётся `null`.
- Emitted asset хэшируется до любого повторного import.
- Package container и rewritten-PUB semantics анализируются раздельно.
