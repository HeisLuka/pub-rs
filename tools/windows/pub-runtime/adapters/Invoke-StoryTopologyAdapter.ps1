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

function Find-StoryTargets {
    param(
        [Parameter(Mandatory = $true)]
        $Document
    )

    $found = @{}
    for ($pageIndex = 1; $pageIndex -le [int]$Document.Pages.Count; $pageIndex++) {
        $page = $Document.Pages.Item($pageIndex)
        for ($shapeIndex = 1; $shapeIndex -le [int]$page.Shapes.Count; $shapeIndex++) {
            $shape = $page.Shapes.Item($shapeIndex)
            $tagValue = Get-OracleTagValue -Shape $shape -TagName "PUB_ORACLE_ID"
            if ($tagValue -eq "STORY_A" -or $tagValue -eq "STORY_B") {
                if ($found.ContainsKey($tagValue)) {
                    throw "Fixture содержит повторный PUB_ORACLE_ID=$tagValue"
                }

                $found[$tagValue] = [ordered]@{
                    page_index = $pageIndex
                    shape_index = $shapeIndex
                    page = $page
                    shape = $shape
                }
            }
        }
    }

    if (-not $found.ContainsKey("STORY_A") -or -not $found.ContainsKey("STORY_B")) {
        throw "Fixture должен содержать ровно STORY_A и STORY_B tags"
    }

    return [ordered]@{
        A = $found["STORY_A"]
        B = $found["STORY_B"]
    }
}

function Get-LinkedFrameSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        $Frame,
        [Parameter(Mandatory = $true)]
        [ValidateSet("next", "previous")]
        [string]$Direction
    )

    try {
        $linkedFrame = if ($Direction -eq "next") {
            $Frame.NextLinkedTextFrame
        }
        else {
            $Frame.PreviousLinkedTextFrame
        }

        if ($null -eq $linkedFrame) {
            return [ordered]@{
                state = "none"
            }
        }

        $parentShape = $linkedFrame.Parent
        return [ordered]@{
            state = "value"
            shape_id = Get-PubSafeValue { [int]$parentShape.ID } "LinkedTextFrame.Parent.ID"
            shape_name = Get-PubSafeValue { [string]$parentShape.Name } "LinkedTextFrame.Parent.Name"
            oracle_tag = Get-OracleTagValue -Shape $parentShape -TagName "PUB_ORACLE_ID"
        }
    }
    catch {
        $hresult = $null
        if ($_.Exception.HResult) {
            $hresult = Format-PubHResult ([int]$_.Exception.HResult)
        }

        return [ordered]@{
            state = "error"
            hresult = $hresult
            message = $_.Exception.Message
        }
    }
}

function Get-FrameSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        $Target,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $shape = $Target.shape
    $page = $Target.page
    $frame = $shape.TextFrame

    return [ordered]@{
        label = $Label
        page_index = [int]$Target.page_index
        page_id = Get-PubSafeValue { [int]$page.PageID } "Page.PageID"
        shape_index = [int]$Target.shape_index
        shape_id = Get-PubSafeValue { [int]$shape.ID } "Shape.ID"
        shape_name = Get-PubSafeValue { [string]$shape.Name } "Shape.Name"
        oracle_tag = Get-OracleTagValue -Shape $shape -TagName "PUB_ORACLE_ID"
        text = Get-PubSafeValue { [string]$frame.TextRange.Text } "TextFrame.TextRange.Text"
        has_next_link = Get-PubSafeValue { [int]$frame.HasNextLink } "TextFrame.HasNextLink"
        has_previous_link = Get-PubSafeValue { [int]$frame.HasPreviousLink } "TextFrame.HasPreviousLink"
        next = Get-LinkedFrameSnapshot -Frame $frame -Direction "next"
        previous = Get-LinkedFrameSnapshot -Frame $frame -Direction "previous"
        story = [ordered]@{
            type = Get-PubSafeValue { [int]$frame.Story.Type } "TextFrame.Story.Type"
            text = Get-PubSafeValue { [string]$frame.Story.TextRange.Text } "TextFrame.Story.TextRange.Text"
        }
    }
}

function Get-TopologySnapshot {
    param(
        [Parameter(Mandatory = $true)]
        $Document,
        [Parameter(Mandatory = $true)]
        [string]$Phase
    )

    $targets = Find-StoryTargets -Document $Document
    return [ordered]@{
        phase = $Phase
        stories_count = Get-PubSafeValue { [int]$Document.Stories.Count } "Document.Stories.Count"
        A = Get-FrameSnapshot -Target $targets.A -Label "A"
        B = Get-FrameSnapshot -Target $targets.B -Label "B"
    }
}

function Get-LinkStateBool {
    param(
        [Parameter(Mandatory = $true)]
        $Frame,
        [Parameter(Mandatory = $true)]
        [ValidateSet("next", "previous")]
        [string]$Direction
    )

    $value = if ($Direction -eq "next") {
        [int]$Frame.HasNextLink
    }
    else {
        [int]$Frame.HasPreviousLink
    }

    return $value -ne 0
}

$context = Get-Content -LiteralPath $RunContextPath -Raw | ConvertFrom-Json
$caseId = [string]$context.case_id

$match = [regex]::Match(
    $caseId,
    '^(unlinked|link|break)--(current|publisher2000|publisher98)$',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)
