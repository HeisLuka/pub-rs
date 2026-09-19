param(
    [Parameter(Mandatory = $true)]
    [string]$RunContextPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$runtimeDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $runtimeDir "PubRuntime.psm1") -Force

$context = Get-Content -LiteralPath $RunContextPath -Raw | ConvertFrom-Json
$caseId = [string]$context.case_id
$sourcePub = [string]$context.source_pub
$oracleDir = [string]$context.oracle_dir
$outputDir = [string]$context.output_dir

# Microsoft Publisher Object Model enum namespace; НЕ on-disk FDPP value contract.
$AlignmentMap = @{
    "align-left" = 0
    "align-center" = 1
    "align-right" = 2
    "align-interword" = 3
    "align-distribute" = 4
}

if (-not $AlignmentMap.ContainsKey($caseId)) {
    throw "Неизвестный alignment case_id: $caseId"
}

function Get-OracleTagValue {
    param(
        [Parameter(Mandatory = $true)]
        $Shape,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    for ($i = 1; $i -le [int]$Shape.Tags.Count; $i++) {
        $tag = $Shape.Tags.Item($i)
        if ([string]$tag.Name -eq $Name) {
            return [string]$tag.Value
        }
    }

    return $null
}

function Find-AlignmentTarget {
    param(
        [Parameter(Mandatory = $true)]
        $Document
    )

    $matches = @()
    for ($pageIndex = 1; $pageIndex -le [int]$Document.Pages.Count; $pageIndex++) {
        $page = $Document.Pages.Item($pageIndex)
        for ($shapeIndex = 1; $shapeIndex -le [int]$page.Shapes.Count; $shapeIndex++) {
            $shape = $page.Shapes.Item($shapeIndex)
            try {
                if ((Get-OracleTagValue -Shape $shape -Name "PUB_ORACLE_ID") -eq "ALIGN_TARGET") {
                    $matches += $shape
                }
            }
            catch {
                # Shape без Tags не является target.
            }
        }
    }

    if ($matches.Count -ne 1) {
        throw "Ожидался ровно один shape с PUB_ORACLE_ID=ALIGN_TARGET; найдено $($matches.Count)."
    }

    return $matches[0]
}

function Get-AlignmentSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        $Application,
        [Parameter(Mandatory = $true)]
        $Document,
        [Parameter(Mandatory = $true)]
        [string]$Phase
    )

    $shape = Find-AlignmentTarget $Document
    $range = $shape.TextFrame.TextRange

    return [ordered]@{
        schema = "pub-runtime/alignment-oracle/v1"
        phase = $Phase
        publisher = [ordered]@{
            version = Get-PubSafeValue { [string]$Application.Version } "Application.Version"
            build = Get-PubSafeValue { [string]$Application.Build } "Application.Build"
        }
        target = [ordered]@{
            page_id = Get-PubSafeValue { [int]$shape.Parent.PageID } "Page.PageID"
            shape_id = Get-PubSafeValue { [int]$shape.ID } "Shape.ID"
            shape_name = Get-PubSafeValue { [string]$shape.Name } "Shape.Name"
            oracle_tag = "ALIGN_TARGET"
            text = Get-PubSafeValue { [string]$range.Text } "TextRange.Text"
            paragraph_alignment = Get-PubSafeValue { [int]$range.ParagraphFormat.Alignment } "ParagraphFormat.Alignment"
        }
    }
}

$application = $null
$document = $null
$outputPath = Join-Path $outputDir "current.pub"

try {
    $application = New-PubPublisherApplication -Visible:$([bool]$context.visible)
    $document = $application.Open($sourcePub, $false, $false)

    $before = Get-AlignmentSnapshot -Application $application -Document $document -Phase "before"
    Write-PubJson -Value $before -Path (Join-Path $oracleDir "before.json")

    $shape = Find-AlignmentTarget $document
    $range = $shape.TextFrame.TextRange
    $range.ParagraphFormat.Alignment = [int]$AlignmentMap[$caseId]

    $after = Get-AlignmentSnapshot -Application $application -Document $document -Phase "after-mutation"
    Write-PubJson -Value $after -Path (Join-Path $oracleDir "after.json")

    # pbFilePublication = 1; API enum, не форматный wire enum.
    $document.SaveAs($outputPath, 1, $false)
}
finally {
    if ($null -ne $document) {
        try { $document.Close() } catch {}
    }
    Close-PubPublisherApplication $application
}

$application = $null
$document = $null
try {
    $application = New-PubPublisherApplication -Visible:$([bool]$context.visible)
    $document = $application.Open($outputPath, $true, $false)
    $reopen = Get-AlignmentSnapshot -Application $application -Document $document -Phase "reopen"
    Write-PubJson -Value $reopen -Path (Join-Path $oracleDir "reopen.json")
}
finally {
    if ($null -ne $document) {
        try { $document.Close() } catch {}
    }
    Close-PubPublisherApplication $application
}
