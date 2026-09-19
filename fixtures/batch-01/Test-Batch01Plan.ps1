param(
    [Parameter(Mandatory = $false)]
    [string]$ManifestPath = (Join-Path $PSScriptRoot "manifest.json"),

    [Parameter(Mandatory = $false)]
    [string]$PlanPath = (Join-Path $PSScriptRoot "run-plan.json"),

    [Parameter(Mandatory = $false)]
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path,

    [Parameter(Mandatory = $false)]
    [string]$FixtureRoot = "",

    [switch]$RequireExecutable,

    [switch]$CheckAdapters
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json

$fixtures = @{}
foreach ($fixture in $manifest.fixtures) {
    $id = [string]$fixture.fixture_id
    if ($fixtures.ContainsKey($id)) {
        throw "Duplicate fixture_id в manifest: $id"
    }
    $fixtures[$id] = $fixture
}

$rows = @()
$schemaError = $false
$executionBlocked = $false
$seenCases = @{}

function Get-OptionalProperty {
    param(
        [Parameter(Mandatory = $true)]
        $Object,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Add-PlanRow {
    param(
        [string]$Kind,
        [string]$Key,
        [string]$State,
        [string]$Detail
    )

    $script:rows += [pscustomobject]@{
        kind = $Kind
        key = $Key
        state = $State
        detail = $Detail
    }
}

function Check-FixtureReference {
    param(
        [string]$FixtureId,
        [string]$CaseKey
    )

    if (-not $fixtures.ContainsKey($FixtureId)) {
        Add-PlanRow "fixture" $CaseKey "SCHEMA_ERROR" "Неизвестный fixture_id=$FixtureId"
        $script:schemaError = $true
        return
    }

    $fixture = $fixtures[$FixtureId]
    $availability = [string]$fixture.availability

    if ($availability -eq "pinned") {
        Add-PlanRow "fixture" $CaseKey "PINNED" $FixtureId
        return
    }

    if ($availability -eq "external_pinned") {
        if ([string]::IsNullOrWhiteSpace($FixtureRoot)) {
            Add-PlanRow "fixture" $CaseKey "BLOCKED" "$FixtureId availability=external_pinned; FixtureRoot не передан для local verification"
            $script:executionBlocked = $true
            return
        }

        $localFilename = [string](Get-OptionalProperty -Object $fixture -Name "local_filename")
        if ([string]::IsNullOrWhiteSpace($localFilename)) {
            Add-PlanRow "fixture" $CaseKey "SCHEMA_ERROR" "$FixtureId external_pinned без local_filename"
            $script:schemaError = $true
            return
        }

        $localPath = Join-Path ([System.IO.Path]::GetFullPath($FixtureRoot)) $localFilename
        if (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) {
            Add-PlanRow "fixture" $CaseKey "BLOCKED" "$FixtureId local bytes отсутствуют: $localPath"
            $script:executionBlocked = $true
            return
        }

        $actualHash = (Get-FileHash -LiteralPath $localPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $expectedHash = ([string]$fixture.sha256).ToLowerInvariant()
        $actualSize = [int64](Get-Item -LiteralPath $localPath).Length
        $expectedSize = [int64]$fixture.size

        if ($actualHash -ne $expectedHash -or $actualSize -ne $expectedSize) {
            Add-PlanRow "fixture" $CaseKey "BLOCKED" "$FixtureId local identity mismatch"
            $script:executionBlocked = $true
            return
        }

        Add-PlanRow "fixture" $CaseKey "PINNED_EXTERNAL" "$FixtureId local size/SHA-256 verified"
        return
    }

    Add-PlanRow "fixture" $CaseKey "BLOCKED" "$FixtureId availability=$availability"
    $script:executionBlocked = $true
}

foreach ($wave in $plan.waves) {
    $snapshotName = [string]$wave.snapshot
    if (-not ($plan.snapshots.PSObject.Properties.Name -contains $snapshotName)) {
        Add-PlanRow "wave" ([string]$wave.wave_id) "SCHEMA_ERROR" "Неизвестный snapshot=$snapshotName"
        $schemaError = $true
    }
    else {
        $snapshotDefinition = $plan.snapshots.PSObject.Properties[$snapshotName].Value
        $requiredLabel = [string](Get-OptionalProperty -Object $snapshotDefinition -Name "required_label")
        if ([string]::IsNullOrWhiteSpace($requiredLabel)) {
            Add-PlanRow "wave" ([string]$wave.wave_id) "SCHEMA_ERROR" "snapshot=$snapshotName без required_label"
            $schemaError = $true
        }
        else {
            Add-PlanRow "wave" ([string]$wave.wave_id) "DEFINED" "$snapshotName -> $requiredLabel"
        }
    }

    foreach ($group in $wave.order) {
        $experimentId = [string]$group.experiment_id
        $runnerPath = $null

        $adapterValue = Get-OptionalProperty -Object $group -Name "adapter"
        $entrypointValue = Get-OptionalProperty -Object $group -Name "entrypoint"

        if ($null -ne $adapterValue -and -not [string]::IsNullOrWhiteSpace([string]$adapterValue)) {
            $runnerPath = [string]$adapterValue
        }
        elseif ($null -ne $entrypointValue -and -not [string]::IsNullOrWhiteSpace([string]$entrypointValue)) {
            $runnerPath = [string]$entrypointValue
        }
        else {
            Add-PlanRow "runner" $experimentId "SCHEMA_ERROR" "Нет adapter/entrypoint"
            $schemaError = $true
        }

        if ($CheckAdapters -and $null -ne $runnerPath) {
            $fullRunnerPath = Join-Path $RepoRoot $runnerPath
            if (-not (Test-Path -LiteralPath $fullRunnerPath -PathType Leaf)) {
                Add-PlanRow "runner" $experimentId "BLOCKED" "Не найден в integration tree: $runnerPath"
                $executionBlocked = $true
            }
            else {
                Add-PlanRow "runner" $experimentId "OK" $runnerPath
            }
        }

        foreach ($case in $group.cases) {
            $caseId = $null
            $caseIdValue = Get-OptionalProperty -Object $case -Name "case_id"
            $caseTemplateValue = Get-OptionalProperty -Object $case -Name "case_id_template"
            if ($null -ne $caseIdValue) {
                $caseId = [string]$caseIdValue
            }
            elseif ($null -ne $caseTemplateValue) {
                $caseId = [string]$caseTemplateValue
            }

            if ([string]::IsNullOrWhiteSpace($caseId)) {
                Add-PlanRow "case" $experimentId "SCHEMA_ERROR" "Case без case_id/case_id_template"
                $schemaError = $true
                continue
            }

            $caseKey = "$experimentId::$caseId"
            if ($seenCases.ContainsKey($caseKey)) {
                Add-PlanRow "case" $caseKey "SCHEMA_ERROR" "Duplicate case key"
                $schemaError = $true
            }
            else {
                $seenCases[$caseKey] = $true
            }

            $state = [string](Get-OptionalProperty -Object $case -Name "state")
            if ([string]::IsNullOrWhiteSpace($state)) {
                Add-PlanRow "case" $caseKey "SCHEMA_ERROR" "Case state отсутствует"
                $schemaError = $true
            }
            elseif ($state -like "needs_*" -or $state -like "after_*") {
                $unresolvedValue = Get-OptionalProperty -Object $case -Name "unresolved"
                $unresolved = @($unresolvedValue | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) })
                $detail = "state=$state"
                if ($unresolved.Count -gt 0) {
                    $detail += "; unresolved=" + ($unresolved -join ",")
                }
                Add-PlanRow "case" $caseKey "BLOCKED" $detail
                $executionBlocked = $true
            }
            elseif ($state -eq "ready" -or $state -like "ready_when_*") {
                Add-PlanRow "case" $caseKey "DEFINED" $state
            }
            else {
                Add-PlanRow "case" $caseKey "SCHEMA_ERROR" "Неизвестный state=$state; допустимы ready, ready_when_*, needs_*, after_*"
                $schemaError = $true
            }

            $sourceFixtureId = Get-OptionalProperty -Object $case -Name "source_fixture_id"
            if ($null -ne $sourceFixtureId) {
                Check-FixtureReference -FixtureId ([string]$sourceFixtureId) -CaseKey $caseKey
            }
            else {
                Add-PlanRow "fixture" $caseKey "SCHEMA_ERROR" "source_fixture_id отсутствует"
                $schemaError = $true
            }

            $assetFixtureIds = Get-OptionalProperty -Object $case -Name "asset_fixture_ids"
            foreach ($assetId in @($assetFixtureIds)) {
                if ($null -ne $assetId -and -not [string]::IsNullOrWhiteSpace([string]$assetId)) {
                    Check-FixtureReference -FixtureId ([string]$assetId) -CaseKey "$caseKey asset"
                }
            }
        }
    }
}

$rows | Format-Table -AutoSize

if ($schemaError) {
    Write-Error "Batch 01 run-plan содержит schema/integrity errors."
    exit 3
}

if ($RequireExecutable -and $executionBlocked) {
    Write-Error "Batch 01 structurally valid, но ещё не executable: есть unresolved parameters/unpinned fixtures/missing adapters."
    exit 2
}

if ($executionBlocked) {
    Write-Host "Batch 01 plan structurally valid; execution blockers остаются."
}
else {
    Write-Host "Batch 01 plan structurally valid и не содержит обнаруженных execution blockers."
}
