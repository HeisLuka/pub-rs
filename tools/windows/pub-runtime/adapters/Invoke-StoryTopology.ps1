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

if ($caseId -notin @("story-unlinked", "story-linked", "story-link-broken")) {
    throw "Неизвестный story topology case_id: $caseId"
}

function Get-OracleTagValue {
    param(
        [Parameter(Mandatory = $true)]$Shape,
        [Parameter(Mandatory = $true)][string]$Name
    )

    for ($i = 1; $i -le [int]$Shape.Tags.Count; $i++) {
        $tag = $Shape.Tags.Item($i)
        if ([string]$tag.Name -eq $Name) {
            return [string]$tag.Value
        }
    }

    return $null
}

function Find-TaggedShape {
    param(
        [Parameter(Mandatory = $true)]$Document,
        [Parameter(Mandatory = $true)][string]$TagValue
    )

    $matches = @()
    for ($pageIndex = 1; $pageIndex -le [int]$Document.Pages.Count; $pageIndex++) {
        $page = $Document.Pages.Item($pageIndex)
        for ($shapeIndex = 1; $shapeIndex -le [int]$page.Shapes.Count; $shapeIndex++) {
            $shape = $page.Shapes.Item($shapeIndex)
            try {
                if ((Get-OracleTagValue -Shape $shape -Name "PUB_ORACLE_ID") -eq $TagValue) {
                    $matches += $shape
                }
            }
            catch {}
        }
    }

    if ($matches.Count -ne 1) {
        throw "Ожидался ровно один shape с PUB_ORACLE_ID=$TagValue; найдено $($matches.Count)."
    }

    return $matches[0]
}

function Get-FrameSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Shape,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $frame = $Shape.TextFrame

    $nextId = $null
    try {
        if ([int]$frame.HasNextLink -ne 0) {
            $nextId = [int]$frame.NextLinkedTextFrame.Parent.ID
        }
    }
    catch {}

    $prevId = $null
    try {
        if ([int]$frame.HasPreviousLink -ne 0) {
            $prevId = [int]$frame.PreviousLinkedTextFrame.Parent.ID
        }
    }
    catch {}

    return [ordered]@{
        label = $Label
        shape_id = Get-PubSafeValue { [int]$Shape.ID } "Shape.ID"
        shape_name = Get-PubSafeValue { [string]$Shape.Name } "Shape.Name"
        text = Get-PubSafeValue { [string]$frame.TextRange.Text } "TextFrame.TextRange.Text"
        has_next_link = Get-PubSafeValue { [int]$frame.HasNextLink } "TextFrame.HasNextLink"
        has_previous_link = Get-PubSafeValue { [int]$frame.HasPreviousLink } "TextFrame.HasPreviousLink"
        next_shape_id = $nextId
        previous_shape_id = $prevId
        story_text = Get-PubSafeValue { [string]$frame.Story.TextRange.Text } "TextFrame.Story.TextRange.Text"
    }
}

function Get-StoriesSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Document
    )

    $items = @()
    $count = [int]$Document.Stories.Count
    for ($i = 1; $i -le $count; $i++) {
        $story = $Document.Stories.Item($i)
        $items += [ordered]@{
            index = $i
            text = Get-PubSafeValue { [string]$story.TextRange.Text } "Story.TextRange.Text"
            length = Get-PubSafeValue { [int]$story.TextRange.Length } "Story.TextRange.Length"
        }
    }

    return [ordered]@{
        count = $count
        items = $items
    }
}

function Get-TopologySnapshot {
    param(
        [Parameter(Mandatory = $true)]$Application,
        [Parameter(Mandatory = $true)]$Document,
        [Parameter(Mandatory = $true)][string]$Phase
    )

    $shapeA = Find-TaggedShape -Document $Document -TagValue "STORY_A"
    $shapeB = Find-TaggedShape -Document $Document -TagValue "STORY_B"

    return [ordered]@{
        schema = "pub-runtime/story-topology/v1"
        phase = $Phase
        publisher = [ordered]@{
            version = Get-PubSafeValue { [string]$Application.Version } "Application.Version"
            build = Get-PubSafeValue { [string]$Application.Build } "Application.Build"
        }
        frames = @(
            (Get-FrameSnapshot -Shape $shapeA -Label "A"),
            (Get-FrameSnapshot -Shape $shapeB -Label "B")
        )
        stories = Get-StoriesSnapshot $Document
    }
}

