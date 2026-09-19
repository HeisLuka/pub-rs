param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("baseline", "manual-linked", "pack-commercial", "pack-computer")]
    [string]$CaseId,

    [Parameter(Mandatory = $true)]
    [string]$SourcePub,

    [Parameter(Mandatory = $true)]
    [string]$SentinelAsset,

    [Parameter(Mandatory = $false)]
    [string]$SourceFixtureId = "",

    [Parameter(Mandatory = $false)]
    [string]$OutputPub = "",

    [Parameter(Mandatory = $false)]
    [string]$EmittedAssetsRoot = "",

    [Parameter(Mandatory = $false)]
    [string]$PackageFile = "",

    [Parameter(Mandatory = $false)]
    [string]$OperatorManifest = "",

    [Parameter(Mandatory = $false)]
    [string]$OutputRoot = (Join-Path $PSScriptRoot "out"),

    [Parameter(Mandatory = $false)]
    [string]$SnapshotId = "MODERN-2019-12527"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$runner = Join-Path $PSScriptRoot "Invoke-PubRuntimeCase.ps1"
$adapter = Join-Path $PSScriptRoot "adapters\Invoke-PackExt01Adapter.ps1"

if ($CaseId -ne "baseline") {
    if ([string]::IsNullOrWhiteSpace($OutputPub)) {
        throw "$CaseId требует -OutputPub с rewritten publication после UI action"
    }

    if ([string]::IsNullOrWhiteSpace($EmittedAssetsRoot)) {
        throw "$CaseId требует -EmittedAssetsRoot"
    }

    if ([string]::IsNullOrWhiteSpace($OperatorManifest)) {
        throw "$CaseId требует -OperatorManifest с точным описанием UI action/options"
    }
}

if (($CaseId -eq "pack-commercial" -or $CaseId -eq "pack-computer") -and
    [string]::IsNullOrWhiteSpace($PackageFile)) {
    throw "$CaseId требует -PackageFile для binding исходного package container"
}

$oldOutputPub = $env:PUB_PACK_OUTPUT_PUB
$oldAssetsRoot = $env:PUB_PACK_ASSETS_ROOT
$oldPackageFile = $env:PUB_PACK_PACKAGE_FILE
$oldOperatorManifest = $env:PUB_PACK_OPERATOR_MANIFEST

try {
    $env:PUB_PACK_OUTPUT_PUB = $OutputPub
    $env:PUB_PACK_ASSETS_ROOT = $EmittedAssetsRoot
    $env:PUB_PACK_PACKAGE_FILE = $PackageFile
    $env:PUB_PACK_OPERATOR_MANIFEST = $OperatorManifest

    $operation = switch ($CaseId) {
        "baseline" {
            "Снять semantic picture state exact embedded baseline без mutation"
        }
        "manual-linked" {
            "Зафиксировать результат operator-run Graphics Manager -> Save as Linked Picture"
        }
        "pack-commercial" {
            "Зафиксировать результат operator-run commercial Pack & Go и распакованные artifacts"
        }
        "pack-computer" {
            "Зафиксировать результат operator-run another-computer Pack & Go и распакованные artifacts"
        }
    }

    $hostPath = Join-Path $PSHOME "powershell.exe"
    if (-not (Test-Path -LiteralPath $hostPath -PathType Leaf)) {
        $hostPath = Join-Path $PSHOME "pwsh.exe"
    }
    if (-not (Test-Path -LiteralPath $hostPath -PathType Leaf)) {
        throw "Не найден PowerShell executable рядом с PSHOME=$PSHOME"
    }

    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", ('"' + $runner + '"'),
        "-ExperimentId", "PACK-EXT-01",
        "-CaseId", $CaseId,
        "-SourcePub", ('"' + $SourcePub + '"'),
        "-AdapterScript", ('"' + $adapter + '"'),
        "-OutputRoot", ('"' + $OutputRoot + '"'),
        "-SnapshotId", $SnapshotId,
        "-Operation", ('"' + $operation + '"'),
        "-ExternalAssets", ('"' + $SentinelAsset + '"'),
        "-RequirePublisher"
    )

    if (-not [string]::IsNullOrWhiteSpace($SourceFixtureId)) {
        $arguments += @("-SourceFixtureId", $SourceFixtureId)
    }

    $runnerProcess = Start-Process -FilePath $hostPath -ArgumentList $arguments -PassThru -Wait
    if ($runnerProcess.ExitCode -ne 0) {
        exit $runnerProcess.ExitCode
    }
}
finally {
    $env:PUB_PACK_OUTPUT_PUB = $oldOutputPub
    $env:PUB_PACK_ASSETS_ROOT = $oldAssetsRoot
    $env:PUB_PACK_PACKAGE_FILE = $oldPackageFile
    $env:PUB_PACK_OPERATOR_MANIFEST = $oldOperatorManifest
}
