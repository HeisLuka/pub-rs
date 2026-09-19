param(
    [Parameter(Mandatory = $true)]
    [string]$ExperimentId,

    [Parameter(Mandatory = $true)]
    [string]$CaseId,

    [Parameter(Mandatory = $true)]
    [string]$SnapshotId,

    [Parameter(Mandatory = $true)]
    [string]$FixtureRoot,

    [Parameter(Mandatory = $false)]
    [string]$ManifestPath = (Join-Path $PSScriptRoot "..\..\..\fixtures\batch-01\manifest.json"),

    [Parameter(Mandatory = $false)]
    [string]$PlanPath = (Join-Path $PSScriptRoot "..\..\..\fixtures\batch-01\run-plan.json"),

    [Parameter(Mandatory = $false)]
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path,

    [Parameter(Mandatory = $false)]
    [string]$OutputRoot = (Join-Path $PSScriptRoot "out"),

    [Parameter(Mandatory = $false)]
    [string]$OperatorOutputPub = "",

    [Parameter(Mandatory = $false)]
    [string]$OperatorAssetsRoot = "",

    [Parameter(Mandatory = $false)]
    [string]$OperatorPackageFile = "",

    [Parameter(Mandatory = $false)]
    [string]$OperatorManifest = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$runtimeRunner = Join-Path $PSScriptRoot "Invoke-PubRuntimeCase.ps1"
if (-not (Test-Path -LiteralPath $runtimeRunner -PathType Leaf)) {
    throw "Не найден общий runtime envelope: $runtimeRunner"
}

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
$fixtureRootResolved = [System.IO.Path]::GetFullPath($FixtureRoot)

function Get-OptionalProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Find-Fixture {
    param(
        [Parameter(Mandatory = $true)][string]$FixtureId
    )

    $matches = @($manifest.fixtures | Where-Object { [string]$_.fixture_id -eq $FixtureId })
    if ($matches.Count -ne 1) {
        throw "Canonical manifest должен содержать ровно один fixture_id=$FixtureId; найдено $($matches.Count)"
    }

    return $matches[0]
}

function Resolve-PinnedFixture {
    param(
        [Parameter(Mandatory = $true)][string]$FixtureId
    )

    $fixture = Find-Fixture -FixtureId $FixtureId
    $availability = [string]$fixture.availability
    if ($availability -notin @("pinned", "external_pinned")) {
        throw "Fixture $FixtureId нельзя запускать: availability=$availability"
    }

    $filename = [string](Get-OptionalProperty -Object $fixture -Name "local_filename")
    if ([string]::IsNullOrWhiteSpace($filename)) {
        throw "Fixture $FixtureId не имеет local_filename"
    }

    $path = Join-Path $fixtureRootResolved $filename
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Локальные bytes fixture $FixtureId отсутствуют: $path"
    }

    $item = Get-Item -LiteralPath $path
    $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    $expectedHash = ([string]$fixture.sha256).ToLowerInvariant()

    if ([string]::IsNullOrWhiteSpace($expectedHash)) {
        throw "Fixture $FixtureId помечен $availability, но canonical SHA-256 отсутствует"
    }
    if ($actualHash -ne $expectedHash) {
        throw "SHA-256 mismatch fixture $FixtureId: expected=$expectedHash actual=$actualHash"
    }

    $sizeProperty = Get-OptionalProperty -Object $fixture -Name "size"
    if ($null -ne $sizeProperty -and [int64]$sizeProperty -ne [int64]$item.Length) {
        throw "Size mismatch fixture $FixtureId: expected=$sizeProperty actual=$($item.Length)"
    }

    return [ordered]@{
        fixture = $fixture
        path = $item.FullName
        sha256 = $actualHash
        size = [int64]$item.Length
    }
}

$caseMatches = @()
foreach ($wave in $plan.waves) {
    foreach ($group in $wave.order) {
        if ([string]$group.experiment_id -ne $ExperimentId) {
            continue
        }

        foreach ($case in $group.cases) {
            $caseValue = Get-OptionalProperty -Object $case -Name "case_id"
            if ($null -ne $caseValue -and [string]$caseValue -eq $CaseId) {
                $caseMatches += [ordered]@{
                    wave = $wave
                    group = $group
                    case = $case
                }
            }
        }
    }
}

if ($caseMatches.Count -ne 1) {
    throw "Run-plan должен содержать ровно один exact case $ExperimentId::$CaseId; найдено $($caseMatches.Count)"
}

$selection = $caseMatches[0]
$waveSnapshot = [string]$selection.wave.snapshot
if ($waveSnapshot -ne $SnapshotId) {
    throw "Snapshot mismatch: case требует $waveSnapshot, передан $SnapshotId"
}