function Assert-TextAndGeometryStable {
    param(
        [Parameter(Mandatory = $true)]$BeforeA,
        [Parameter(Mandatory = $true)]$BeforeB,
        [Parameter(Mandatory = $true)]$AfterA,
        [Parameter(Mandatory = $true)]$AfterB
    )

    foreach ($pair in @(@($BeforeA, $AfterA), @($BeforeB, $AfterB))) {
        $before = $pair[0]
        $after = $pair[1]
        if ([string]$before.TextFrame.TextRange.Text -ne [string]$after.TextFrame.TextRange.Text) {
            throw "Story topology mutation изменила TextRange.Text; run не является single-variable."
        }

        foreach ($member in @("Left", "Top", "Width", "Height")) {
            if ([double]$before.$member -ne [double]$after.$member) {
                throw "Story topology mutation изменила geometry $member; run не является single-variable."
            }
        }
    }
}

$application = $null
$document = $null
$outputPath = Join-Path $outputDir "current.pub"

try {
    $application = New-PubPublisherApplication -Visible:$([bool]$context.visible)
    $document = $application.Open($sourcePub, $false, $false)

    $shapeA = Find-TaggedShape -Document $document -TagValue "STORY_A"
    $shapeB = Find-TaggedShape -Document $document -TagValue "STORY_B"

    $beforeStateA = [ordered]@{
        Left = [double]$shapeA.Left
        Top = [double]$shapeA.Top
        Width = [double]$shapeA.Width
        Height = [double]$shapeA.Height
        TextFrame = [ordered]@{ TextRange = [ordered]@{ Text = [string]$shapeA.TextFrame.TextRange.Text } }
    }
    $beforeStateB = [ordered]@{
        Left = [double]$shapeB.Left
        Top = [double]$shapeB.Top
        Width = [double]$shapeB.Width
        Height = [double]$shapeB.Height
        TextFrame = [ordered]@{ TextRange = [ordered]@{ Text = [string]$shapeB.TextFrame.TextRange.Text } }
    }

    $before = Get-TopologySnapshot -Application $application -Document $document -Phase "before"
    Write-PubJson -Value $before -Path (Join-Path $oracleDir "before.json")

    switch ($caseId) {
        "story-unlinked" {
            if ([int]$shapeA.TextFrame.HasNextLink -ne 0) {
                $shapeA.TextFrame.BreakForwardLink()
            }
        }
        "story-linked" {
            if ([int]$shapeA.TextFrame.HasNextLink -ne 0) {
                $shapeA.TextFrame.BreakForwardLink()
            }
            $shapeA.TextFrame.NextLinkedTextFrame = $shapeB.TextFrame
        }
        "story-link-broken" {
            if ([int]$shapeA.TextFrame.HasNextLink -eq 0) {
                $shapeA.TextFrame.NextLinkedTextFrame = $shapeB.TextFrame
            }
            $shapeA.TextFrame.BreakForwardLink()
        }
    }

    $shapeAAfter = Find-TaggedShape -Document $document -TagValue "STORY_A"
    $shapeBAfter = Find-TaggedShape -Document $document -TagValue "STORY_B"
    Assert-TextAndGeometryStable -BeforeA $beforeStateA -BeforeB $beforeStateB -AfterA $shapeAAfter -AfterB $shapeBAfter

    $after = Get-TopologySnapshot -Application $application -Document $document -Phase "after-mutation"
    Write-PubJson -Value $after -Path (Join-Path $oracleDir "after.json")

    # pbFilePublication = 1; API enum, не wire enum.
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
    $reopen = Get-TopologySnapshot -Application $application -Document $document -Phase "reopen"
    Write-PubJson -Value $reopen -Path (Join-Path $oracleDir "reopen.json")
}
finally {
    if ($null -ne $document) {
        try { $document.Close() } catch {}
    }
    Close-PubPublisherApplication $application
}
