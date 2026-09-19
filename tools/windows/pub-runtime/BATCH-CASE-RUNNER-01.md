# BATCH-CASE-RUNNER-01

Безопасный мост между machine-readable Batch 01 plan и одним конкретным Windows Publisher run.

Связанный issue: #46.

## Что он принципиально не делает

Runner не выбирает следующий experiment и не запускает весь batch. Live V3 Safe pickup остаётся внешним orchestration gate в Notion.

Перед вызовом оператор/агент уже должен иметь разрешённый конкретный experiment/case.

## Вызов

Пример для обычного adapter case:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\windows\pub-runtime\Invoke-Batch01Case.ps1 `
  -ExperimentId "COM-ORACLE-03" `
  -CaseId "link--current" `
  -SnapshotId MODERN-2019-12527 `
  -FixtureRoot C:\pub-lab\batch-01
```

## Fail-closed gates

До Publisher runtime проверяются:

- exact experiment/case встречается в run-plan ровно один раз;
- logical wave snapshot key разрешается через `snapshots.<key>.required_label`, и именно этот concrete label должен совпасть с `-SnapshotId`;
- `needs_*` / `after_*` state не запускается;
- source fixture существует в canonical manifest;
- availability source — `pinned` или `external_pinned`;
- local filename существует;
- size и SHA-256 exact bytes совпадают;
- asset fixtures проходят те же проверки;
- adapter/entrypoint существует в integration tree.

Для обычного adapter canonical `source_fixture_id` передаётся в общий envelope через `-SourceFixtureId`.

## PACK UI-assisted cases

PACK использует свой entrypoint и те же exact source/sentinel bindings.

Для `baseline` дополнительных operator artifacts нет.

Для `manual-linked` нужны:

- `-OperatorOutputPub`;
- `-OperatorAssetsRoot`;
- `-OperatorManifest`.

Для `pack-commercial` / `pack-computer` дополнительно:

- `-OperatorPackageFile`.

PACK wrapper передаёт canonical `SourceFixtureId` дальше в общий envelope.

## Evidence boundary

Успешный launcher gate означает только то, что выбранный case структурно согласован с plan и exact local bytes.

Он не доказывает:
- что live V3 Notion gate был соблюдён;
- semantic correctness результата;
- raw PUB attribution;
- writer fidelity.

После native run остаётся обязательной цепочка raw/offline diff → OBS/evidence → claim reconciliation.
