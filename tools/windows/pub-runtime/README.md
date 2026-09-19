# PUB Runtime Envelope

Общий Windows run envelope для controlled Microsoft Publisher experiments.

Связанный issue: #22. Ветка построена поверх PR #18, потому что новый слой должен переиспользовать уже существующий Publisher COM harness, а не создавать параллельный semantic oracle.

## Что делает слой

`Invoke-PubRuntimeCase.ps1` отвечает только за provenance и layout запуска:

1. привязывает exact input PUB по SHA-256;
2. копирует и хэширует optional external assets;
3. сохраняет `EnvironmentManifest`;
4. сохраняет `fixture-manifest.json` и `operation.json`;
5. запускает один experiment-specific adapter;
6. сохраняет structured adapter result;
7. строит `hashes.sha256` для run artifacts;
8. сохраняет финальный `run-manifest.json`.

Он намеренно не интерпретирует Contents/Quill/Escher и не повышает никаких claims о формате.

## Каталог run

```text
out/<experiment>/<case>/<run-id>/
  environment.json
  fixture-manifest.json
  operation.json
  run-manifest.json
  hashes.sha256
  input/
    source.pub
    external-assets/
  oracle/
  output/
  inspect/
  logs/
  meta/
    run-context.json
    structural-manifest.*
    lab-environment/
      comparison.json
      environment-01.json
      environment-02.json
```

`run-id` содержит UTC timestamp и первые 12 hex символов SHA-256 bound input PUB.

Существующий run directory никогда не перезаписывается.

## No-op проверка

No-op adapter позволяет проверить envelope без установленного Publisher и без ложного native claim.

Пример:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\windows\pub-runtime\Invoke-PubRuntimeCase.ps1 ^
  -ExperimentId BATCH-HARNESS-01 ^
  -CaseId envelope-noop ^
  -SourcePub C:\pub-lab\fixtures\sample.pub ^
  -AdapterScript .\tools\windows\pub-runtime\adapters\Invoke-NoopAdapter.ps1 ^
  -Operation "Без semantic mutation"
```

В PowerShell multiline удобнее писать с backtick, а в `cmd.exe` — с `^`. Однострочный вызов работает одинаково предсказуемо.

## Native preflight

`SnapshotId` — только операторская метка. Для любого запуска с `-RequirePublisher` теперь обязателен exact stable `LAB-ENV-01 comparison.json`; одной строки `MODERN-2019-12527` недостаточно.

Перед native run:

1. на clean snapshot запустить `Get-PubLabEnvironment.ps1`;
2. убедиться, что его `comparison.json` имеет `stable=true`;
3. передать этот exact файл через `-LabEnvironmentComparison` или переменную `PUB_LAB_ENV_COMPARISON`;
4. envelope проверит schema, snapshot ID, единственный stable fingerprint, минимум два capture, bind'ит comparison + capture JSON в `meta/lab-environment/` и сверит текущий runtime projection с одним из bound captures.

Пример:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\windows\pub-runtime\Invoke-PubRuntimeCase.ps1 ^
  -ExperimentId MORPH-FLAGS-01 ^
  -CaseId move-only ^
  -SourcePub C:\pub-lab\fixtures\morph\baseline.pub ^
  -AdapterScript C:\pub-lab\adapters\Invoke-MorphMove.ps1 ^
  -SnapshotId MODERN-2019-12527 ^
  -LabEnvironmentComparison C:\pub-lab\environment\MODERN\<run-id>\comparison.json ^
  -Operation "Сдвинуть только tagged object по X" ^
  -RequirePublisher
```

Если LAB-ENV binding отсутствует, нестабилен, относится к другому snapshot label или текущий runtime projection отличается от preflight capture, native run прекращается до adapter. Если COM недоступен, действует тот же fail-closed путь.

Для stacked wrappers, которые пока не имеют отдельного параметра, можно задать:

```powershell
$env:PUB_LAB_ENV_COMPARISON = "C:\pub-lab\environment\MODERN\<run-id>\comparison.json"
```

Это временный совместимый bridge; canonical single-case launcher должен передавать comparison path явно после integration review.

## Adapter contract

Adapter — обычный PowerShell script с единственным обязательным параметром:

```powershell
param(
    [Parameter(Mandatory = $true)]
    [string]$RunContextPath
)
```

`run-context.json` содержит:

- `experiment_id`;
- `case_id`;
- `run_id`;
- exact bound `source_pub`;
- каталоги `oracle`, `output`, `inspect`, `logs`, `meta`;
- `snapshot_id`;
- признаки `publisher_required` и `visible`.

Adapter отвечает только за experiment-specific действие. Общие SHA-256/manifest/lifecycle функции не надо копировать в каждый experiment.

## Structural manifest

Параметр `-StructuralManifest` принимает уже созданный offline manifest инспектора и копирует его в `meta/` с собственным SHA-256 binding.

Это сделано намеренно: текущий `pub inspect --json` пока не объявлен canonical stream-hash API. Batch harness не должен скрытно менять Rust-модель CFB только ради удобства лаборатории.

## External assets

Для PACK/linked-picture experiments:

```powershell
-ExternalAssets C:\pub-lab\assets\sentinel.png,C:\pub-lab\assets\control.wmf
```

Каждый asset копируется в immutable input area и сверяется по SHA-256 после копирования.

Два assets с одинаковым basename в одном run запрещены, чтобы provenance не зависел от порядка аргументов.

## Evidence guardrails

- `status=ok` означает только успешное выполнение adapter внутри envelope.
- Успешный run не доказывает read/write/semantic contract.
- COM snapshot — semantic oracle, а не описание raw bytes.
- SaveAs 2000/98 из нового Publisher — conversion writer arm, а не native runtime Publisher 2000/98.
- Fixture с тем же именем, но другим SHA-256 считается другим input.
- `SnapshotId` сам по себе ничего не доказывает: native run требует bound stable LAB-ENV comparison и совпадение runtime projection.
- Structural/stream manifest — derived offline artifact; source PUB остаётся первичным bound object.
- Claims меняются только после experiment-specific raw analysis и reconciliation.

## Что дальше

Поверх этого слоя добавляются узкие adapters для Batch 01:

- `VAL-AUTH-01`: open policy / PromptForBadFiles;
- `MORPH-FLAGS-01`: format/move/resize/rotation/scenario arms;
- paragraph alignment: explicit-property и style-topology families;
- `PACK-EXT-01`: Graphics Manager / Pack & Go;
- `COM-ORACLE-03`: linked story topology.

Их нельзя объединять в один adapter с несколькими semantic mutations.