if (-not $match.Success) {
    throw "Case ID должен иметь вид unlinked|link|break--current|publisher2000|publisher98: $caseId"
}

$operation = $match.Groups[1].Value.ToLowerInvariant()
$writer = $match.Groups[2].Value.ToLowerInvariant()

$saveFormats = @{
    current = 1
    publisher98 = 2
    publisher2000 = 3
}
$saveFormatValue = [int]$saveFormats[$writer]

$result = [ordered]@{
    schema = "pub-com-oracle-03/story-topology/v1"
    experiment_id = [string]$context.experiment_id
    case_id = $caseId
    operation = $operation
    writer = $writer
    publisher = $null
    before = $null
    mutation = [ordered]@{
        state = "not_attempted"
        hresult = $null
        message = $null
    }
    after = $null
    save = [ordered]@{
        state = "not_attempted"
        path = $null
        sha256 = $null
        size = $null
        hresult = $null
        message = $null
    }
    reopen = $null
    interpretation_guardrails = @(
        "COM story/link topology является semantic oracle, а не wire topology.",
        "Break arm стартует из уже linked exact source и содержит одну semantic mutation.",
        "Link arm стартует из unlinked exact source и содержит одну semantic mutation.",
        "Old-format SaveAs является conversion writer arm.",
        "Изменение text при link/break сохраняется как observation и не нормализуется harness'ом."
    )
}

$application = $null
$document = $null

try {
    $application = New-PubPublisherApplication
    $result.publisher = [ordered]@{
        version = Get-PubSafeValue { [string]$application.Version } "Application.Version"
        build = Get-PubSafeValue { [string]$application.Build } "Application.Build"
        path = Get-PubSafeValue { [string]$application.Path } "Application.Path"
    }

    $document = $application.Open([string]$context.source_pub, $false, $false)
    $targets = Find-StoryTargets -Document $document
    $result.before = Get-TopologySnapshot -Document $document -Phase "before"

    $aFrame = $targets.A.shape.TextFrame
    $bFrame = $targets.B.shape.TextFrame

    try {
        switch ($operation) {
            "unlinked" {
                if ((Get-LinkStateBool -Frame $aFrame -Direction "next") -or
                    (Get-LinkStateBool -Frame $bFrame -Direction "previous")) {
                    throw "unlinked control fixture уже содержит A→B link"
                }

                $result.mutation.state = "control_no_mutation"
            }

            "link" {
                if ((Get-LinkStateBool -Frame $aFrame -Direction "next") -or
                    (Get-LinkStateBool -Frame $bFrame -Direction "previous")) {
                    throw "link arm требует unlinked source fixture"
                }

                $aFrame.NextLinkedTextFrame = $bFrame
                $result.mutation.state = "ok"
            }

            "break" {
                if (-not (Get-LinkStateBool -Frame $aFrame -Direction "next")) {
                    throw "break arm требует source fixture с forward link из STORY_A"
                }

                $aFrame.BreakForwardLink()
                $result.mutation.state = "ok"
            }
        }
    }
    catch {
        $result.mutation.state = "error"
        if ($_.Exception.HResult) {
            $result.mutation.hresult = Format-PubHResult ([int]$_.Exception.HResult)
        }
        $result.mutation.message = $_.Exception.Message
    }

    $result.after = Get-TopologySnapshot -Document $document -Phase "after"

    if ($result.mutation.state -eq "ok" -or $result.mutation.state -eq "control_no_mutation") {
        $outputPath = Join-Path ([string]$context.output_dir) ("story-{0}-{1}.pub" -f $operation, $writer)

        try {
            $document.SaveAs($outputPath, $saveFormatValue, $false)
            $fileRecord = Get-PubFileRecord $outputPath
            $result.save.state = "ok"
            $result.save.path = $fileRecord.path
            $result.save.sha256 = $fileRecord.sha256
            $result.save.size = $fileRecord.size
        }
        catch {
            $result.save.state = "error"
            if ($_.Exception.HResult) {
                $result.save.hresult = Format-PubHResult ([int]$_.Exception.HResult)
            }
            $result.save.message = $_.Exception.Message
        }
    }
}
finally {
    if ($null -ne $document) {
        try {
            $document.Close()
        }
        catch {
            # Cleanup не меняет зафиксированный semantic outcome.
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

if ($result.save.state -eq "ok") {
    $reopenApplication = $null
    $reopenDocument = $null

    try {
        $reopenApplication = New-PubPublisherApplication
        $reopenDocument = $reopenApplication.Open([string]$result.save.path, $true, $false)
        $result.reopen = Get-TopologySnapshot -Document $reopenDocument -Phase "reopen"
    }
    catch {
        $hresult = $null
        if ($_.Exception.HResult) {
            $hresult = Format-PubHResult ([int]$_.Exception.HResult)
        }

        $result.reopen = [ordered]@{
            phase = "reopen"
            state = "error"
            hresult = $hresult
            message = $_.Exception.Message
        }
    }
    finally {
        if ($null -ne $reopenDocument) {
            try {
                $reopenDocument.Close()
            }
            catch {
                # Best effort cleanup.
            }

            try {
                [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($reopenDocument)
            }
            catch {
                # Best effort cleanup.
            }
        }

        Close-PubPublisherApplication $reopenApplication
    }
}

Write-PubJson -Value $result -Path (Join-Path ([string]$context.oracle_dir) "story-topology.json")
