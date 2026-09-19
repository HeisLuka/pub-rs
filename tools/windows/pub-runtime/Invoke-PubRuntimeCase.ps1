param(
    [Parameter(Mandatory = $true)]
    [string]$ExperimentId,

    [Parameter(Mandatory = $true)]
    [string]$CaseId,

    [Parameter(Mandatory = $true)]
    [string]$SourcePub,

    [Parameter(Mandatory = $true)]
    [string]$AdapterScript,

    [Parameter(Mandatory = $false)]
    [string]$OutputRoot = (Join-Path $PSScriptRoot "out"),

    [Parameter(Mandatory = $false)]
    [string]$SnapshotId = "",

    [Parameter(Mandatory = $false)]
    [string]$Operation = "",

    [Parameter(Mandatory = $false)]
    [string[]]$ExternalAssets = @(),

    [Parameter(Mandatory = $false)]
    [string]$StructuralManifest = "",

    [switch]$RequirePublisher,

    [switch]$Visible
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "PubRuntime.psm1") -Force

$sourceRecord = Get-PubFileRecord $SourcePub
$runStarted = [DateTimeOffset]::Now
$runId = "{0}--{1}" -f $runStarted.ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ"), $sourceRecord.sha256.Substring(0, 12)

$experimentDir = Join-Path ([System.IO.Path]::GetFullPath($OutputRoot)) $ExperimentId
$caseDir = Join-Path $experimentDir $CaseId
$runDir = Join-Path $caseDir $runId

if (Test-Path -LiteralPath $runDir) {
    throw "Run directory уже существует; immutable run нельзя перезаписывать: $runDir"
}

$inputDir = Join-Path $runDir "input"
$assetDir = Join-Path $inputDir "external-assets"
$oracleDir = Join-Path $runDir "oracle"
$outputDir = Join-Path $runDir "output"
$inspectDir = Join-Path $runDir "inspect"
$logsDir = Join-Path $runDir "logs"
$metaDir = Join-Path $runDir "meta"

