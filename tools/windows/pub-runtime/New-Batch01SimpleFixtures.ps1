param(
    [Parameter(Mandatory = $true)]
    [string]$SentinelPng,

    [Parameter(Mandatory = $false)]
    [string]$OutputRoot = (Join-Path $PSScriptRoot "fixture-out")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "PubRuntime.psm1") -Force

$PbTextOrientationHorizontal = 1
$PbFilePublication = 1
$MsoFalse = 0
$MsoTrue = -1

function Assert-OutputDoesNotExist {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Paths
    )

    foreach ($path in $Paths) {
        if (Test-Path -LiteralPath $path) {
            throw "Generator не перезаписывает существующий artifact: $path"
        }
    }
}

function Add-OracleTag {
    param(
        [Parameter(Mandatory = $true)]
        $Shape,
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $Shape.Tags.Add("PUB_ORACLE_ID", $Value) | Out-Null
}

function Get-OracleTagValue {
    param(
        [Parameter(Mandatory = $true)]
        $Shape
    )

    try {
        for ($i = 1; $i -le [int]$Shape.Tags.Count; $i++) {
            $tag = $Shape.Tags.Item($i)
            if ([string]$tag.Name -eq "PUB_ORACLE_ID") {
                return [string]$tag.Value
            }
        }
    }
    catch {
        return $null
    }

    return $null
}

function Find-TaggedShape {
    param(
        [Parameter(Mandatory = $true)]
        $Document,
        [Parameter(Mandatory = $true)]
        [string]$TagValue
    )

    $matches = @()
    for ($pageIndex = 1; $pageIndex -le [int]$Document.Pages.Count; $pageIndex++) {
        $page = $Document.Pages.Item($pageIndex)
        for ($shapeIndex = 1; $shapeIndex -le [int]$page.Shapes.Count; $shapeIndex++) {
            $shape = $page.Shapes.Item($shapeIndex)
            if ((Get-OracleTagValue -Shape $shape) -eq $TagValue) {
                $matches += $shape
            }
        }
    }

    if ($matches.Count -ne 1) {
        throw "Ожидался ровно один PUB_ORACLE_ID=$TagValue; найдено: $($matches.Count)"
    }

    return $matches[0]
}

function Close-GeneratedDocument {
    param(
        $Document,
        $Application
    )

    if ($null -ne $Document) {
        try { $Document.Close() } catch {}
        try { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($Document) } catch {}
    }

    Close-PubPublisherApplication $Application
}

function New-AlignmentExplicitFixture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $application = $null
    $document = $null

    try {
        $application = New-PubPublisherApplication
        $document = $application.Documents.Add()
        $page = $document.Pages.Item(1)
        $shape = $page.Shapes.AddTextbox($PbTextOrientationHorizontal, 72, 72, 360, 72)
        Add-OracleTag -Shape $shape -Value "ALIGN_TARGET"
        $shape.TextFrame.TextRange.Text = "PUB-ALIGN-EXPLICIT"
        $shape.TextFrame.TextRange.ParagraphFormat.Alignment = 1

        $document.SaveAs($Path, $PbFilePublication, $false)
    }
    finally {
        Close-GeneratedDocument -Document $document -Application $application
    }

    $application = $null
    $document = $null
    try {
        $application = New-PubPublisherApplication
        $document = $application.Open($Path, $true, $false)
        $shape = Find-TaggedShape -Document $document -TagValue "ALIGN_TARGET"
        $readback = [int]$shape.TextFrame.TextRange.ParagraphFormat.Alignment
        if ($readback -ne 1) {
            throw "ALIGN_TARGET reopen readback=$readback, ожидалось COM Alignment=1"
        }
    }
    finally {
        Close-GeneratedDocument -Document $document -Application $application
    }

    return [ordered]@{
        fixture_id = "ALIGN-EXPLICIT-PARAGRAPH-BASE"
        file = Get-PubFileRecord $Path
        setup = "AddTextbox + PUB_ORACLE_ID=ALIGN_TARGET + text sentinel + ParagraphFormat.Alignment=1"
        verification = "reopen tag count=1 and Alignment=1"
    }
}

