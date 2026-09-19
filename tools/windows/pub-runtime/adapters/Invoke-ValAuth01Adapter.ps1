param(
    [Parameter(Mandatory = $true)]
    [string]$RunContextPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$runtimeRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $runtimeRoot "PubRuntime.psm1") -Force

function Get-PublisherProcessSnapshot {
    $items = @()
    Get-Process -Name MSPUB -ErrorAction SilentlyContinue | ForEach-Object {
        $startedAt = $null
        try {
            $startedAt = $_.StartTime.ToUniversalTime().ToString("o")
        }
        catch {
            $startedAt = $null
        }

        $items += [ordered]@{
            pid = [int]$_.Id
            process_name = [string]$_.ProcessName
            main_window_title = [string]$_.MainWindowTitle
            started_at_utc = $startedAt
        }
    }
    return $items
}

function Get-PowerShellHostPath {
    $windowsPowerShell = Join-Path $PSHOME "powershell.exe"
    if (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf) {
        return $windowsPowerShell
    }

    $pwsh = Join-Path $PSHOME "pwsh.exe"
    if (Test-Path -LiteralPath $pwsh -PathType Leaf) {
        return $pwsh
    }

    throw "Не найден PowerShell executable рядом с PSHOME=$PSHOME"
}

$context = Get-Content -LiteralPath $RunContextPath -Raw | ConvertFrom-Json
$caseId = [string]$context.case_id

$policyMode = $null
if ($caseId.EndsWith("--default", [System.StringComparison]::OrdinalIgnoreCase)) {
    $policyMode = "default"
}
elseif ($caseId.EndsWith("--prompt", [System.StringComparison]::OrdinalIgnoreCase)) {
    $policyMode = "prompt"
}
else {
    throw "VAL-AUTH-01 case_id должен заканчиваться на --default или --prompt: $caseId"
}

$environmentPath = Join-Path ([string]$context.run_dir) "environment.json"
$environment = Get-Content -LiteralPath $environmentPath -Raw | ConvertFrom-Json

if (-not $environment.publisher.available) {
    throw "VAL-AUTH-01 требует Publisher COM, но EnvironmentManifest отмечает publisher.available=false"
}

if ($environment.publisher.version.state -ne "value") {
    throw "Не удалось определить Publisher major version из EnvironmentManifest"
}

$versionText = [string]$environment.publisher.version.value
$major = $versionText.Split('.')[0]
if ([string]::IsNullOrWhiteSpace($major) -or $major -notmatch '^\d+$') {
    throw "Неожиданное значение Publisher Version: $versionText"
}

$registrySubKey = "Software\Microsoft\Office\$major.0\Publisher"
$policyRegistrySubKey = "Software\Policies\Microsoft\Office\$major.0\publisher"
$valueName = "PromptForBadFiles"

$policyRoots = @(
    [ordered]@{
        hive = "HKCU"
        root = [Microsoft.Win32.Registry]::CurrentUser
    },
    [ordered]@{
        hive = "HKLM"
        root = [Microsoft.Win32.Registry]::LocalMachine
    }
)

foreach ($policyRoot in $policyRoots) {
    $policyRegistryKey = $policyRoot.root.OpenSubKey($policyRegistrySubKey, $false)
    if ($null -eq $policyRegistryKey) {
        continue
    }

    try {
        if (@($policyRegistryKey.GetValueNames()) -contains $valueName) {
            $policyValue = $policyRegistryKey.GetValue($valueName)
            throw "Нельзя выполнить controlled PromptForBadFiles A/B: policy path $($policyRoot.hive)\$policyRegistrySubKey уже задаёт $valueName=$policyValue"
        }
    }
    finally {
        $policyRegistryKey.Close()
    }
}
$registryKey = $null
$keyExistedBefore = $false
$valueExistedBefore = $false
$valueBefore = $null
$valueKindBefore = $null

