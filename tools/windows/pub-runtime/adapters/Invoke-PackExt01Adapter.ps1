param(
    [Parameter(Mandatory = $true)]
    [string]$RunContextPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$runtimeRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $runtimeRoot "PubRuntime.psm1") -Force

function Get-OracleTagValue {
    param(
        [Parameter(Mandatory = $true)]
        $Shape,
        [Parameter(Mandatory = $true)]
        [string]$TagName
    )

    try {
        for ($i = 1; $i -le [int]$Shape.Tags.Count; $i++) {
            $tag = $Shape.Tags.Item($i)
            if ([string]$tag.Name -eq $TagName) {
                return [string]$tag.Value
            }
        }
    }
    catch {
        return $null
    }

    return $null
}

function Find-PackTarget {
    param(
        [Parameter(Mandatory = $true)]
        $Document
    )

    $matches = @()
    for ($pageIndex = 1; $pageIndex -le [int]$Document.Pages.Count; $pageIndex++) {
        $page = $Document.Pages.Item($pageIndex)
        for ($shapeIndex = 1; $shapeIndex -le [int]$page.Shapes.Count; $shapeIndex++) {
            $shape = $page.Shapes.Item($shapeIndex)
            if ((Get-OracleTagValue -Shape $shape -TagName "PUB_ORACLE_ID") -eq "PACK_TARGET") {
                $matches += [ordered]@{
                    page_index = $pageIndex
                    shape_index = $shapeIndex
                    page = $page
                    shape = $shape
                }
            }
        }
    }

    if ($matches.Count -ne 1) {
        throw "Publication должна содержать ровно один PUB_ORACLE_ID=PACK_TARGET; найдено: $($matches.Count)"
    }

    return $matches[0]
}

function Get-PackPictureSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PublicationPath,
        [Parameter(Mandatory = $true)]
        [string]$Phase
    )

    $application = $null
    $document = $null

    try {
        $application = New-PubPublisherApplication
        $document = $application.Open($PublicationPath, $true, $false)

        try {
            $target = Find-PackTarget -Document $document
        }
        catch {
            return [ordered]@{
                phase = $Phase
                state = "target_error"
                message = $_.Exception.Message
                publisher = [ordered]@{
                    version = Get-PubSafeValue { [string]$application.Version } "Application.Version"
                    build = Get-PubSafeValue { [string]$application.Build } "Application.Build"
                }
            }
        }

        $shape = $target.shape
        $page = $target.page

        return [ordered]@{
            phase = $Phase
            state = "value"
            publisher = [ordered]@{
                version = Get-PubSafeValue { [string]$application.Version } "Application.Version"
                build = Get-PubSafeValue { [string]$application.Build } "Application.Build"
            }
            page_index = [int]$target.page_index
            page_id = Get-PubSafeValue { [int]$page.PageID } "Page.PageID"
            shape_index = [int]$target.shape_index
            shape_id = Get-PubSafeValue { [int]$shape.ID } "Shape.ID"
            shape_name = Get-PubSafeValue { [string]$shape.Name } "Shape.Name"
            shape_type = Get-PubSafeValue { [int]$shape.Type } "Shape.Type"
            oracle_tag = Get-OracleTagValue -Shape $shape -TagName "PUB_ORACLE_ID"
            left = Get-PubSafeValue { [double]$shape.Left } "Shape.Left"
            top = Get-PubSafeValue { [double]$shape.Top } "Shape.Top"
            width = Get-PubSafeValue { [double]$shape.Width } "Shape.Width"
            height = Get-PubSafeValue { [double]$shape.Height } "Shape.Height"
            picture = [ordered]@{
                is_linked = Get-PubSafeValue { [bool]$shape.PictureFormat.IsLinked } "PictureFormat.IsLinked"
                file_name = Get-PubSafeValue { [string]$shape.PictureFormat.FileName } "PictureFormat.FileName"
                file_size = Get-PubSafeValue { [int64]$shape.PictureFormat.FileSize } "PictureFormat.FileSize"
                original_file_size = Get-PubSafeValue { [int64]$shape.PictureFormat.OriginalFileSize } "PictureFormat.OriginalFileSize"
                image_format = Get-PubSafeValue { [int]$shape.PictureFormat.ImageFormat } "PictureFormat.ImageFormat"
            }
        }
    }
    finally {
        if ($null -ne $document) {
            try {
                $document.Close()
            }
            catch {
                # Cleanup не меняет зафиксированный semantic snapshot.
            }

            try {
                [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($document)
            }
            catch {
                # Best effort cleanup.
            }
        }

        Close-PubPublisherApplication $application
    }
}

function Copy-DirectoryBound {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceRoot,
        [Parameter(Mandatory = $true)]
        [string]$DestinationRoot
    )

    $source = (Resolve-Path -LiteralPath $SourceRoot).Path
    New-Item -ItemType Directory -Force -Path $DestinationRoot | Out-Null

    $records = @()
    Get-ChildItem -LiteralPath $source -Recurse -File |
        Sort-Object FullName |
        ForEach-Object {
            $relative = $_.FullName.Substring($source.Length).TrimStart([char[]]"\/")
            $destination = Join-Path $DestinationRoot $relative
            $destinationParent = Split-Path -Parent $destination
            New-Item -ItemType Directory -Force -Path $destinationParent | Out-Null

            $binding = Copy-PubBoundFile -Source $_.FullName -Destination $destination
            $records += [ordered]@{
                relative_path = $relative.Replace("\", "/")
                source = $binding.source
                bound_copy = $binding.bound_copy
            }
        }

    return $records
}

