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

function Find-AlignmentTarget {
    param(
        [Parameter(Mandatory = $true)]
        $Document,
        [Parameter(Mandatory = $true)]
        [string]$Family,
        [Parameter(Mandatory = $true)]
        [string]$SourceSha256,
        [Parameter(Mandatory = $true)]
        [int]$RequiredAlignment,
        [switch]$DerivedFromVerifiedHalloween
    )

    $taggedMatches = @()
    for ($pageIndex = 1; $pageIndex -le [int]$Document.Pages.Count; $pageIndex++) {
        $page = $Document.Pages.Item($pageIndex)
        for ($shapeIndex = 1; $shapeIndex -le [int]$page.Shapes.Count; $shapeIndex++) {
            $shape = $page.Shapes.Item($shapeIndex)
            $tagValue = Get-OracleTagValue -Shape $shape -TagName "PUB_ORACLE_ID"
            if ($tagValue -eq "ALIGN_TARGET") {
                $taggedMatches += [ordered]@{
                    page_index = $pageIndex
                    shape_index = $shapeIndex
                    page = $page
                    shape = $shape
                    locator = "oracle_tag"
                }
            }
        }
    }

    if ($taggedMatches.Count -eq 1) {
        return $taggedMatches[0]
    }
    if ($taggedMatches.Count -gt 1) {
        throw "Fixture содержит несколько PUB_ORACLE_ID=ALIGN_TARGET: $($taggedMatches.Count)"
    }

    if ($Family -ne "style") {
        throw "Fixture family=$Family требует ровно один PUB_ORACLE_ID=ALIGN_TARGET"
    }

    $knownHalloweenSha256 = "f079765650af152e1ae1fbfded757f679c588ceea884b77329a240c578884c25"
    if (-not $DerivedFromVerifiedHalloween -and $SourceSha256.ToLowerInvariant() -ne $knownHalloweenSha256) {
        throw "Style source fallback разрешён только для exact halloween-flyer.pub SHA-256=$knownHalloweenSha256; получен $SourceSha256"
    }

    if ($DerivedFromVerifiedHalloween -and $SourceSha256.ToLowerInvariant() -ne $knownHalloweenSha256) {
        throw "Derived Halloween locator требует, чтобы parent run был привязан к exact upstream SHA-256=$knownHalloweenSha256"
    }

    $fallbackMatches = @()
    for ($pageIndex = 1; $pageIndex -le [int]$Document.Pages.Count; $pageIndex++) {
        $page = $Document.Pages.Item($pageIndex)
        for ($shapeIndex = 1; $shapeIndex -le [int]$page.Shapes.Count; $shapeIndex++) {
            $shape = $page.Shapes.Item($shapeIndex)

            $name = $null
            try {
                $name = [string]$shape.Name
            }
            catch {
                continue
            }

            if ($name -ne "Text Box 20") {
                continue
            }

            try {
                if ([int]$shape.HasTextFrame -eq 0) {
                    continue
                }

                $text = [string]$shape.TextFrame.TextRange.Text
                if (-not $text.Contains("Children")) {
                    continue
                }

                $alignment = [int]$shape.TextFrame.TextRange.ParagraphFormat.Alignment
                if ($alignment -ne $RequiredAlignment) {
                    throw "Known Halloween target найден, но Alignment=$alignment вместо required=$RequiredAlignment"
                }

                $fallbackMatches += [ordered]@{
                    page_index = $pageIndex
                    shape_index = $shapeIndex
                    page = $page
                    shape = $shape
                    locator = if ($DerivedFromVerifiedHalloween) {
                        "derived_halloween_lineage_name_text_alignment"
                    }
                    else {
                        "known_halloween_sha_name_text_alignment"
                    }
                }
            }
            catch {
                if ($_.Exception.Message -like "Known Halloween target*") {
                    throw
                }
            }
        }
    }

    if ($fallbackMatches.Count -ne 1) {
        throw "Halloween locator требует ровно один Text Box 20 с needle Children и required Alignment=$RequiredAlignment; найдено: $($fallbackMatches.Count)"
    }

    return $fallbackMatches[0]
}

function Get-AlignmentSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        $Target,
        [Parameter(Mandatory = $true)]
        [string]$Phase
    )

    $shape = $Target.shape
    $page = $Target.page

    return [ordered]@{
        phase = $Phase
        page_index = [int]$Target.page_index
        page_id = Get-PubSafeValue { [int]$page.PageID } "Page.PageID"
        shape_index = [int]$Target.shape_index
        shape_id = Get-PubSafeValue { [int]$shape.ID } "Shape.ID"
        shape_name = Get-PubSafeValue { [string]$shape.Name } "Shape.Name"
        oracle_tag = Get-OracleTagValue -Shape $shape -TagName "PUB_ORACLE_ID"
        locator = if ($Target.Contains("locator")) { [string]$Target.locator } else { "unknown" }
        text = Get-PubSafeValue { [string]$shape.TextFrame.TextRange.Text } "TextRange.Text"
        alignment = Get-PubSafeValue { [int]$shape.TextFrame.TextRange.ParagraphFormat.Alignment } "ParagraphFormat.Alignment"
    }
}