function New-StoryFixtures {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UnlinkedPath,
        [Parameter(Mandatory = $true)]
        [string]$LinkedPath
    )

    $application = $null
    $document = $null

    try {
        $application = New-PubPublisherApplication
        $document = $application.Documents.Add()
        $page = $document.Pages.Item(1)

        $shapeA = $page.Shapes.AddTextbox($PbTextOrientationHorizontal, 72, 72, 300, 72)
        Add-OracleTag -Shape $shapeA -Value "STORY_A"
        $shapeA.TextFrame.TextRange.Text = "PUB-STORY-A-SENTINEL"

        $shapeB = $page.Shapes.AddTextbox($PbTextOrientationHorizontal, 72, 180, 300, 72)
        Add-OracleTag -Shape $shapeB -Value "STORY_B"
        $shapeB.TextFrame.TextRange.Text = ""

        $document.SaveAs($UnlinkedPath, $PbFilePublication, $false)
    }
    finally {
        Close-GeneratedDocument -Document $document -Application $application
    }

    $unlinkedRecord = Get-PubFileRecord $UnlinkedPath

    $application = $null
    $document = $null
    try {
        $application = New-PubPublisherApplication
        $document = $application.Open($UnlinkedPath, $false, $false)
        $shapeA = Find-TaggedShape -Document $document -TagValue "STORY_A"
        $shapeB = Find-TaggedShape -Document $document -TagValue "STORY_B"

        if ([int]$shapeA.TextFrame.HasNextLink -ne 0 -or [int]$shapeB.TextFrame.HasPreviousLink -ne 0) {
            throw "Generated unlinked source unexpectedly contains a link"
        }

        $shapeA.TextFrame.NextLinkedTextFrame = $shapeB.TextFrame
        $document.SaveAs($LinkedPath, $PbFilePublication, $false)
    }
    finally {
        Close-GeneratedDocument -Document $document -Application $application
    }

    $application = $null
    $document = $null
    try {
        $application = New-PubPublisherApplication
        $document = $application.Open($LinkedPath, $true, $false)
        $shapeA = Find-TaggedShape -Document $document -TagValue "STORY_A"
        $shapeB = Find-TaggedShape -Document $document -TagValue "STORY_B"

        if ([int]$shapeA.TextFrame.HasNextLink -eq 0 -or [int]$shapeB.TextFrame.HasPreviousLink -eq 0) {
            throw "Generated linked source did not preserve A→B link after reopen"
        }
    }
    finally {
        Close-GeneratedDocument -Document $document -Application $application
    }

    return @(
        [ordered]@{
            fixture_id = "STORY-UNLINKED-BASE"
            file = $unlinkedRecord
            setup = "Two tagged text frames; A contains sentinel text, B empty; no link"
            verification = "pre-derivation readback confirmed A.HasNextLink=0 and B.HasPreviousLink=0"
        },
        [ordered]@{
            fixture_id = "STORY-LINKED-A-B"
            file = Get-PubFileRecord $LinkedPath
            parent_sha256 = $unlinkedRecord.sha256
            derivation = "Open exact STORY-UNLINKED-BASE; one mutation A.NextLinkedTextFrame = B.TextFrame; SaveAs current"
            verification = "reopen confirmed A.HasNextLink!=0 and B.HasPreviousLink!=0"
        }
    )
}

