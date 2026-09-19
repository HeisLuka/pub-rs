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

function Find-MorphTarget {
    param(
        [Parameter(Mandatory = $true)]
        $Document
    )

    $matches = @()
    for ($pageIndex = 1; $pageIndex -le [int]$Document.Pages.Count; $pageIndex++) {
        $page = $Document.Pages.Item($pageIndex)
        for ($shapeIndex = 1; $shapeIndex -le [int]$page.Shapes.Count; $shapeIndex++) {
            $shape = $page.Shapes.Item($shapeIndex)
            if ((Get-OracleTagValue -Shape $shape -TagName "PUB_ORACLE_ID") -eq "MORPH_TARGET") {
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
        throw "Fixture должен содержать ровно один PUB_ORACLE_ID=MORPH_TARGET; найдено: $($matches.Count)"
    }

    return $matches[0]
}

function Get-MorphSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        $Target,
        [Parameter(Mandatory = $true)]
        [string]$Phase
    )

    $shape = $Target.shape
    $page = $Target.page

    $textState = [ordered]@{
        state = "not_applicable"
    }
    try {
        if ([int]$shape.HasTextFrame -ne 0) {
            $textState = Get-PubSafeValue { [string]$shape.TextFrame.TextRange.Text } "TextFrame.TextRange.Text"
        }
    }
    catch {
        $textState = [ordered]@{
            state = "error"
            member = "TextFrame.TextRange.Text"
            hresult = if ($_.Exception.HResult) { Format-PubHResult ([int]$_.Exception.HResult) } else { $null }
            message = $_.Exception.Message
        }
    }

    return [ordered]@{
        phase = $Phase
        page_index = [int]$Target.page_index
        page_id = Get-PubSafeValue { [int]$page.PageID } "Page.PageID"
        shape_index = [int]$Target.shape_index
        shape_id = Get-PubSafeValue { [int]$shape.ID } "Shape.ID"
        shape_name = Get-PubSafeValue { [string]$shape.Name } "Shape.Name"
        oracle_tag = Get-OracleTagValue -Shape $shape -TagName "PUB_ORACLE_ID"
        baseline_left_tag = Get-OracleTagValue -Shape $shape -TagName "MORPH_BASE_LEFT"
        left = Get-PubSafeValue { [double]$shape.Left } "Shape.Left"
        top = Get-PubSafeValue { [double]$shape.Top } "Shape.Top"
        width = Get-PubSafeValue { [double]$shape.Width } "Shape.Width"
        height = Get-PubSafeValue { [double]$shape.Height } "Shape.Height"
        rotation = Get-PubSafeValue { [double]$shape.Rotation } "Shape.Rotation"
        fill_rgb = Get-PubSafeValue { [int]$shape.Fill.ForeColor.RGB } "Shape.Fill.ForeColor.RGB"
        line_rgb = Get-PubSafeValue { [int]$shape.Line.ForeColor.RGB } "Shape.Line.ForeColor.RGB"
        text = $textState
    }
}

$context = Get-Content -LiteralPath $RunContextPath -Raw | ConvertFrom-Json
$caseId = [string]$context.case_id

$operation = $null
$parameter = $null

if ($caseId -match '^format-fill-([0-9A-Fa-f]{6})$') {
    $operation = "format-fill"
    $parameter = [Convert]::ToInt32($Matches[1], 16)
}
elseif ($caseId -match '^move-x-(-?\d+(?:\.\d+)?)$') {
    $operation = "move-x"
    $parameter = [double]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture)
}
elseif ($caseId -match '^resize-width-(-?\d+(?:\.\d+)?)$') {
    $operation = "resize-width"
    $parameter = [double]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture)
}
elseif ($caseId -match '^rotate-(-?\d+(?:\.\d+)?)$') {
    $operation = "rotate"
    $parameter = [double]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture)
}
elseif ($caseId -eq "restore-left") {
    $operation = "restore-left"
}
else {
    throw "Неизвестный MORPH case_id: $caseId"
}

if (($operation -eq "move-x" -or $operation -eq "resize-width" -or $operation -eq "rotate") -and [double]$parameter -eq 0.0) {
    throw "Delta=0 не является controlled mutation: $caseId"
}

$result = [ordered]@{
    schema = "pub-morph-flags-01/object-adapter/v1"
    experiment_id = [string]$context.experiment_id
    case_id = $caseId
    operation = $operation
    parameter = $parameter
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
        "Adapter меняет ровно одно COM property на object-level arm.",
        "OplPo/OplOt/OplLastFmt attribution выполняется только offline decoder'ом.",
        "Restore arm требует отдельный moved source и меняет только Shape.Left.",
        "Scenario/design switch этим adapter'ом не автоматизируется."
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
    $target = Find-MorphTarget -Document $document
    $result.before = Get-MorphSnapshot -Target $target -Phase "before"
    $shape = $target.shape

    try {
        switch ($operation) {
            "format-fill" {
                $beforeRgb = [int]$shape.Fill.ForeColor.RGB
                if ($beforeRgb -eq [int]$parameter) {
                    throw "format-fill sentinel совпадает с baseline Fill.ForeColor.RGB"
                }

                $shape.Fill.ForeColor.RGB = [int]$parameter
            }

            "move-x" {
                $shape.Left = [double]$shape.Left + [double]$parameter
            }

            "resize-width" {
                $newWidth = [double]$shape.Width + [double]$parameter
                if ($newWidth -le 0) {
                    throw "resize-width даёт неположительную Width=$newWidth"
                }
                $shape.Width = $newWidth
            }

            "rotate" {
                $shape.Rotation = [double]$shape.Rotation + [double]$parameter
            }

            "restore-left" {
                $baselineText = Get-OracleTagValue -Shape $shape -TagName "MORPH_BASE_LEFT"
                if ([string]::IsNullOrWhiteSpace($baselineText)) {
                    throw "restore-left source обязан содержать MORPH_BASE_LEFT"
                }

                $baselineLeft = [double]::Parse($baselineText, [System.Globalization.CultureInfo]::InvariantCulture)
                if ([math]::Abs(([double]$shape.Left) - $baselineLeft) -lt 0.000001) {
                    throw "restore-left source уже находится на baseline Left"
                }

                $shape.Left = $baselineLeft
                $result.parameter = $baselineLeft
            }
        }

        $result.mutation.state = "ok"
    }
    catch {
        $result.mutation.state = "error"
        if ($_.Exception.HResult) {
            $result.mutation.hresult = Format-PubHResult ([int]$_.Exception.HResult)
        }
        $result.mutation.message = $_.Exception.Message
    }

    $result.after = Get-MorphSnapshot -Target $target -Phase "after"

    if ($result.mutation.state -eq "ok") {
        $outputPath = Join-Path ([string]$context.output_dir) ("morph-{0}.pub" -f $caseId)

        try {
            # pbFilePublication = 1: current Publisher writer.
            $document.SaveAs($outputPath, 1, $false)
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
            # Cleanup не меняет зафиксированный outcome.
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
        $reopenTarget = Find-MorphTarget -Document $reopenDocument
        $result.reopen = Get-MorphSnapshot -Target $reopenTarget -Phase "reopen"
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

Write-PubJson -Value $result -Path (Join-Path ([string]$context.oracle_dir) "morph-object.json")
