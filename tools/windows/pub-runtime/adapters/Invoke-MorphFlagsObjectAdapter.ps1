param(
    [Parameter(Mandatory = $true)]
    [string]$RunContextPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$runtimeRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $runtimeRoot "PubRuntime.psm1") -Force

$KnownHelpSha256 = "1e7f38b3ce1d0d956815992b15d361c405fc4bbdced5cdabb3c4581327cc183e"

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

function Get-DescriptorProperty {
    param(
        [Parameter(Mandatory = $true)]
        $Object,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Read-MorphTargetDescriptor {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceSha256,
        [Parameter(Mandatory = $true)]
        [string]$MetaDir
    )

    if ([string]::IsNullOrWhiteSpace($env:PUB_MORPH_TARGET_DESCRIPTOR)) {
        return $null
    }

    $descriptorSource = (Resolve-Path -LiteralPath $env:PUB_MORPH_TARGET_DESCRIPTOR).Path
    $descriptor = Get-Content -LiteralPath $descriptorSource -Raw | ConvertFrom-Json

    if ([string]$descriptor.schema -ne "pub-morph-target-descriptor/v1") {
        throw "Неожиданная schema MORPH target descriptor: $($descriptor.schema)"
    }

    $descriptorSourceSha = ([string]$descriptor.source_sha256).ToLowerInvariant()
    if ($descriptorSourceSha -ne $SourceSha256.ToLowerInvariant()) {
        throw "MORPH target descriptor привязан к source_sha256=$descriptorSourceSha, текущий source=$SourceSha256"
    }

    $crosswalk = Get-DescriptorProperty -Object $descriptor -Name "crosswalk"
    if ($null -eq $crosswalk -or [string]$crosswalk.state -ne "confirmed") {
        throw "MORPH target descriptor должен иметь crosswalk.state=confirmed"
    }

    $ohTrackValue = Get-DescriptorProperty -Object $crosswalk -Name "object_tracking_oh"
    if ($null -eq $ohTrackValue) {
        throw "Подтверждённый MORPH descriptor обязан сохранять ObjectTracking.OhTrack"
    }

    $descriptorDestination = Join-Path $MetaDir "morph-target-descriptor.json"
    $binding = Copy-PubBoundFile -Source $descriptorSource -Destination $descriptorDestination

    return [ordered]@{
        parsed = $descriptor
        binding = $binding
        wizard_tag = [int]$descriptor.wizard_tag
        wizard_tag_instance = [int]$descriptor.wizard_tag_instance
        object_tracking_oh = [int]$ohTrackValue
    }
}

function Add-WizardPairMatchesRecursive {
    param(
        [Parameter(Mandatory = $true)]
        $Shape,
        [Parameter(Mandatory = $true)]
        [int]$PageIndex,
        [Parameter(Mandatory = $true)]
        [string]$TraversalPath,
        [Parameter(Mandatory = $true)]
        [int]$WizardTag,
        [Parameter(Mandatory = $true)]
        [int]$WizardTagInstance,
        [Parameter(Mandatory = $true)]
        [System.Collections.ArrayList]$Matches
    )

    try {
        if ([int]$Shape.WizardTag -eq $WizardTag -and [int]$Shape.WizardTagInstance -eq $WizardTagInstance) {
            [void]$Matches.Add([ordered]@{
                page_index = $PageIndex
                shape_index = $null
                traversal_path = $TraversalPath
                page = $null
                shape = $Shape
                locator = "wizard_tag_instance"
            })
        }
    }
    catch {
        # Shape без доступного wizard identity не является совпадением.
    }

    $groupCount = 0
    try {
        $groupCount = [int]$Shape.GroupItems.Count
    }
    catch {
        return
    }

    for ($i = 1; $i -le $groupCount; $i++) {
        try {
            $child = $Shape.GroupItems.Item($i)
            Add-WizardPairMatchesRecursive -Shape $child -PageIndex $PageIndex -TraversalPath "$TraversalPath/group[$i]" -WizardTag $WizardTag -WizardTagInstance $WizardTagInstance -Matches $Matches
        }
        catch {
            # Ошибка одного group member не превращается в совпадение.
        }
    }
}

function Find-MorphTarget {
    param(
        [Parameter(Mandatory = $true)]
        $Document,
        [Parameter(Mandatory = $true)]
        [string]$SourceSha256,
        [Parameter(Mandatory = $false)]
        $Descriptor,
        [switch]$DerivedFromVerifiedSource
    )

    $taggedMatches = @()
    for ($pageIndex = 1; $pageIndex -le [int]$Document.Pages.Count; $pageIndex++) {
        $page = $Document.Pages.Item($pageIndex)
        for ($shapeIndex = 1; $shapeIndex -le [int]$page.Shapes.Count; $shapeIndex++) {
            $shape = $page.Shapes.Item($shapeIndex)
            if ((Get-OracleTagValue -Shape $shape -TagName "PUB_ORACLE_ID") -eq "MORPH_TARGET") {
                $taggedMatches += [ordered]@{
                    page_index = $pageIndex
                    shape_index = $shapeIndex
                    traversal_path = "page[$pageIndex]/shape[$shapeIndex]"
                    page = $page
                    shape = $shape
                    locator = "oracle_tag"
                    object_tracking_oh = $null
                }
            }
        }
    }

    if ($taggedMatches.Count -eq 1) {
        return $taggedMatches[0]
    }
    if ($taggedMatches.Count -gt 1) {
        throw "Fixture содержит несколько PUB_ORACLE_ID=MORPH_TARGET: $($taggedMatches.Count)"
    }

    if ($null -eq $Descriptor) {
        if ($SourceSha256.ToLowerInvariant() -eq $KnownHelpSha256) {
            throw "Exact help.pub нельзя мутировать без PUB_MORPH_TARGET_DESCRIPTOR с подтверждённым ObjectTracking crosswalk"
        }
        throw "Fixture без MORPH_TARGET требует подтверждённый MORPH target descriptor"
    }

    if (-not $DerivedFromVerifiedSource -and $SourceSha256.ToLowerInvariant() -ne ([string]$Descriptor.parsed.source_sha256).ToLowerInvariant()) {
        throw "Descriptor/source SHA mismatch"
    }

    $matches = New-Object System.Collections.ArrayList
    for ($pageIndex = 1; $pageIndex -le [int]$Document.Pages.Count; $pageIndex++) {
        $page = $Document.Pages.Item($pageIndex)
        for ($shapeIndex = 1; $shapeIndex -le [int]$page.Shapes.Count; $shapeIndex++) {
            $shape = $page.Shapes.Item($shapeIndex)
            Add-WizardPairMatchesRecursive -Shape $shape -PageIndex $pageIndex -TraversalPath "page[$pageIndex]/shape[$shapeIndex]" -WizardTag ([int]$Descriptor.wizard_tag) -WizardTagInstance ([int]$Descriptor.wizard_tag_instance) -Matches $matches
        }
    }

    if ($matches.Count -ne 1) {
        throw "WizardTag=$($Descriptor.wizard_tag) / Instance=$($Descriptor.wizard_tag_instance) должен дать ровно один shape; найдено: $($matches.Count)"
    }

    $target = $matches[0]
    $target.page = $Document.Pages.Item([int]$target.page_index)
    $target.object_tracking_oh = [int]$Descriptor.object_tracking_oh
    return $target
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
        locator = [string]$Target.locator
        traversal_path = [string]$Target.traversal_path
        object_tracking_oh = $Target.object_tracking_oh
        page_index = [int]$Target.page_index
        page_id = Get-PubSafeValue { [int]$page.PageID } "Page.PageID"
        shape_index = [int]$Target.shape_index
        shape_id = Get-PubSafeValue { [int]$shape.ID } "Shape.ID"
        shape_name = Get-PubSafeValue { [string]$shape.Name } "Shape.Name"
        wizard_tag = Get-PubSafeValue { [int]$shape.WizardTag } "Shape.WizardTag"
        wizard_tag_instance = Get-PubSafeValue { [int]$shape.WizardTagInstance } "Shape.WizardTagInstance"
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
$sourceRecord = Get-PubFileRecord ([string]$context.source_pub)
$descriptor = Read-MorphTargetDescriptor -SourceSha256 $sourceRecord.sha256 -MetaDir ([string]$context.meta_dir)

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
    source_sha256 = $sourceRecord.sha256
    operation = $operation
    parameter = $parameter
    target_descriptor = if ($null -eq $descriptor) {
        $null
    }
    else {
        [ordered]@{
            sha256 = $descriptor.binding.bound_copy.sha256
            wizard_tag = $descriptor.wizard_tag
            wizard_tag_instance = $descriptor.wizard_tag_instance
            object_tracking_oh = $descriptor.object_tracking_oh
            crosswalk_state = [string]$descriptor.parsed.crosswalk.state
        }
    }
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
        "WizardTag/Instance, Shape.ID, Contents oh/seqNum, Escher spid и ObjectTracking.OhTrack остаются разными пространствами идентичности.",
        "Для внешнего help.pub mutation запрещена без descriptor со crosswalk.state=confirmed.",
        "OplPo/OplOt/OplLastFmt attribution выполняется только offline decoder'ом.",
        "Restore arm требует отдельно pinned moved source и меняет только Shape.Left.",
        "Scenario/design switch выполняется отдельным adapter'ом."
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
    $target = Find-MorphTarget -Document $document -SourceSha256 $sourceRecord.sha256 -Descriptor $descriptor
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
                $baselineLeft = $null
                $baselineText = Get-OracleTagValue -Shape $shape -TagName "MORPH_BASE_LEFT"

                if (-not [string]::IsNullOrWhiteSpace($baselineText)) {
                    $baselineLeft = [double]::Parse($baselineText, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                elseif ($null -ne $descriptor) {
                    $baselineProperty = $descriptor.parsed.PSObject.Properties["baseline_left"]
                    if ($null -ne $baselineProperty) {
                        $baselineLeft = [double]$baselineProperty.Value
                    }
                }

                if ($null -eq $baselineLeft) {
                    throw "restore-left source требует MORPH_BASE_LEFT либо baseline_left в подтверждённом descriptor"
                }

                if ([math]::Abs(([double]$shape.Left) - [double]$baselineLeft) -lt 0.000001) {
                    throw "restore-left source уже находится на baseline Left"
                }

                $shape.Left = [double]$baselineLeft
                $result.parameter = [double]$baselineLeft
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
            # pbFilePublication = 1 — текущий формат сохранения Publisher.
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
        $reopenTarget = Find-MorphTarget -Document $reopenDocument -SourceSha256 $sourceRecord.sha256 -Descriptor $descriptor -DerivedFromVerifiedSource
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

Write-PubJson -Value $result -Path (Join-Path ([string]$context.oracle_dir) "morph-object.json")
