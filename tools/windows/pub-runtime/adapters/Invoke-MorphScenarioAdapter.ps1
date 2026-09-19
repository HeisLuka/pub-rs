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

function Get-ShapeSemanticSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        $Page,
        [Parameter(Mandatory = $true)]
        $Shape,
        [Parameter(Mandatory = $true)]
        [int]$PageIndex,
        [Parameter(Mandatory = $true)]
        [int]$ShapeIndex
    )

    $textState = [ordered]@{ state = "not_applicable" }
    try {
        if ([int]$Shape.HasTextFrame -ne 0) {
            $textState = Get-PubSafeValue { [string]$Shape.TextFrame.TextRange.Text } "TextFrame.TextRange.Text"
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
        page_index = $PageIndex
        page_id = Get-PubSafeValue { [int]$Page.PageID } "Page.PageID"
        shape_index = $ShapeIndex
        shape_id = Get-PubSafeValue { [int]$Shape.ID } "Shape.ID"
        shape_name = Get-PubSafeValue { [string]$Shape.Name } "Shape.Name"
        oracle_tag = Get-OracleTagValue -Shape $Shape -TagName "PUB_ORACLE_ID"
        wizard_tag = Get-PubSafeValue { [int]$Shape.WizardTag } "Shape.WizardTag"
        wizard_tag_instance = Get-PubSafeValue { [int]$Shape.WizardTagInstance } "Shape.WizardTagInstance"
        is_excess = Get-PubSafeValue { [bool]$Shape.IsExcess } "Shape.IsExcess"
        left = Get-PubSafeValue { [double]$Shape.Left } "Shape.Left"
        top = Get-PubSafeValue { [double]$Shape.Top } "Shape.Top"
        width = Get-PubSafeValue { [double]$Shape.Width } "Shape.Width"
        height = Get-PubSafeValue { [double]$Shape.Height } "Shape.Height"
        rotation = Get-PubSafeValue { [double]$Shape.Rotation } "Shape.Rotation"
        text = $textState
    }
}

function Get-WizardPropertiesSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        $Wizard
    )

    $result = @()
    $countState = Get-PubSafeValue { [int]$Wizard.Properties.Count } "Wizard.Properties.Count"
    if ($countState.state -ne "value") {
        return [ordered]@{
            count = $countState
            items = $result
        }
    }

    for ($i = 1; $i -le [int]$countState.value; $i++) {
        try {
            $property = $Wizard.Properties.Item($i)
            $result += [ordered]@{
                collection_index = $i
                id = Get-PubSafeValue { [int]$property.ID } "WizardProperty.ID"
                name = Get-PubSafeValue { [string]$property.Name } "WizardProperty.Name"
                current_value_id = Get-PubSafeValue { [int]$property.CurrentValueId } "WizardProperty.CurrentValueId"
                enabled = Get-PubSafeValue { [bool]$property.Enabled } "WizardProperty.Enabled"
            }
        }
        catch {
            $result += [ordered]@{
                collection_index = $i
                state = "enumeration_error"
                hresult = if ($_.Exception.HResult) { Format-PubHResult ([int]$_.Exception.HResult) } else { $null }
                message = $_.Exception.Message
            }
        }
    }

    return [ordered]@{
        count = $countState
        items = $result
    }
}

function Get-SurplusShapesSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        $Document
    )

    try {
        $range = $Document.SurplusShapes
        $count = [int]$range.Count
        $items = @()

        for ($i = 1; $i -le $count; $i++) {
            $shape = $range.Item($i)
            $items += [ordered]@{
                collection_index = $i
                shape_id = Get-PubSafeValue { [int]$shape.ID } "SurplusShape.ID"
                shape_name = Get-PubSafeValue { [string]$shape.Name } "SurplusShape.Name"
                oracle_tag = Get-OracleTagValue -Shape $shape -TagName "PUB_ORACLE_ID"
                wizard_tag = Get-PubSafeValue { [int]$shape.WizardTag } "SurplusShape.WizardTag"
                wizard_tag_instance = Get-PubSafeValue { [int]$shape.WizardTagInstance } "SurplusShape.WizardTagInstance"
            }
        }

        return [ordered]@{
            state = "value"
            count = $count
            items = $items
        }
    }
    catch {
        return [ordered]@{
            state = "error"
            hresult = if ($_.Exception.HResult) { Format-PubHResult ([int]$_.Exception.HResult) } else { $null }
            message = $_.Exception.Message
            items = @()
        }
    }
}

