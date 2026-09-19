param(
    [Parameter(Mandatory = $false)]
    [string]$ManifestPath = (Join-Path $PSScriptRoot "manifest.json"),

    [Parameter(Mandatory = $false)]
    [string]$PlanPath = (Join-Path $PSScriptRoot "run-plan.json"),

    [Parameter(Mandatory = $false)]
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path,

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

    Add-PlanRow "fixture" $CaseKey "BLOCKED" "$FixtureId availability=$availability"
    $script:executionBlocked = $true
}

foreach ($wave in $plan.waves) {
    $snapshotName = [string]$wave.snapshot
    if ($null -eq $plan.snapshots.$snapshotName) {
        Add-PlanRow "wave" ([string]$wave.wave_id) "SCHEMA_ERROR" "Неизвестный snapshot=$snapshotName"
        $schemaError = $true
    }

    foreach ($group in $wave.order) {
        $experimentId = [string]$group.experiment_id
        $runnerPath = $null

        if ($null -ne $group.adapter -and -not [string]::IsNullOrWhiteSpace([string]$group.adapter)) {
            $runnerPath = [string]$group.adapter
        }
        elseif ($null -ne $group.entrypoint -and -not [string]::IsNullOrWhiteSpace([string]$group.entrypoint)) {
            $runnerPath = [string]$group.entrypoint
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
            if ($null -ne $case.case_id) {
                $caseId = [string]$case.case_id
            }
            elseif ($null -ne $case.case_id_template) {
                $caseId = [string]$case.case_id_template
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

            $state = [string]$case.state
            if ([string]::IsNullOrWhiteSpace($state)) {
                Add-PlanRow "case" $caseKey "SCHEMA_ERROR" "Case state отсутствует"
                $schemaError = $true
            }
            elseif ($state -eq "needs_parameters") {
                $unresolved = @($case.unresolved)
                if ($unresolved.Count -eq 0) {
                    Add-PlanRow "case" $caseKey "SCHEMA_ERROR" "needs_parameters без unresolved"
                    $schemaError = $true
                }
                else {
                    Add-PlanRow "case" $caseKey "BLOCKED" ("unresolved=" + ($unresolved -join ","))
                    $executionBlocked = $true
                }
            }
            else {
                Add-PlanRow "case" $caseKey "DEFINED" $state
            }

            if ($null -ne $case.source_fixture_id) {
                Check-FixtureReference -FixtureId ([string]$case.source_fixture_id) -CaseKey $caseKey
            }
            else {
                Add-PlanRow "fixture" $caseKey "SCHEMA_ERROR" "source_fixture_id отсутствует"
                $schemaError = $true
            }

            foreach ($assetId in @($case.asset_fixture_ids)) {
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
