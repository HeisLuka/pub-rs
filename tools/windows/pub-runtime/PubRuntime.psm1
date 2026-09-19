Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-PubJson {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $Value | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Format-PubHResult {
    param(
        [Parameter(Mandatory = $true)]
        [int]$HResult
    )

    return ('0x{0:X8}' -f ($HResult -band 0xFFFFFFFFL))
}

function Get-PubFileRecord {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $item = Get-Item -LiteralPath $resolved
    if ($item.PSIsContainer) {
        throw "Ожидался файл, но получен каталог: $resolved"
    }

    $hash = Get-FileHash -LiteralPath $resolved -Algorithm SHA256
    return [ordered]@{
        path = $resolved
        name = $item.Name
        size = [int64]$item.Length
        sha256 = $hash.Hash.ToLowerInvariant()
    }
}

function Get-PubSafeValue {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Getter,
        [Parameter(Mandatory = $true)]
        [string]$Member
    )

    try {
        return [ordered]@{
            state = "value"
            member = $Member
            value = & $Getter
        }
    }
    catch {
        $hresult = $null
        if ($_.Exception.HResult) {
            $hresult = Format-PubHResult ([int]$_.Exception.HResult)
        }

        return [ordered]@{
            state = "error"
            member = $Member
            hresult = $hresult
            message = $_.Exception.Message
        }
    }
}

function New-PubPublisherApplication {
    param(
        [switch]$Visible
    )

    $application = New-Object -ComObject Publisher.Application
    if ($Visible) {
        try {
            $application.ActiveWindow.Visible = $true
        }
        catch {
            # До открытия документа ActiveWindow может отсутствовать.
        }
    }

    return $application
}

function Close-PubPublisherApplication {
    param(
        [Parameter(Mandatory = $false)]
        $Application
    )

    if ($null -eq $Application) {
        return
    }

    try {
        $Application.Quit()
    }
    catch {
        Write-Warning "Publisher.Quit завершился ошибкой: $($_.Exception.Message)"
    }

    try {
        [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($Application)
    }
    catch {
        # Освобождение RCW — best effort; provenance результата важнее cleanup-ошибки.
    }

    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}

function Get-PubPublisherIdentity {
    param(
        [switch]$Visible
    )

    $application = $null
    try {
        $application = New-PubPublisherApplication -Visible:$Visible
        return [ordered]@{
            available = $true
            version = Get-PubSafeValue { [string]$application.Version } "Application.Version"
            build = Get-PubSafeValue { [string]$application.Build } "Application.Build"
            name = Get-PubSafeValue { [string]$application.Name } "Application.Name"
            path = Get-PubSafeValue { [string]$application.Path } "Application.Path"
        }
    }
    catch {
        $hresult = $null
        if ($_.Exception.HResult) {
            $hresult = Format-PubHResult ([int]$_.Exception.HResult)
        }

        return [ordered]@{
            available = $false
            hresult = $hresult
            message = $_.Exception.Message
        }
    }
    finally {
        Close-PubPublisherApplication $application
    }
}

function Get-PubEnvironmentManifest {
    param(
        [string]$SnapshotId = "",
        [switch]$RequirePublisher,
        [switch]$Visible
    )

    $publisher = Get-PubPublisherIdentity -Visible:$Visible
    if ($RequirePublisher -and -not $publisher.available) {
        throw "Microsoft Publisher COM automation недоступна: $($publisher.message)"
    }

    $culture = [System.Globalization.CultureInfo]::CurrentCulture
    $uiCulture = [System.Globalization.CultureInfo]::CurrentUICulture

    $timezone = $null
    try {
        $timezone = [System.TimeZoneInfo]::Local.Id
    }
    catch {
        $timezone = $null
    }

    $defaultPrinter = $null
    try {
        $defaultPrinter = (Get-CimInstance Win32_Printer -Filter "Default=True" -ErrorAction Stop |
            Select-Object -First 1 -ExpandProperty Name)
    }
    catch {
        $defaultPrinter = $null
    }

    return [ordered]@{
        schema = "pub-runtime/environment/v1"
        captured_at = [DateTimeOffset]::Now.ToString("o")
        snapshot_id = $SnapshotId
        os = [ordered]@{
            version = [System.Environment]::OSVersion.VersionString
            is_64_bit_os = [System.Environment]::Is64BitOperatingSystem
            is_64_bit_process = [System.Environment]::Is64BitProcess
        }
        powershell = [ordered]@{
            version = $PSVersionTable.PSVersion.ToString()
            edition = if ($PSVersionTable.PSEdition) { [string]$PSVersionTable.PSEdition } else { "Desktop" }
        }
        locale = [ordered]@{
            culture = $culture.Name
            ui_culture = $uiCulture.Name
            ansi_code_page = $culture.TextInfo.ANSICodePage
        }
        timezone = $timezone
        default_printer = $defaultPrinter
        machine = [System.Environment]::MachineName
        publisher = $publisher
    }
}

function Copy-PubBoundFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $before = Get-PubFileRecord $Source
    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    Copy-Item -LiteralPath $before.path -Destination $Destination

    $after = Get-PubFileRecord $Destination
    if ($before.sha256 -ne $after.sha256 -or $before.size -ne $after.size) {
        throw "Binding файла нарушен при копировании: $($before.path)"
    }

    return [ordered]@{
        source = $before
        bound_copy = $after
    }
}


