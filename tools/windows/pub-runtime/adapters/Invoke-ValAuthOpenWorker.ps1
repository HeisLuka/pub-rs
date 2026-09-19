param(
    [Parameter(Mandatory = $true)]
    [string]$RunContextPath,

    [Parameter(Mandatory = $true)]
    [string]$ResultPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$runtimeRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $runtimeRoot "PubRuntime.psm1") -Force

function Get-StoryRecord {
    param(
        [Parameter(Mandatory = $true)]
        $Document,
        [Parameter(Mandatory = $true)]
        [int]$Index
    )

    $countState = Get-PubSafeValue { [int]$Document.Stories.Count } "Document.Stories.Count"
    if ($countState.state -ne "value" -or [int]$countState.value -lt $Index) {
        return [ordered]@{
            index = $Index
            state = "absent"
            stories_count = $countState
        }
    }

    try {
        $story = $Document.Stories.Item($Index)
        return [ordered]@{
            index = $Index
            state = "value"
            type = Get-PubSafeValue { [int]$story.Type } "Story.Type"
            text = Get-PubSafeValue { [string]$story.TextRange.Text } "Story.TextRange.Text"
            text_length = Get-PubSafeValue { [int]$story.TextRange.Length } "Story.TextRange.Length"
        }
    }
    catch {
        $hresult = $null
        if ($_.Exception.HResult) {
            $hresult = Format-PubHResult ([int]$_.Exception.HResult)
        }

        return [ordered]@{
            index = $Index
            state = "error"
            hresult = $hresult
            message = $_.Exception.Message
        }
    }
}

$context = Get-Content -LiteralPath $RunContextPath -Raw | ConvertFrom-Json

$result = [ordered]@{
    schema = "pub-val-auth-01/open-worker/v1"
    started_at = [DateTimeOffset]::Now.ToString("o")
    finished_at = $null
    worker_pid = $PID
    experiment_id = [string]$context.experiment_id
    case_id = [string]$context.case_id
    source_pub = [string]$context.source_pub
    publisher = $null
    open = [ordered]@{
        state = "not_attempted"
        hresult = $null
        message = $null
    }
    document = $null
    save_current = [ordered]@{
        attempted = $false
        state = "not_attempted"
        path = $null
        sha256 = $null
        size = $null
        hresult = $null
        message = $null
    }
}

$application = $null
$document = $null

try {
    $application = New-PubPublisherApplication
    $result.publisher = [ordered]@{
        version = Get-PubSafeValue { [string]$application.Version } "Application.Version"
        build = Get-PubSafeValue { [string]$application.Build } "Application.Build"
        name = Get-PubSafeValue { [string]$application.Name } "Application.Name"
        path = Get-PubSafeValue { [string]$application.Path } "Application.Path"
    }

    try {
        $document = $application.Open([string]$context.source_pub, $true, $false)
        $result.open.state = "returned"
    }
    catch {
        $result.open.state = "exception"
        if ($_.Exception.HResult) {
            $result.open.hresult = Format-PubHResult ([int]$_.Exception.HResult)
        }
        $result.open.message = $_.Exception.Message
    }

    if ($null -ne $document) {
        if ([bool]$context.visible) {
            try {
                $application.ActiveWindow.Visible = $true
            }
            catch {
                # Видимость окна не влияет на semantic capture.
            }
        }

        $result.document = [ordered]@{
            pages_count = Get-PubSafeValue { [int]$document.Pages.Count } "Document.Pages.Count"
            stories_count = Get-PubSafeValue { [int]$document.Stories.Count } "Document.Stories.Count"
            saved = Get-PubSafeValue { [bool]$document.Saved } "Document.Saved"
            story_1 = Get-StoryRecord -Document $document -Index 1
            story_3 = Get-StoryRecord -Document $document -Index 3
        }

        $result.save_current.attempted = $true
        $savePath = Join-Path ([string]$context.output_dir) "normalized-current.pub"
        try {
            # pbFilePublication = 1. Это COM enum PbFileFormat, а не wire enum.
            $document.SaveAs($savePath, 1, $false)
            $fileRecord = Get-PubFileRecord $savePath
            $result.save_current.state = "ok"
            $result.save_current.path = $fileRecord.path
            $result.save_current.sha256 = $fileRecord.sha256
            $result.save_current.size = $fileRecord.size
        }
        catch {
            $result.save_current.state = "error"
            if ($_.Exception.HResult) {
                $result.save_current.hresult = Format-PubHResult ([int]$_.Exception.HResult)
            }
            $result.save_current.message = $_.Exception.Message
        }
    }
}
catch {
    if ($result.open.state -eq "not_attempted") {
        $result.open.state = "worker_exception"
        if ($_.Exception.HResult) {
            $result.open.hresult = Format-PubHResult ([int]$_.Exception.HResult)
        }
        $result.open.message = $_.Exception.Message
    }
}
finally {
    if ($null -ne $document) {
        try {
            $document.Close()
        }
        catch {
            # Cleanup не должен затереть наблюдаемый результат Open/SaveAs.
        }

        try {
            [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($document)
        }
        catch {
            # Best effort cleanup.
        }
    }

    Close-PubPublisherApplication $application
    $result.finished_at = [DateTimeOffset]::Now.ToString("o")
    Write-PubJson -Value $result -Path $ResultPath
}
