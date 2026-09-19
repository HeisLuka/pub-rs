# VAL-AUTH-01 adapter

Adapter для controlled validation matrix Parker CR-VAL fixtures.

Связанный issue: #28.

## Почему отдельный worker

Malformed PUB может остановить COM-вызов на модальном bad-file dialog. Поэтому `Documents/Open` не выполняется внутри общего batch process.

Схема:

```text
Invoke-PubRuntimeCase
        ↓
Invoke-ValAuth01Adapter
        ↓
child PowerShell process
        ↓
Publisher.Application.Open
```

Parent adapter ограничивает worker timeout. Если worker не завершился, фиксируется `open.state=timeout`, затем завершаются только новые `MSPUB.EXE`, которых не было до arm.

Timeout — наблюдение. Он не означает автоматически «validator reject» и не локализует owner.

## Case ID

Case ID обязан заканчиваться на один из suffix:

- `--default` — `PromptForBadFiles` удаляется на время run;
- `--prompt` — `PromptForBadFiles = DWORD 1`.

Примеры:

```text
VAL-CRVAL02-TERMINAL-CR-TO-R--default
VAL-CRVAL02-TERMINAL-CR-TO-R--prompt
VAL-CRVAL05-COHERENT-BOUNDARY-PLUS1--default
VAL-CRVAL05-COHERENT-BOUNDARY-PLUS1--prompt
```

Registry major version берётся из уже сохранённого `environment.json`, а не из case name.

Для Publisher 2007 это должно привести к:

```text
HKCU\Software\Microsoft\Office\12.0\Publisher
PromptForBadFiles
```

Исходное наличие key/value, значение и RegistryValueKind сохраняются и восстанавливаются в `finally`.

## Запуск одного arm

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\windows\pub-runtime\Invoke-PubRuntimeCase.ps1 `
  -ExperimentId VAL-AUTH-01 `
  -CaseId VAL-CRVAL02-TERMINAL-CR-TO-R--default `
  -SourcePub C:\pub-lab\batch-01\VAL-CRVAL02-TERMINAL-CR-TO-R.pub `
  -AdapterScript .\tools\windows\pub-runtime\adapters\Invoke-ValAuth01Adapter.ps1 `
  -SnapshotId P2007-RTM `
  -Operation "Открыть exact CRVAL02 при default PromptForBadFiles policy" `
  -RequirePublisher
```

Для второго arm меняются только `CaseId`, `Operation` и policy suffix. Input PUB остаётся тем же exact SHA-256.

## Timeout

По умолчанию worker получает 45 секунд.

Для лабораторной настройки:

```powershell
$env:PUB_VAL_TIMEOUT_SECONDS = "90"
```

Допустимый диапазон: 5–600 секунд.

Не менять timeout между двумя policy arms одного fixture без явной фиксации этого различия.

## Автоматический capture

`oracle/validation-open.json` содержит:

- policy mode и registry provenance;
- Publisher process snapshot до run;
- process/window snapshot в момент timeout;
- Open state: returned / exception / timeout;
- HRESULT/message, если есть;
- Publisher Version/Build/Path;
- Pages.Count;
- Stories.Count;
- story 1 и story 3 text/readability;
- current SaveAs attempt после успешного Open;
- SHA-256 и size нормализованного output.

## Что пока остаётся UI-assisted

Definition of Done также требует:

- точный visible dialog text;
- скрытый `Ctrl+Shift+I` code.

Adapter намеренно не выводит эти значения из HRESULT. В результате стоят:

```json
{
  "ui_capture": {
    "state": "not_automated",
    "dialog_text": null,
    "hidden_ctrl_shift_i_code": null
  }
}
```

Позже можно добавить отдельный UI-capture слой, не меняя raw COM outcome.

## Первый порядок запуска

После pin exact bytes:

1. baseline default/prompt;
2. CRVAL02 default/prompt;
3. CRVAL04 default/prompt;
4. CRVAL05 default/prompt;
5. CRVAL01 default/prompt;
6. CRVAL03 default/prompt.

Это следует текущему VAL-AUTH-01 gate: сначала terminal TEXT mismatch, metadata-only mismatch и coherent known-mirror relocation.

## Guardrails

- Adapter не изменяет PUB bytes.
- `PromptForBadFiles=1` — policy bifurcation, не semantic proof.
- Успешный Open ещё не доказывает, что все истории/структуры восстановлены корректно.
- SaveAs output после Open — normalization evidence конкретного Publisher build.
- Timeout не приравнивается к crash/reject без дополнительного UI/runtime evidence.
- Dialog text и hidden code не фабрикуются из COM exception.