$timeoutSeconds = 45
if ($env:PUB_VAL_TIMEOUT_SECONDS) {
    $parsedTimeout = 0
    if ([int]::TryParse($env:PUB_VAL_TIMEOUT_SECONDS, [ref]$parsedTimeout) -and $parsedTimeout -ge 5 -and $parsedTimeout -le 600) {
        $timeoutSeconds = $parsedTimeout
    }
    else {
        throw "PUB_VAL_TIMEOUT_SECONDS должен быть целым числом от 5 до 600"
    }
}

$workerScript = Join-Path $PSScriptRoot "Invoke-ValAuthOpenWorker.ps1"
$workerResultPath = Join-Path ([string]$context.meta_dir) "val-auth-worker-result.json"
$stdoutPath = Join-Path ([string]$context.logs_dir) "val-auth-worker.stdout.log"
$stderrPath = Join-Path ([string]$context.logs_dir) "val-auth-worker.stderr.log"
$finalResultPath = Join-Path ([string]$context.oracle_dir) "validation-open.json"

$beforeProcesses = @(Get-PublisherProcessSnapshot)
$beforePids = @($beforeProcesses | ForEach-Object { $_.pid })

$workerProcess = $null
$timedOut = $false
$timeoutProcesses = @()
$adapterStarted = [DateTimeOffset]::Now