function New-PackFixture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SentinelPath,
        [Parameter(Mandatory = $true)]
        [string]$PublicationPath
    )

    $application = $null
    $document = $null

    try {
        $application = New-PubPublisherApplication
        $document = $application.Documents.Add()
        $page = $document.Pages.Item(1)

        $shape = $page.Shapes.AddPicture(
            $SentinelPath,
            $MsoFalse,
            $MsoTrue,
            72,
            72
        )
        Add-OracleTag -Shape $shape -Value "PACK_TARGET"

        $document.SaveAs($PublicationPath, $PbFilePublication, $false)
    }
    finally {
        Close-GeneratedDocument -Document $document -Application $application
    }

    $application = $null
    $document = $null
    try {
        $application = New-PubPublisherApplication
        $document = $application.Open($PublicationPath, $true, $false)
        $shape = Find-TaggedShape -Document $document -TagValue "PACK_TARGET"
        $isLinked = [bool]$shape.PictureFormat.IsLinked
        if ($isLinked) {
            throw "PACK_TARGET reopen reports IsLinked=true; embedded baseline contract not satisfied"
        }
    }
    finally {
        Close-GeneratedDocument -Document $document -Application $application
    }

    return [ordered]@{
        fixture_id = "PACK-EMBEDDED-PNG-BASE"
        file = Get-PubFileRecord $PublicationPath
        sentinel = Get-PubFileRecord $SentinelPath
        setup = "Shapes.AddPicture(LinkToFile=msoFalse, SaveWithDocument=msoTrue) + PUB_ORACLE_ID=PACK_TARGET"
        verification = "reopen PictureFormat.IsLinked=false"
    }
}

$resolvedOutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
New-Item -ItemType Directory -Force -Path $resolvedOutputRoot | Out-Null

$alignmentPath = Join-Path $resolvedOutputRoot "ALIGN-EXPLICIT-PARAGRAPH-BASE.pub"
$storyUnlinkedPath = Join-Path $resolvedOutputRoot "STORY-UNLINKED-BASE.pub"
$storyLinkedPath = Join-Path $resolvedOutputRoot "STORY-LINKED-A-B.pub"
$packPath = Join-Path $resolvedOutputRoot "PACK-EMBEDDED-PNG-BASE.pub"
$sentinelCopyPath = Join-Path $resolvedOutputRoot "PACK-SENTINEL-PNG.png"
$manifestPath = Join-Path $resolvedOutputRoot "generation-manifest.json"

Assert-OutputDoesNotExist -Paths @(
    $alignmentPath,
    $storyUnlinkedPath,
    $storyLinkedPath,
    $packPath,
    $sentinelCopyPath,
    $manifestPath
)

$sentinelBinding = Copy-PubBoundFile -Source $SentinelPng -Destination $sentinelCopyPath
$publisher = Get-PubPublisherIdentity
if (-not $publisher.available) {
    throw "Microsoft Publisher COM automation недоступна: $($publisher.message)"
}

$startedAt = [DateTimeOffset]::Now
$generated = @()
$generated += New-AlignmentExplicitFixture -Path $alignmentPath
$generated += New-StoryFixtures -UnlinkedPath $storyUnlinkedPath -LinkedPath $storyLinkedPath
$generated += New-PackFixture -SentinelPath $sentinelCopyPath -PublicationPath $packPath

$manifest = [ordered]@{
    schema = "pub-batch-01/simple-fixture-generation/v1"
    started_at = $startedAt.ToString("o")
    finished_at = [DateTimeOffset]::Now.ToString("o")
    publisher = $publisher
    sentinel_binding = $sentinelBinding
    generated = $generated
    not_generated = @(
        "ALIGN-STYLE-TOPOLOGY-BASE — требует независимую уже наблюдаемую style topology.",
        "MORPH-WIZARD-TRACKED-BASE / MORPH-MOVED-LEFT-SOURCE — требуют wizard/tracking state и отдельный scenario contract.",
        "VAL-PARKER/CRVAL — bytes уже существуют в исследовательской базе и должны быть materialized без регенерации."
    )
    guardrails = @(
        "Generated bytes не становятся pinned автоматически.",
        "После generation SHA-256 переносится в fixture manifest только после ручной проверки provenance и exact output.",
        "STORY-LINKED-A-B производен от exact saved unlinked source одной link mutation.",
        "PACK sentinel asset bound copy используется и для insertion, и для последующего PACK-EXT-01 comparison."
    )
}

Write-PubJson -Value $manifest -Path $manifestPath

Write-Host "BATCH-FIXTURE-GEN-01 завершён."
Write-Host "Output: $resolvedOutputRoot"
Write-Host "Manifest: $manifestPath"