$context = Get-Content -LiteralPath $RunContextPath -Raw | ConvertFrom-Json
$caseId = [string]$context.case_id

if ($caseId -notin @("baseline", "manual-linked", "pack-commercial", "pack-computer")) {
    throw "Неизвестный PACK-EXT-01 case_id: $caseId"
}

$assetsRoot = Join-Path ([string]$context.run_dir) "assets"
$emittedRoot = Join-Path $assetsRoot "emitted"
$packageRoot = Join-Path $assetsRoot "package"
New-Item -ItemType Directory -Force -Path $assetsRoot | Out-Null

$result = [ordered]@{
    schema = "pub-pack-ext-01/capture/v1"
    experiment_id = [string]$context.experiment_id
    case_id = $caseId
    action = [ordered]@{
        mode = $caseId
        automated = ($caseId -eq "baseline")
        note = if ($caseId -eq "baseline") {
            "Baseline arm: UI mutation отсутствует."
        }
        else {
            "Graphics Manager / Pack & Go action выполнен оператором до capture; harness не притворяется UI automation."
        }
    }
    source = [ordered]@{
        pub = Get-PubFileRecord ([string]$context.source_pub)
        semantic = Get-PackPictureSnapshot -PublicationPath ([string]$context.source_pub) -Phase "source"
        sentinel_assets = @(Get-PubDirectoryHashes -Root ([string]$context.external_assets_dir))
    }
    rewritten = $null
    emitted_assets = @()
    package = $null
    operator_manifest = $null
    interpretation_guardrails = @(
        "PictureFormat state является semantic oracle, а не BStore/EscherDelay attribution.",
        "Pack & Go destructive-vs-dual-state остаётся experiment result, а не предпосылка adapter'а.",
        "Emitted asset bytes хэшируются до любого повторного import.",
        "PUZ/CAB или ZIP package layer отделяется от rewritten PUB semantics.",
        "Reference COM AddPicture states не приравниваются к Graphics Manager или Pack & Go."
    )
}

$finalResultPath = Join-Path ([string]$context.oracle_dir) "pack-picture-state.json"

if ($result.source.semantic.state -ne "value") {
    Write-PubJson -Value $result -Path $finalResultPath
    throw "Baseline fixture не удовлетворяет PACK_TARGET contract: $($result.source.semantic.message)"
}

if ($caseId -ne "baseline") {
    if ([string]::IsNullOrWhiteSpace($env:PUB_PACK_OPERATOR_MANIFEST)) {
        throw "Для $caseId требуется PUB_PACK_OPERATOR_MANIFEST"
    }

    $operatorSource = (Resolve-Path -LiteralPath $env:PUB_PACK_OPERATOR_MANIFEST).Path
    $operatorParsed = Get-Content -LiteralPath $operatorSource -Raw | ConvertFrom-Json
    if ([string]$operatorParsed.schema -ne "pub-pack-ext-01/operator-action/v1") {
        throw "Неожиданная schema operator manifest: $($operatorParsed.schema)"
    }
    if ([string]$operatorParsed.case_id -ne $caseId) {
        throw "operator manifest case_id=$($operatorParsed.case_id) не совпадает с run case_id=$caseId"
    }

    $operatorDestination = Join-Path ([string]$context.meta_dir) "pack-operator-manifest.json"
    $operatorBinding = Copy-PubBoundFile -Source $operatorSource -Destination $operatorDestination
    $result.operator_manifest = [ordered]@{
        binding = $operatorBinding
        parsed = $operatorParsed
    }

    if ([string]::IsNullOrWhiteSpace($env:PUB_PACK_OUTPUT_PUB)) {
        throw "Для $caseId требуется PUB_PACK_OUTPUT_PUB с exact rewritten publication path"
    }

    $rewrittenSource = (Resolve-Path -LiteralPath $env:PUB_PACK_OUTPUT_PUB).Path
    $rewrittenDestination = Join-Path ([string]$context.output_dir) "rewritten.pub"
    $rewrittenBinding = Copy-PubBoundFile -Source $rewrittenSource -Destination $rewrittenDestination

    $result.rewritten = [ordered]@{
        binding = $rewrittenBinding
        semantic = Get-PackPictureSnapshot -PublicationPath $rewrittenDestination -Phase "rewritten"
    }

    if (-not [string]::IsNullOrWhiteSpace($env:PUB_PACK_ASSETS_ROOT)) {
        if (-not (Test-Path -LiteralPath $env:PUB_PACK_ASSETS_ROOT -PathType Container)) {
            throw "PUB_PACK_ASSETS_ROOT не является каталогом: $($env:PUB_PACK_ASSETS_ROOT)"
        }

        $result.emitted_assets = @(Copy-DirectoryBound -SourceRoot $env:PUB_PACK_ASSETS_ROOT -DestinationRoot $emittedRoot)
    }

    if (-not [string]::IsNullOrWhiteSpace($env:PUB_PACK_PACKAGE_FILE)) {
        $packageSource = (Resolve-Path -LiteralPath $env:PUB_PACK_PACKAGE_FILE).Path
        New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null
        $extension = [System.IO.Path]::GetExtension($packageSource)
        $packageDestination = Join-Path $packageRoot ("package" + $extension)
        $result.package = Copy-PubBoundFile -Source $packageSource -Destination $packageDestination
    }
}

Write-PubJson -Value $result -Path $finalResultPath
