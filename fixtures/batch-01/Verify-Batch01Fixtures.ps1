param(
    [Parameter(Mandatory = $true)]
    [string]$FixtureRoot,

    [Parameter(Mandatory = $false)]
    [string]$ManifestPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $PSScriptRoot "manifest.json"
}

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$root = [System.IO.Path]::GetFullPath($FixtureRoot)

$failed = $false
$rows = @()

foreach ($fixture in $manifest.fixtures) {
    $expected = $fixture.sha256
    if ([string]::IsNullOrWhiteSpace([string]$expected)) {
        $rows += [pscustomobject]@{
            fixture_id = $fixture.fixture_id
            availability = $fixture.availability
            state = "UNPINNED"
            expected_sha256 = ""
            actual_sha256 = ""
        }
        continue
    }

    $localFilenameProperty = $fixture.PSObject.Properties["local_filename"]
    $localFilename = if ($null -eq $localFilenameProperty) { $null } else { [string]$localFilenameProperty.Value }
    if ([string]::IsNullOrWhiteSpace($localFilename)) {
        $rows += [pscustomobject]@{
            fixture_id = $fixture.fixture_id
            availability = $fixture.availability
            state = "MANIFEST_ERROR"
            expected_sha256 = $expected
            actual_sha256 = ""
        }
        $failed = $true
        continue
    }

    $path = Join-Path $root $localFilename
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $availability = [string]$fixture.availability
        $isRequiredNow = $availability -eq "pinned" -or $availability -eq "external_pinned"

        $rows += [pscustomobject]@{
            fixture_id = $fixture.fixture_id
            availability = $availability
            state = if ($isRequiredNow) { "MISSING_REQUIRED" } else { "MISSING_PENDING" }
            expected_sha256 = $expected
            actual_sha256 = ""
        }

        if ($isRequiredNow) {
            $failed = $true
        }
        continue
    }

    $item = Get-Item -LiteralPath $path
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    $sizeMatches = ($null -eq $fixture.size) -or ([int64]$fixture.size -eq [int64]$item.Length)
    $hashMatches = $actual -eq ([string]$expected).ToLowerInvariant()

    $state = if ($hashMatches -and $sizeMatches) { "OK" } else { "MISMATCH" }
    if ($state -ne "OK") {
        $failed = $true
    }

    $rows += [pscustomobject]@{
        fixture_id = $fixture.fixture_id
        availability = $fixture.availability
        state = $state
        expected_sha256 = $expected
        actual_sha256 = $actual
    }
}

$rows | Format-Table -AutoSize

if ($failed) {
    Write-Error "Fixture bundle не соответствует pinned manifest или содержит отсутствующие pinned bytes."
    exit 2
}

Write-Host "Проверка fixture manifest завершена без hash mismatch."