function Get-MorphScenarioSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        $Document,
        [Parameter(Mandatory = $true)]
        [string]$Phase
    )

    $wizardState = $null
    try {
        $wizard = $Document.Wizard
        $wizardState = [ordered]@{
            state = "value"
            id = Get-PubSafeValue { [int]$wizard.ID } "Wizard.ID"
            name = Get-PubSafeValue { [string]$wizard.Name } "Wizard.Name"
            properties = Get-WizardPropertiesSnapshot -Wizard $wizard
        }
    }
    catch {
        $wizardState = [ordered]@{
            state = "error"
            hresult = if ($_.Exception.HResult) { Format-PubHResult ([int]$_.Exception.HResult) } else { $null }
            message = $_.Exception.Message
            properties = [ordered]@{
                count = $null
                items = @()
            }
        }
    }

    $pages = @()
    $morphTargetCount = 0

    for ($pageIndex = 1; $pageIndex -le [int]$Document.Pages.Count; $pageIndex++) {
        $page = $Document.Pages.Item($pageIndex)
        $shapes = @()

        for ($shapeIndex = 1; $shapeIndex -le [int]$page.Shapes.Count; $shapeIndex++) {
            $shape = $page.Shapes.Item($shapeIndex)
            $shapeSnapshot = Get-ShapeSemanticSnapshot -Page $page -Shape $shape -PageIndex $pageIndex -ShapeIndex $shapeIndex
            if ($shapeSnapshot.oracle_tag -eq "MORPH_TARGET") {
                $morphTargetCount++
            }
            $shapes += $shapeSnapshot
        }

        $pages += [ordered]@{
            page_index = $pageIndex
            page_id = Get-PubSafeValue { [int]$page.PageID } "Page.PageID"
            shapes = $shapes
        }
    }

    return [ordered]@{
        phase = $Phase
        pages_count = Get-PubSafeValue { [int]$Document.Pages.Count } "Document.Pages.Count"
        wizard = $wizardState
        morph_target_count = $morphTargetCount
        surplus_shapes = Get-SurplusShapesSnapshot -Document $Document
        pages = $pages
    }
}

function Get-FirstWizardDesignValue {
    param(
        [Parameter(Mandatory = $true)]
        $Snapshot
    )

    if ($Snapshot.wizard.state -ne "value") {
        return $null
    }

    $items = @($Snapshot.wizard.properties.items)
    if ($items.Count -lt 1) {
        return $null
    }

    $first = $items[0]
    if ($null -eq $first.current_value_id -or $first.current_value_id.state -ne "value") {
        return $null
    }

    return [int]$first.current_value_id.value
}

$context = Get-Content -LiteralPath $RunContextPath -Raw | ConvertFrom-Json
$caseId = [string]$context.case_id

$match = [regex]::Match(
    $caseId,
    '^change-document--wizard-(\d+)--design-(\d+)$',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)
if (-not $match.Success) {
    throw "Case ID должен иметь вид change-document--wizard-<id>--design-<id>: $caseId"
}

$targetWizard = [int]$match.Groups[1].Value
$targetDesign = [int]$match.Groups[2].Value

$result = [ordered]@{
    schema = "pub-morph-scenario-01/change-document/v1"
    experiment_id = [string]$context.experiment_id
    case_id = $caseId
    target = [ordered]@{
        wizard_id = $targetWizard
        design_id = $targetDesign
        namespace = "Publisher COM/API"
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
    event_capture = [ordered]@{
        wizard_after_change = "not_instrumented"
        note = "Microsoft documents WizardAfterChange as a wizard-operation event, but this adapter does not claim event observation without a dedicated COM event sink."
    }
    interpretation_guardrails = @(
        "Wizard/design IDs belong to the Publisher COM/API namespace and are not OplControlling raw IDs.",
        "Exactly one Document.ChangeDocument call is made in this arm.",
        "No format/move/resize/rotation mutation is added to this arm.",
        "Mass object changes are expected behavior of the semantic operation and must be classified, not normalized away.",
        "Field-to-API mapping is established only by offline binary diff."
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
    $result.before = Get-MorphScenarioSnapshot -Document $document -Phase "before"

    if ($result.before.wizard.state -ne "value") {
        throw "Source publication не имеет доступного Document.Wizard"
    }
    if ([int]$result.before.morph_target_count -ne 1) {
        throw "Source publication должна содержать ровно один PUB_ORACLE_ID=MORPH_TARGET; найдено: $($result.before.morph_target_count)"
    }

    $beforeWizard = $null
    if ($result.before.wizard.id.state -eq "value") {
        $beforeWizard = [int]$result.before.wizard.id.value
    }
    $beforeDesign = Get-FirstWizardDesignValue -Snapshot $result.before

    if ($null -ne $beforeWizard -and $null -ne $beforeDesign -and
        $beforeWizard -eq $targetWizard -and $beforeDesign -eq $targetDesign) {
        throw "Target wizard/design совпадает с documented current design probe; no-op arm запрещён"
    }

    try {
        $document.ChangeDocument($targetWizard, $targetDesign)
        $result.mutation.state = "ok"
    }
    catch {
        $result.mutation.state = "error"
        if ($_.Exception.HResult) {
            $result.mutation.hresult = Format-PubHResult ([int]$_.Exception.HResult)
        }
        $result.mutation.message = $_.Exception.Message
    }

    $result.after = Get-MorphScenarioSnapshot -Document $document -Phase "after"

    if ($result.mutation.state -eq "ok") {
        $outputPath = Join-Path ([string]$context.output_dir) ("morph-scenario-w{0}-d{1}.pub" -f $targetWizard, $targetDesign)

        try {
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
        $result.reopen = Get-MorphScenarioSnapshot -Document $reopenDocument -Phase "reopen"
    }
    catch {
        $result.reopen = [ordered]@{
            phase = "reopen"
            state = "error"
            hresult = if ($_.Exception.HResult) { Format-PubHResult ([int]$_.Exception.HResult) } else { $null }
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

Write-PubJson -Value $result -Path (Join-Path ([string]$context.oracle_dir) "morph-scenario.json")
