param(
    [Parameter(Mandatory = $true)]
    [string]$SnapshotId,

    [Parameter(Mandatory = $false)]
    [string]$OutputRoot = (Join-Path $PSScriptRoot "env-out"),

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 10)]
    [int]$Repeat = 2,

    [switch]$Visible
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "PubRuntime.psm1") -Force

function Get-TextSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-PeTimestamp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $stream = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite
    )
    $reader = New-Object System.IO.BinaryReader($stream)

    try {
        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        $stream.Position = $peOffset + 8
        $seconds = $reader.ReadUInt32()
        return [DateTimeOffset]::FromUnixTimeSeconds([int64]$seconds).ToUniversalTime().ToString("o")
    }
    finally {
        $reader.Close()
        $stream.Close()
    }
}

function Get-ModuleRecord {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $record = Get-PubFileRecord $Path
    $item = Get-Item -LiteralPath $Path
    $version = $item.VersionInfo

    return [ordered]@{
        name = $item.Name
        path = $record.path
        size = $record.size
        sha256 = $record.sha256
        file_version = [string]$version.FileVersion
        product_version = [string]$version.ProductVersion
        pe_timestamp_utc = Get-PeTimestamp $record.path
    }
}

function Get-PublisherModuleInventory {
    param(
        [Parameter(Mandatory = $true)]
        $Publisher
    )

    $result = @()
    if (-not $Publisher.available) {
        return $result
    }

    $pathState = $Publisher.path
    if ($null -eq $pathState -or $pathState.state -ne "value" -or [string]::IsNullOrWhiteSpace([string]$pathState.value)) {
        return $result
    }

    $publisherPath = [string]$pathState.value
    $installDir = if (Test-Path -LiteralPath $publisherPath -PathType Container) {
        $publisherPath
    }
    elseif (Test-Path -LiteralPath $publisherPath -PathType Leaf) {
        Split-Path -Parent $publisherPath
    }
    else {
        $publisherPath
    }

    foreach ($name in @("MSPUB.EXE", "PUBCONV.DLL", "PTXT9.DLL", "PUBOLE.DLL")) {
        $candidate = Join-Path $installDir $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $result += Get-ModuleRecord $candidate
        }
    }

    return $result | Sort-Object name
}

function Get-FontSetFingerprint {
    $fontEntries = @()
    $registryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts",
        "HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"
    )

    foreach ($registryPath in $registryPaths) {
        if (-not (Test-Path -LiteralPath $registryPath)) {
            continue
        }

        $properties = Get-ItemProperty -LiteralPath $registryPath
        foreach ($property in $properties.PSObject.Properties) {
            if ($property.Name -like "PS*") {
                continue
            }

            $fontEntries += "{0}|{1}|{2}" -f $registryPath, $property.Name, [string]$property.Value
        }
    }

    $canonical = @($fontEntries | Sort-Object -Unique)
    return [ordered]@{
        entry_count = $canonical.Count
        sha256 = Get-TextSha256 ($canonical -join "`n")
        entries = $canonical
    }
}

function Get-StableEnvironmentProjection {
    param(
        [Parameter(Mandatory = $true)]
        $Manifest
    )

    return [ordered]@{
        snapshot_id = $Manifest.snapshot_id
        os = $Manifest.os
        powershell = $Manifest.powershell
        locale = $Manifest.locale
        timezone = $Manifest.timezone
        default_printer = $Manifest.default_printer
        publisher = $Manifest.publisher
        publisher_modules = $Manifest.publisher_modules
        font_set = [ordered]@{
            entry_count = $Manifest.font_set.entry_count
            sha256 = $Manifest.font_set.sha256
        }
    }
}

$resolvedOutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
New-Item -ItemType Directory -Force -Path $resolvedOutputRoot | Out-Null

$captures = @()
for ($i = 1; $i -le $Repeat; $i++) {
    $base = Get-PubEnvironmentManifest -SnapshotId $SnapshotId -RequirePublisher -Visible:$Visible
    $base["publisher_modules"] = @(Get-PublisherModuleInventory $base.publisher)
    $base["font_set"] = Get-FontSetFingerprint

    $projection = Get-StableEnvironmentProjection $base
    $projectionJson = $projection | ConvertTo-Json -Depth 32 -Compress
    $base["stable_fingerprint_sha256"] = Get-TextSha256 $projectionJson
    $base["capture_index"] = $i

    $capturePath = Join-Path $resolvedOutputRoot ("environment-{0:D2}.json" -f $i)
    Write-PubJson -Value $base -Path $capturePath

    $captures += [ordered]@{
        index = $i
        path = $capturePath
        stable_fingerprint_sha256 = $base.stable_fingerprint_sha256
    }
}

$fingerprints = @($captures | ForEach-Object { $_.stable_fingerprint_sha256 } | Sort-Object -Unique)
$comparison = [ordered]@{
    schema = "pub-runtime/environment-comparison/v1"
    snapshot_id = $SnapshotId
    capture_count = $captures.Count
    stable = ($fingerprints.Count -eq 1)
    distinct_stable_fingerprints = $fingerprints
    captures = $captures
    interpretation = if ($fingerprints.Count -eq 1) {
        "Стабильная часть EnvironmentManifest совпала во всех process-cold captures."
    }
    else {
        "Зафиксирован environment drift. Native experiment нельзя считать воспроизводимым, пока причина drift не классифицирована."
    }
    guardrails = @(
        "Эти повторы создают новый Publisher COM process, но не заменяют restore VM snapshot между независимыми evidence runs.",
        "SnapshotId является операторской меткой и не доказывает версию Publisher.",
        "Фактическая версия должна подтверждаться COM identity и binary metadata/hashes."
    )
}

$comparisonPath = Join-Path $resolvedOutputRoot "comparison.json"
Write-PubJson -Value $comparison -Path $comparisonPath

Write-Host "LAB-ENV-01 завершён."
Write-Host "Snapshot: $SnapshotId"
Write-Host "Captures: $($captures.Count)"
Write-Host "Stable: $($comparison.stable)"
Write-Host "Comparison: $comparisonPath"

if (-not $comparison.stable) {
    exit 2
}