$context = Get-Content -LiteralPath $RunContextPath -Raw | ConvertFrom-Json
$caseId = [string]$context.case_id

$match = [regex]::Match(
    $caseId,
    '^(explicit|style)--align-(\d+)--(current|publisher2000|publisher98)$',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)
if (-not $match.Success) {
    throw "Case ID должен иметь вид explicit|style--align-<0..11>--current|publisher2000|publisher98: $caseId"
}

$family = $match.Groups[1].Value.ToLowerInvariant()
$alignmentValue = [int]$match.Groups[2].Value
$writer = $match.Groups[3].Value.ToLowerInvariant()

if ($alignmentValue -lt 0 -or $alignmentValue -gt 11) {
    throw "Alignment value вне controlled matrix 0..11: $alignmentValue"
}

$saveFormats = @{
    current = 1
    publisher98 = 2
    publisher2000 = 3
}
$saveFormatValue = [int]$saveFormats[$writer]

$sourceRecord = Get-PubFileRecord ([string]$context.source_pub)

$result = [ordered]@{
    schema = "pub-para-align-remainder/adapter-result/v1"
    experiment_id = [string]$context.experiment_id
    case_id = $caseId
    family = $family
    requested_alignment = $alignmentValue
    writer = $writer
    source_sha256 = $sourceRecord.sha256
    publisher = $null
    before = $null
    setter = [ordered]@{
        state = "not_attempted"
        hresult = $null
        message = $null
    }
    after_set = $null
    save = [ordered]@{
        attempted = $false
        state = "not_attempted"
        path = $null
        sha256 = $null
        size = $null
        hresult = $null
        message = $null
    }
    reopen = $null
    interpretation_guardrails = @(
        "Успешный ParagraphFormat.Alignment setter не доказывает конкретный FDPP/STSH carrier.",
        "Reopen semantic equality не доказывает byte equality.",
        "publisher2000/publisher98 здесь являются conversion writer arms текущего Publisher, а не native old-version runtime.",
        "Carrier attribution выполняется только последующим offline Quill/STSH diff."
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

    # Для semantic mutation публикация открывается не read-only; AddToRecentFiles отключён.
    $document = $application.Open([string]$context.source_pub, $false, $false)
    $requiredSourceAlignment = if ($family -eq "style") { 2 } else { $alignmentValue }
    $target = Find-AlignmentTarget -Document $document -Family $family -SourceSha256 $sourceRecord.sha256 -RequiredAlignment $requiredSourceAlignment
    $result.before = Get-AlignmentSnapshot -Target $target -Phase "before"

    try {
        $target.shape.TextFrame.TextRange.ParagraphFormat.Alignment = $alignmentValue
        $result.setter.state = "ok"
    }
    catch {
        $result.setter.state = "rejected"
        if ($_.Exception.HResult) {
            $result.setter.hresult = Format-PubHResult ([int]$_.Exception.HResult)
        }
        $result.setter.message = $_.Exception.Message
    }

    $result.after_set = Get-AlignmentSnapshot -Target $target -Phase "after_set"

    if ($result.setter.state -eq "ok") {
        $result.save.attempted = $true
        $outputPath = Join-Path ([string]$context.output_dir) ("alignment-{0}-{1}.pub" -f $alignmentValue, $writer)

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
            # Cleanup не должен менять semantic outcome.
        }

        try {
            [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($document)
        }
        catch {
            # Очистка выполняется по возможности.
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
        $reopenTarget = Find-AlignmentTarget -Document $reopenDocument -Family $family -SourceSha256 $sourceRecord.sha256 -RequiredAlignment $alignmentValue -DerivedFromVerifiedHalloween:($family -eq "style")
        $result.reopen = Get-AlignmentSnapshot -Target $reopenTarget -Phase "reopen"
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
                # Очистка выполняется по возможности.
            }

            try {
                [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($reopenDocument)
            }
            catch {
                # Очистка выполняется по возможности.
            }
        }

        Close-PubPublisherApplication $reopenApplication
    }
}

Write-PubJson -Value $result -Path (Join-Path ([string]$context.oracle_dir) "paragraph-alignment.json")
