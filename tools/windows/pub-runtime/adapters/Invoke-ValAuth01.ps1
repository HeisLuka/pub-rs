param(
    [Parameter(Mandatory = $true)]
    [string]$RunContextPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$runtimeDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $runtimeDir "PubRuntime.psm1") -Force

$context = Get-Content -LiteralPath $RunContextPath -Raw | ConvertFrom-Json
$caseId = [string]$context.case_id
$sourcePub = [string]$context.source_pub
$oracleDir = [string]$context.oracle_dir
$logsDir = [string]$context.logs_dir

if ($caseId -notmatch "(--default|--prompt)$") {
    throw "VAL-AUTH adapter ожидает case_id с суффиксом --default или --prompt: $caseId"
}

$usePrompt = $caseId.EndsWith("--prompt", [System.StringComparison]::OrdinalIgnoreCase)

function Get-RegistryState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return [ordered]@{
            path_exists = $false
            value_exists = $false
            value = $null
        }
    }

    $property = Get-ItemProperty -LiteralPath $Path
    $match = $property.PSObject.Properties[$Name]
    return [ordered]@{
        path_exists = $true
        value_exists = ($null -ne $match)
        value = if ($null -ne $match) { $match.Value } else { $null }
    }
}

function Restore-RegistryState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        $State
    )

    if ($State.value_exists) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
        New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType DWord -Value ([int]$State.value) -Force | Out-Null
    }
    else {
        if (Test-Path -LiteralPath $Path) {
            Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
        }
    }
}

function Get-StorySnapshot {
    param(
        [Parameter(Mandatory = $true)]
        $Document
    )

    $stories = @()
    try {
        $count = [int]$Document.Stories.Count
        for ($i = 1; $i -le $count; $i++) {
            $story = $Document.Stories.Item($i)
            $stories += [ordered]@{
                index = $i
                text = Get-PubSafeValue { [string]$story.TextRange.Text } "Story.TextRange.Text"
                length = Get-PubSafeValue { [int]$story.TextRange.Length } "Story.TextRange.Length"
            }
        }
    }
    catch {
        return [ordered]@{
            state = "error"
            message = $_.Exception.Message
            items = @()
        }
    }

    return [ordered]@{
        state = "value"
        count = $stories.Count
        items = $stories
    }
}

$application = $null
$document = $null
$registryPath = $null
$registryBefore = $null
$result = [ordered]@{
    schema = "pub-runtime/val-auth-01/v1"
    case_id = $caseId
    source_pub = Get-PubFileRecord $sourcePub
    policy = if ($usePrompt) { "prompt_for_bad_files" } else { "default" }
    publisher = $null
    registry = $null
    open = $null
    document = $null
    cleanup = $null
}

try {
    $application = New-PubPublisherApplication -Visible:$([bool]$context.visible)
    $publisherVersion = Get-PubSafeValue { [string]$application.Version } "Application.Version"
    $publisherBuild = Get-PubSafeValue { [string]$application.Build } "Application.Build"

    $result.publisher = [ordered]@{
        version = $publisherVersion
        build = $publisherBuild
    }

    if ($publisherVersion.state -ne "value") {
        throw "Не удалось получить Application.Version; registry path нельзя определить доказательно."
    }

    $registryPath = "HKCU:\Software\Microsoft\Office\$($publisherVersion.value)\Publisher"
    $registryBefore = Get-RegistryState -Path $registryPath -Name "PromptForBadFiles"

    # Policy читается Publisher process; поэтому registry меняется до фактического Open.
    Close-PubPublisherApplication $application
    $application = $null

    if ($usePrompt) {
        New-Item -ItemType Directory -Force -Path $registryPath | Out-Null
        New-ItemProperty -LiteralPath $registryPath -Name "PromptForBadFiles" -PropertyType DWord -Value 1 -Force | Out-Null
    }
    else {
        # default arm не должен наследовать случайно оставшийся override от другого run.
        Remove-ItemProperty -LiteralPath $registryPath -Name "PromptForBadFiles" -ErrorAction SilentlyContinue
    }

    $registryApplied = Get-RegistryState -Path $registryPath -Name "PromptForBadFiles"
    $result.registry = [ordered]@{
        path = $registryPath
        before = $registryBefore
        applied = $registryApplied
    }

    $application = New-PubPublisherApplication -Visible:$([bool]$context.visible)
    $openedAt = [DateTimeOffset]::Now
    try {
        $document = $application.Open($sourcePub, $true, $false)
        $result.open = [ordered]@{
            status = "opened"
            started_at = $openedAt.ToString("o")
            finished_at = [DateTimeOffset]::Now.ToString("o")
            hresult = $null
            message = $null
        }

        $result.document = [ordered]@{
            pages_count = Get-PubSafeValue { [int]$document.Pages.Count } "Document.Pages.Count"
            stories = Get-StorySnapshot $document
            save_format = Get-PubSafeValue { [int]$document.SaveFormat } "Document.SaveFormat"
            full_name = Get-PubSafeValue { [string]$document.FullName } "Document.FullName"
        }
    }
    catch {
        $result.open = [ordered]@{
            status = "error"
            started_at = $openedAt.ToString("o")
            finished_at = [DateTimeOffset]::Now.ToString("o")
            hresult = if ($_.Exception.HResult) { Format-PubHResult ([int]$_.Exception.HResult) } else { $null }
            message = $_.Exception.Message
        }
    }
}
finally {
    if ($null -ne $document) {
        try {
            $document.Close()
        }
        catch {
            # Ошибка Close не должна уничтожать open oracle.
        }
    }

    Close-PubPublisherApplication $application

    if ($null -ne $registryBefore -and $null -ne $registryPath) {
        try {
            Restore-RegistryState -Path $registryPath -Name "PromptForBadFiles" -State $registryBefore
            $result.cleanup = [ordered]@{
                registry_restored = $true
                restored_state = Get-RegistryState -Path $registryPath -Name "PromptForBadFiles"
            }
        }
        catch {
            $result.cleanup = [ordered]@{
                registry_restored = $false
                message = $_.Exception.Message
            }
        }
    }

    Write-PubJson -Value $result -Path (Join-Path $oracleDir "val-auth-open.json")
}

if ($result.open.status -eq "error") {
    # Open rejection/error является данными эксперимента, а не infrastructure failure.
    exit 0
}