try {
    $registryKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registrySubKey, $true)
    if ($null -ne $registryKey) {
        $keyExistedBefore = $true
    }
    else {
        $registryKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($registrySubKey)
    }

    $valueNames = @($registryKey.GetValueNames())
    $valueExistedBefore = $valueNames -contains $valueName
    if ($valueExistedBefore) {
        $valueBefore = $registryKey.GetValue($valueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $valueKindBefore = [string]$registryKey.GetValueKind($valueName)
    }

    if ($policyMode -eq "prompt") {
        $registryKey.SetValue($valueName, 1, [Microsoft.Win32.RegistryValueKind]::DWord)
    }
    else {
        if (@($registryKey.GetValueNames()) -contains $valueName) {
            $registryKey.DeleteValue($valueName, $false)
        }
    }

    $registryKey.Close()
    $registryKey = $null

    $hostPath = Get-PowerShellHostPath
    $quotedWorker = '"' + $workerScript + '"'
    $quotedContext = '"' + $RunContextPath + '"'
    $quotedResult = '"' + $workerResultPath + '"'
    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $quotedWorker,
        "-RunContextPath", $quotedContext,
        "-ResultPath", $quotedResult
    )

    $workerProcess = Start-Process -FilePath $hostPath -ArgumentList $arguments -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

    $completed = $workerProcess.WaitForExit($timeoutSeconds * 1000)
    if (-not $completed) {
        $timedOut = $true
        $timeoutProcesses = @(Get-PublisherProcessSnapshot)

        try {
            Stop-Process -Id $workerProcess.Id -Force -ErrorAction SilentlyContinue
        }
        catch {
            # Завершение worker-процесса выполняется по возможности.
        }

        $newPublisherPids = @(
            $timeoutProcesses |
                Where-Object { $beforePids -notcontains $_.pid } |
                ForEach-Object { $_.pid }
        )

        foreach ($publisherPid in $newPublisherPids) {
            try {
                Stop-Process -Id $publisherPid -Force -ErrorAction SilentlyContinue
            }
            catch {
                # В isolated lab это cleanup зависшего run, а не evidence.
            }
        }
    }

    if ($timedOut) {
        $raw = [ordered]@{
            schema = "pub-val-auth-01/open-worker/v1"
            started_at = $adapterStarted.ToString("o")
            finished_at = [DateTimeOffset]::Now.ToString("o")
            worker_pid = if ($null -ne $workerProcess) { [int]$workerProcess.Id } else { $null }
            experiment_id = [string]$context.experiment_id
            case_id = $caseId
            source_pub = [string]$context.source_pub
            publisher = $environment.publisher
            open = [ordered]@{
                state = "timeout"
                timeout_seconds = $timeoutSeconds
                hresult = $null
                message = "Worker не завершил Publisher Open до timeout; возможен модальный UI или зависший parser path."
            }
            document = $null
            save_current = [ordered]@{
                attempted = $false
                state = "not_attempted"
            }
        }
    }
    else {
        if (-not (Test-Path -LiteralPath $workerResultPath -PathType Leaf)) {
            throw "VAL worker завершился без result JSON"
        }

        $raw = Get-Content -LiteralPath $workerResultPath -Raw | ConvertFrom-Json
    }

    $result = [ordered]@{
        schema = "pub-val-auth-01/adapter-result/v1"
        experiment_id = [string]$context.experiment_id
        case_id = $caseId
        policy = [ordered]@{
            mode = $policyMode
            registry_subkey = "HKCU\$registrySubKey"
            policy_registry_subkeys_checked = @(
                "HKCU\$policyRegistrySubKey",
                "HKLM\$policyRegistrySubKey"
            )
            policy_override_present = $false
            value_name = $valueName
            effective_test_value = if ($policyMode -eq "prompt") { 1 } else { $null }
            previous_state = [ordered]@{
                key_existed = $keyExistedBefore
                value_existed = $valueExistedBefore
                value = $valueBefore
                value_kind = $valueKindBefore
            }
        }
        timeout_seconds = $timeoutSeconds
        publisher_processes_before = $beforeProcesses
        publisher_processes_at_timeout = $timeoutProcesses
        observation = $raw
        ui_capture = [ordered]@{
            state = "not_automated"
            dialog_text = $null
            hidden_ctrl_shift_i_code = $null
            note = "Dialog text и Ctrl+Shift+I code должны добавляться как отдельное UI-assisted observation; их нельзя выводить из COM HRESULT."
        }
        interpretation_guardrails = @(
            "timeout является наблюдаемым runtime outcome, но не локализует validator owner.",
            "PromptForBadFiles меняет policy response и сам по себе не доказывает parser semantics.",
            "COM/Open result не заменяет raw Quill/Contents analysis.",
            "SaveAs output после успешного Open является normalization observation только для зафиксированного Publisher build."
        )
    }

    Write-PubJson -Value $result -Path $finalResultPath
}
finally {
    if ($null -ne $registryKey) {
        try {
            $registryKey.Close()
        }
        catch {
            # Best effort перед restore.
        }
    }

    $restoreKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registrySubKey, $true)
    if ($null -eq $restoreKey -and ($keyExistedBefore -or $valueExistedBefore)) {
        $restoreKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($registrySubKey)
    }

    if ($null -ne $restoreKey) {
        try {
            if ($valueExistedBefore) {
                $kind = [Microsoft.Win32.RegistryValueKind]([System.Enum]::Parse([Microsoft.Win32.RegistryValueKind], $valueKindBefore))
                $restoreKey.SetValue($valueName, $valueBefore, $kind)
            }
            else {
                if (@($restoreKey.GetValueNames()) -contains $valueName) {
                    $restoreKey.DeleteValue($valueName, $false)
                }
            }
        }
        finally {
            $restoreKey.Close()
        }
    }

    if (-not $keyExistedBefore) {
        # Не удаляем всё дерево: Publisher мог создать собственные значения во время Open.
        # Удалить созданный нами key можно только если после restore он действительно пуст.
        $cleanupKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registrySubKey, $false)
        if ($null -ne $cleanupKey) {
            try {
                $canDeleteKey = (
                    @($cleanupKey.GetValueNames()).Count -eq 0 -and
                    @($cleanupKey.GetSubKeyNames()).Count -eq 0
                )
            }
            finally {
                $cleanupKey.Close()
            }

            if ($canDeleteKey) {
                try {
                    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($registrySubKey, $false)
                }
                catch {
                    # Cleanup не должен маскировать уже сохранённое evidence.
                }
            }
        }
    }
}