$state = [string](Get-OptionalProperty -Object $selection.case -Name "state")
if ([string]::IsNullOrWhiteSpace($state)) {
    throw "Case $ExperimentId::$CaseId не имеет state"
}
if ($state -like "needs_*" -or $state -like "after_*") {
    throw "Case $ExperimentId::$CaseId заблокирован run-plan state=$state"
}
if ($state -ne "ready" -and $state -notlike "ready_when_*") {
    throw "Неизвестный/неисполняемый run-plan state=$state"
}

$sourceFixtureId = [string](Get-OptionalProperty -Object $selection.case -Name "source_fixture_id")
if ([string]::IsNullOrWhiteSpace($sourceFixtureId)) {
    throw "Case $ExperimentId::$CaseId не имеет source_fixture_id"
}
$source = Resolve-PinnedFixture -FixtureId $sourceFixtureId

$assetPaths = @()
$assetFixtureIds = @(Get-OptionalProperty -Object $selection.case -Name "asset_fixture_ids")
foreach ($assetFixtureId in $assetFixtureIds) {
    if ($null -eq $assetFixtureId -or [string]::IsNullOrWhiteSpace([string]$assetFixtureId)) {
        continue
    }

    $asset = Resolve-PinnedFixture -FixtureId ([string]$assetFixtureId)
    $assetPaths += $asset.path
}

$adapterValue = Get-OptionalProperty -Object $selection.group -Name "adapter"
$entrypointValue = Get-OptionalProperty -Object $selection.group -Name "entrypoint"

if ($null -ne $adapterValue -and -not [string]::IsNullOrWhiteSpace([string]$adapterValue)) {
    $adapterPath = Join-Path $RepoRoot ([string]$adapterValue)
    if (-not (Test-Path -LiteralPath $adapterPath -PathType Leaf)) {
        throw "Adapter отсутствует в integration tree: $adapterPath"
    }

    $operation = "Batch 01 exact case: $ExperimentId / $CaseId"
    $args = @{
        ExperimentId = $ExperimentId
        CaseId = $CaseId
        SourcePub = $source.path
        SourceFixtureId = $sourceFixtureId
        AdapterScript = $adapterPath
        OutputRoot = $OutputRoot
        SnapshotId = $SnapshotId
        Operation = $operation
        RequirePublisher = $true
    }

    if ($assetPaths.Count -gt 0) {
        $args["ExternalAssets"] = $assetPaths
    }

    & $runtimeRunner @args
    exit 0
}

if ($null -eq $entrypointValue -or [string]::IsNullOrWhiteSpace([string]$entrypointValue)) {
    throw "Group $ExperimentId не имеет adapter/entrypoint"
}

$entrypointPath = Join-Path $RepoRoot ([string]$entrypointValue)
if (-not (Test-Path -LiteralPath $entrypointPath -PathType Leaf)) {
    throw "Entrypoint отсутствует в integration tree: $entrypointPath"
}

if ($ExperimentId -ne "PACK-EXT-01") {
    throw "BATCH-CASE-RUNNER-01 пока не имеет безопасного binding contract для entrypoint experiment=$ExperimentId"
}
if ($assetPaths.Count -ne 1) {
    throw "PACK-EXT-01 требует ровно один pinned sentinel asset; найдено $($assetPaths.Count)"
}

$packArgs = @{
    CaseId = $CaseId
    SourcePub = $source.path
    SourceFixtureId = $sourceFixtureId
    SentinelAsset = $assetPaths[0]
    OutputRoot = $OutputRoot
    SnapshotId = $SnapshotId
}

if ($CaseId -ne "baseline") {
    foreach ($required in @(
        @{ name = "OperatorOutputPub"; value = $OperatorOutputPub },
        @{ name = "OperatorAssetsRoot"; value = $OperatorAssetsRoot },
        @{ name = "OperatorManifest"; value = $OperatorManifest }
    )) {
        if ([string]::IsNullOrWhiteSpace([string]$required.value)) {
            throw "PACK case=$CaseId требует -$($required.name)"
        }
    }

    $packArgs["OutputPub"] = $OperatorOutputPub
    $packArgs["EmittedAssetsRoot"] = $OperatorAssetsRoot
    $packArgs["OperatorManifest"] = $OperatorManifest

    if ($CaseId -like "pack-*") {
        if ([string]::IsNullOrWhiteSpace($OperatorPackageFile)) {
            throw "PACK case=$CaseId требует -OperatorPackageFile"
        }
        $packArgs["PackageFile"] = $OperatorPackageFile
    }
}

& $entrypointPath @packArgs
exit 0
