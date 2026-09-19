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
New-Item -ItemType Directory -Force -Path $root | Out-Null

$downloaded = @()
$skipped = @()

foreach ($fixture in $manifest.fixtures) {
    if ([string]$fixture.availability -ne "external_pinned") {
        continue
    }

    $localFilenameProperty = $fixture.PSObject.Properties["local_filename"]
    if ($null -eq $localFilenameProperty -or [string]::IsNullOrWhiteSpace([string]$localFilenameProperty.Value)) {
        throw "external_pinned fixture без local_filename: $($fixture.fixture_id)"
    }

    $sourceIdentityProperty = $fixture.PSObject.Properties["source_identity"]
    if ($null -eq $sourceIdentityProperty -or $null -eq $sourceIdentityProperty.Value) {
        throw "external_pinned fixture без source_identity: $($fixture.fixture_id)"
    }

    $rawUrlProperty = $sourceIdentityProperty.Value.PSObject.Properties["raw_url"]
    if ($null -eq $rawUrlProperty -or [string]::IsNullOrWhiteSpace([string]$rawUrlProperty.Value)) {
        throw "external_pinned fixture без immutable raw_url: $($fixture.fixture_id)"
    }

    $rawUrl = [string]$rawUrlProperty.Value
    $parsedUri = $null
    if (-not [System.Uri]::TryCreate($rawUrl, [System.UriKind]::Absolute, [ref]$parsedUri) -or $parsedUri.Scheme -ne "https") {
        throw "external_pinned raw_url должен быть абсолютным HTTPS URL: $rawUrl"
    }

    $commitProperty = $sourceIdentityProperty.Value.PSObject.Properties["commit"]
    if ($null -ne $commitProperty -and -not [string]::IsNullOrWhiteSpace([string]$commitProperty.Value)) {
        $commit = [string]$commitProperty.Value
        if ($rawUrl.IndexOf($commit, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            throw "raw_url не содержит pinned commit=$commit для fixture $($fixture.fixture_id)"
        }
    }

    $expectedHash = ([string]$fixture.sha256).ToLowerInvariant()
    $expectedSize = [int64]$fixture.size
    $destination = Join-Path $root ([string]$localFilenameProperty.Value)

    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        $existing = Get-Item -LiteralPath $destination
        $existingHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()

        if ($existing.Length -eq $expectedSize -and $existingHash -eq $expectedHash) {
            $skipped += [ordered]@{
                fixture_id = [string]$fixture.fixture_id
                path = $destination
                state = "already_verified"
                size = [int64]$existing.Length
                sha256 = $existingHash
            }
            continue
        }

        throw "Существующий файл не совпадает с pinned identity: $destination"
    }

    $tempPath = "$destination.download"
    if (Test-Path -LiteralPath $tempPath) {
        Remove-Item -LiteralPath $tempPath -Force
    }

    try {
        Invoke-WebRequest -Uri $rawUrl -OutFile $tempPath -UseBasicParsing

        $download = Get-Item -LiteralPath $tempPath
        $actualHash = (Get-FileHash -LiteralPath $tempPath -Algorithm SHA256).Hash.ToLowerInvariant()

        if ($download.Length -ne $expectedSize) {
            throw "Size mismatch для $($fixture.fixture_id): expected=$expectedSize actual=$($download.Length)"
        }
        if ($actualHash -ne $expectedHash) {
            throw "SHA-256 mismatch для $($fixture.fixture_id): expected=$expectedHash actual=$actualHash"
        }

        Move-Item -LiteralPath $tempPath -Destination $destination

        $downloaded += [ordered]@{
            fixture_id = [string]$fixture.fixture_id
            source_url = $rawUrl
            path = $destination
            size = [int64]$download.Length
            sha256 = $actualHash
            state = "downloaded_and_verified"
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
}

$result = [ordered]@{
    schema = "pub-batch-01/external-fixture-acquisition/v1"
    captured_at = [DateTimeOffset]::Now.ToString("o")
    fixture_root = $root
    downloaded = $downloaded
    skipped = $skipped
}

$resultPath = Join-Path $root "external-acquisition.json"
$result | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $resultPath -Encoding utf8

Write-Host "External fixture acquisition завершён."
Write-Host "Downloaded: $($downloaded.Count)"
Write-Host "Already verified: $($skipped.Count)"
Write-Host "Manifest: $resultPath"