foreach ($dir in @($inputDir, $assetDir, $oracleDir, $outputDir, $inspectDir, $logsDir, $metaDir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

$boundSourcePath = Join-Path $inputDir "source.pub"
$sourceBinding = Copy-PubBoundFile -Source $SourcePub -Destination $boundSourcePath

$assetBindings = @()
foreach ($asset in $ExternalAssets) {
    $assetRecord = Get-PubFileRecord $asset
    $assetDestination = Join-Path $assetDir $assetRecord.name
    if (Test-Path -LiteralPath $assetDestination) {
        throw "Два external asset дают одинаковое имя назначения: $($assetRecord.name)"
    }

    $assetBindings += Copy-PubBoundFile -Source $asset -Destination $assetDestination
}

$structuralBinding = $null
if ($StructuralManifest) {
    $manifestRecord = Get-PubFileRecord $StructuralManifest
    $manifestDestination = Join-Path $metaDir "structural-manifest$([System.IO.Path]::GetExtension($manifestRecord.name))"
    $structuralBinding = Copy-PubBoundFile -Source $StructuralManifest -Destination $manifestDestination
}

$environment = Get-PubEnvironmentManifest -SnapshotId $SnapshotId -RequirePublisher:$RequirePublisher -Visible:$Visible
Write-PubJson -Value $environment -Path (Join-Path $runDir "environment.json")

$fixtureManifest = [ordered]@{
    schema = "pub-runtime/fixture-manifest/v1"
    fixture_id = "$ExperimentId::$CaseId"
    bound_at = [DateTimeOffset]::Now.ToString("o")
    source = $sourceBinding
    external_assets = $assetBindings
    structural_manifest = $structuralBinding
    guardrails = @(
        "whole-file SHA-256 относится к exact bytes bound copy.",
        "structural manifest является отдельным offline artifact и не подменяет raw source bytes.",
        "совпадение имени fixture без совпадения SHA-256 не считается binding."
    )
}
Write-PubJson -Value $fixtureManifest -Path (Join-Path $runDir "fixture-manifest.json")

$operationManifest = [ordered]@{
    schema = "pub-runtime/operation/v1"
    experiment_id = $ExperimentId
    case_id = $CaseId
    operation = $Operation
    adapter = [ordered]@{
        path = (Resolve-Path -LiteralPath $AdapterScript).Path
        sha256 = (Get-PubFileRecord $AdapterScript).sha256
    }
    rule = "Один run arm должен содержать ровно одну заявленную semantic mutation."
}
Write-PubJson -Value $operationManifest -Path (Join-Path $runDir "operation.json")

$runContext = [ordered]@{
    schema = "pub-runtime/context/v1"
    experiment_id = $ExperimentId
    case_id = $CaseId
    run_id = $runId
    run_dir = $runDir
    source_pub = $boundSourcePath
    external_assets_dir = $assetDir
    oracle_dir = $oracleDir
    output_dir = $outputDir
    inspect_dir = $inspectDir
    logs_dir = $logsDir
    meta_dir = $metaDir
    snapshot_id = $SnapshotId
    publisher_required = [bool]$RequirePublisher
    visible = [bool]$Visible
}
$contextPath = Join-Path $metaDir "run-context.json"
Write-PubJson -Value $runContext -Path $contextPath

$adapterResult = [ordered]@{
    status = "not-run"
    started_at = $null
    finished_at = $null
    exit_code = $null
    error = $null
}

try {
    $adapterResult.started_at = [DateTimeOffset]::Now.ToString("o")
    & (Resolve-Path -LiteralPath $AdapterScript).Path -RunContextPath $contextPath
    # PowerShell-адаптер сигнализирует ошибку через terminating exception.
    # $LASTEXITCODE здесь не используется: он относится к последнему native process
    # и может содержать значение от совершенно другой команды.
    $adapterResult.exit_code = 0
    $adapterResult.status = "ok"
}
catch {
    $adapterResult.status = "error"
    $adapterResult.error = [ordered]@{
        message = $_.Exception.Message
        hresult = if ($_.Exception.HResult) {
            Format-PubHResult ([int]$_.Exception.HResult)
        }
        else {
            $null
        }
    }
}
finally {
    $adapterResult.finished_at = [DateTimeOffset]::Now.ToString("o")
    Write-PubJson -Value $adapterResult -Path (Join-Path $runDir "adapter-result.json")
}

$recordsBeforeFinalManifest = Get-PubDirectoryHashes -Root $runDir |
    Where-Object { $_.path -ne "hashes.sha256" -and $_.path -ne "run-manifest.json" }

$runManifest = [ordered]@{
    schema = "pub-runtime/run-manifest/v1"
    experiment_id = $ExperimentId
    case_id = $CaseId
    run_id = $runId
    started_at = $runStarted.ToString("o")
    finished_at = [DateTimeOffset]::Now.ToString("o")
    status = $adapterResult.status
    source_sha256 = $sourceRecord.sha256
    snapshot_id = $SnapshotId
    adapter_result = $adapterResult
    artifact_count_before_final_manifest = @($recordsBeforeFinalManifest).Count
    guardrails = @(
        "Успешный envelope-run не доказывает semantic/read/write контракт PUB.",
        "Native claim допустим только после experiment-specific анализа и evidence reconciliation.",
        "SaveAs conversion output не считается native writer evidence другой версии Publisher."
    )
}
Write-PubJson -Value $runManifest -Path (Join-Path $runDir "run-manifest.json")

# Финальный hash-list покрывает все artifacts, включая run-manifest, кроме самого себя.
$finalRecords = Get-PubDirectoryHashes -Root $runDir |
    Where-Object { $_.path -ne "hashes.sha256" }
Write-PubHashList -Records $finalRecords -Path (Join-Path $runDir "hashes.sha256")

Write-Host "PUB runtime envelope завершён."
Write-Host "Run: $runDir"
Write-Host "Статус adapter: $($adapterResult.status)"

if ($adapterResult.status -ne "ok") {
    exit 2
}