function Bind-PubLabEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComparisonPath,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedSnapshotId,
        [Parameter(Mandatory = $true)]
        [string]$DestinationDir
    )

    $comparisonSource = (Resolve-Path -LiteralPath $ComparisonPath).Path
    $comparison = Get-Content -LiteralPath $comparisonSource -Raw | ConvertFrom-Json

    if ([string]$comparison.schema -ne "pub-runtime/environment-comparison/v1") {
        throw "Неожиданная schema LAB-ENV comparison: $($comparison.schema)"
    }
    if (-not [bool]$comparison.stable) {
        throw "LAB-ENV comparison не является stable; native run запрещён."
    }
    if ([string]$comparison.snapshot_id -ne $ExpectedSnapshotId) {
        throw "LAB-ENV snapshot mismatch: expected=$ExpectedSnapshotId actual=$($comparison.snapshot_id)"
    }

    $fingerprints = @($comparison.distinct_stable_fingerprints)
    if ($fingerprints.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$fingerprints[0])) {
        throw "LAB-ENV comparison должен содержать ровно один stable fingerprint."
    }
    $expectedFingerprint = ([string]$fingerprints[0]).ToLowerInvariant()

    $captures = @($comparison.captures)
    if ($captures.Count -lt 2) {
        throw "LAB-ENV comparison должен содержать минимум два process-cold capture."
    }
    if ([int]$comparison.capture_count -ne $captures.Count) {
        throw "LAB-ENV capture_count не совпадает с фактическим числом capture references."
    }

    New-Item -ItemType Directory -Force -Path $DestinationDir | Out-Null

    $seenIndices = @{}
    $captureBindings = @()
    foreach ($captureRef in $captures) {
        $index = [int]$captureRef.index
        if ($index -lt 1 -or $seenIndices.ContainsKey($index)) {
            throw "LAB-ENV содержит некорректный или повторный capture index=$index"
        }
        $seenIndices[$index] = $true

        $captureSource = (Resolve-Path -LiteralPath ([string]$captureRef.path)).Path
        $capture = Get-Content -LiteralPath $captureSource -Raw | ConvertFrom-Json

        if ([string]$capture.snapshot_id -ne $ExpectedSnapshotId) {
            throw "LAB-ENV capture index=$index имеет snapshot_id=$($capture.snapshot_id), ожидался $ExpectedSnapshotId"
        }

        $captureFingerprint = ([string]$capture.stable_fingerprint_sha256).ToLowerInvariant()
        if ($captureFingerprint -ne $expectedFingerprint) {
            throw "LAB-ENV capture index=$index имеет fingerprint=$captureFingerprint, ожидался $expectedFingerprint"
        }

        $refFingerprint = [string]$captureRef.stable_fingerprint_sha256
        if (-not [string]::IsNullOrWhiteSpace($refFingerprint) -and
            $refFingerprint.ToLowerInvariant() -ne $expectedFingerprint) {
            throw "LAB-ENV comparison reference index=$index расходится по stable fingerprint."
        }

        $captureDestination = Join-Path $DestinationDir ("environment-{0:D2}.json" -f $index)
        if (Test-Path -LiteralPath $captureDestination) {
            throw "LAB-ENV destination уже существует: $captureDestination"
        }

        $binding = Copy-PubBoundFile -Source $captureSource -Destination $captureDestination
        $captureBindings += [ordered]@{
            index = $index
            stable_fingerprint_sha256 = $expectedFingerprint
            file = $binding
        }
    }

    $comparisonDestination = Join-Path $DestinationDir "comparison.json"
    if (Test-Path -LiteralPath $comparisonDestination) {
        throw "LAB-ENV comparison destination уже существует: $comparisonDestination"
    }
    $comparisonBinding = Copy-PubBoundFile -Source $comparisonSource -Destination $comparisonDestination

    return [ordered]@{
        schema = "pub-runtime/lab-environment-binding/v1"
        snapshot_id = $ExpectedSnapshotId
        stable_fingerprint_sha256 = $expectedFingerprint
        comparison = $comparisonBinding
        captures = $captureBindings
        reference_capture_bound_path = $captureBindings[0].file.bound_copy.path
    }
}

function Get-PubRuntimeEnvironmentProjection {
    param(
        [Parameter(Mandatory = $true)]
        $Manifest
    )

    return [ordered]@{
        snapshot_id = [string]$Manifest.snapshot_id
        os = $Manifest.os
        powershell = $Manifest.powershell
        locale = $Manifest.locale
        timezone = $Manifest.timezone
        default_printer = $Manifest.default_printer
        publisher = $Manifest.publisher
    }
}

function Assert-PubRuntimeEnvironmentMatchesLabCapture {
    param(
        [Parameter(Mandatory = $true)]
        $RuntimeManifest,
        [Parameter(Mandatory = $true)]
        [string]$LabCapturePath
    )

    $labCapture = Get-Content -LiteralPath $LabCapturePath -Raw | ConvertFrom-Json
    $runtimeProjection = Get-PubRuntimeEnvironmentProjection -Manifest $RuntimeManifest
    $labProjection = Get-PubRuntimeEnvironmentProjection -Manifest $labCapture

    $runtimeJson = $runtimeProjection | ConvertTo-Json -Depth 32 -Compress
    $labJson = $labProjection | ConvertTo-Json -Depth 32 -Compress
    if ($runtimeJson -ne $labJson) {
        throw "Текущий runtime environment расходится с bound LAB-ENV capture; native run запрещён."
    }

    return [ordered]@{
        state = "match"
        reference_capture = (Resolve-Path -LiteralPath $LabCapturePath).Path
    }
}

function Get-PubDirectoryHashes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $rootPath = (Resolve-Path -LiteralPath $Root).Path
    $records = @()

    Get-ChildItem -LiteralPath $rootPath -Recurse -File |
        Sort-Object FullName |
        ForEach-Object {
            $hash = Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256
            $relative = $_.FullName.Substring($rootPath.Length).TrimStart([char[]]"\/")
            $records += [ordered]@{
                path = $relative.Replace('\', '/')
                size = [int64]$_.Length
                sha256 = $hash.Hash.ToLowerInvariant()
            }
        }

    return $records
}

function Write-PubHashList {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Records,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $lines = @()
    foreach ($record in $Records) {
        $lines += "$($record.sha256)  $($record.path)"
    }
    $lines | Set-Content -LiteralPath $Path -Encoding ascii
}

Export-ModuleMember -Function @(
    "Write-PubJson",
    "Format-PubHResult",
    "Get-PubFileRecord",
    "Get-PubSafeValue",
    "New-PubPublisherApplication",
    "Close-PubPublisherApplication",
    "Get-PubPublisherIdentity",
    "Get-PubEnvironmentManifest",
    "Copy-PubBoundFile",
    "Bind-PubLabEnvironment",
    "Get-PubRuntimeEnvironmentProjection",
    "Assert-PubRuntimeEnvironmentMatchesLabCapture",
    "Get-PubDirectoryHashes",
    "Write-PubHashList"
)
