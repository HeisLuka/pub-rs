param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePub,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = (Join-Path $PSScriptRoot "morph-object-targets.json")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$runtimeRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $runtimeRoot "PubRuntime.psm1") -Force

$KnownHelpSha256 = "1e7f38b3ce1d0d956815992b15d361c405fc4bbdced5cdabb3c4581327cc183e"

function Get-ShapeWizardSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        $Shape
    )

    try {
        $wizard = $Shape.Wizard
        return [ordered]@{
            state = "value"
            id = Get-PubSafeValue { [int]$wizard.ID } "Shape.Wizard.ID"
            name = Get-PubSafeValue { [string]$wizard.Name } "Shape.Wizard.Name"
        }
    }
    catch {
        return [ordered]@{
            state = "error"
            hresult = if ($_.Exception.HResult) { Format-PubHResult ([int]$_.Exception.HResult) } else { $null }
            message = $_.Exception.Message
        }
    }
}

function Get-ShapeTextSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        $Shape
    )

    try {
        if ([int]$Shape.HasTextFrame -eq 0) {
            return [ordered]@{ state = "not_applicable" }
        }

        return Get-PubSafeValue { [string]$Shape.TextFrame.TextRange.Text } "TextFrame.TextRange.Text"
    }
    catch {
        return [ordered]@{
            state = "error"
            hresult = if ($_.Exception.HResult) { Format-PubHResult ([int]$_.Exception.HResult) } else { $null }
            message = $_.Exception.Message
        }
    }
}

function Get-ShapeRecord {
    param(
        [Parameter(Mandatory = $true)]
        $Shape,
        [Parameter(Mandatory = $true)]
        [int]$PageIndex,
        [Parameter(Mandatory = $true)]
        [string]$TraversalPath,
        [Parameter(Mandatory = $false)]
        [array]$GroupAncestors = @()
    )

    $isGroupMember = Get-PubSafeValue { [bool]$Shape.IsGroupMember } "Shape.IsGroupMember"
    $webNavSetName = Get-PubSafeValue { [string]$Shape.WebNavigationBarSetName } "Shape.WebNavigationBarSetName"

    return [ordered]@{
        page_index = $PageIndex
        traversal_path = $TraversalPath
        group_ancestors = $GroupAncestors
        shape_id = Get-PubSafeValue { [int]$Shape.ID } "Shape.ID"
        shape_name = Get-PubSafeValue { [string]$Shape.Name } "Shape.Name"
        shape_type = Get-PubSafeValue { [int]$Shape.Type } "Shape.Type"
        wizard_tag = Get-PubSafeValue { [int]$Shape.WizardTag } "Shape.WizardTag"
        wizard_tag_instance = Get-PubSafeValue { [int]$Shape.WizardTagInstance } "Shape.WizardTagInstance"
        wizard = Get-ShapeWizardSnapshot -Shape $Shape
        is_group_member = $isGroupMember
        web_navigation_bar_set_name = $webNavSetName
        is_excess = Get-PubSafeValue { [bool]$Shape.IsExcess } "Shape.IsExcess"
        left = Get-PubSafeValue { [double]$Shape.Left } "Shape.Left"
        top = Get-PubSafeValue { [double]$Shape.Top } "Shape.Top"
        width = Get-PubSafeValue { [double]$Shape.Width } "Shape.Width"
        height = Get-PubSafeValue { [double]$Shape.Height } "Shape.Height"
        rotation = Get-PubSafeValue { [double]$Shape.Rotation } "Shape.Rotation"
        text = Get-ShapeTextSnapshot -Shape $Shape
    }
}

function Add-ShapeRecursive {
    param(
        [Parameter(Mandatory = $true)]
        $Shape,
        [Parameter(Mandatory = $true)]
        [int]$PageIndex,
        [Parameter(Mandatory = $true)]
        [string]$TraversalPath,
        [Parameter(Mandatory = $true)]
        [System.Collections.ArrayList]$Records,
        [Parameter(Mandatory = $false)]
        [array]$GroupAncestors = @()
    )

    [void]$Records.Add((Get-ShapeRecord -Shape $Shape -PageIndex $PageIndex -TraversalPath $TraversalPath -GroupAncestors $GroupAncestors))

    $groupCount = 0
    try {
        $groupCount = [int]$Shape.GroupItems.Count
    }
    catch {
        return
    }

    if ($groupCount -le 0) {
        return
    }

    $ancestorRecord = [ordered]@{
        shape_id = Get-PubSafeValue { [int]$Shape.ID } "Group.ID"
        shape_name = Get-PubSafeValue { [string]$Shape.Name } "Group.Name"
        wizard_tag = Get-PubSafeValue { [int]$Shape.WizardTag } "Group.WizardTag"
        wizard_tag_instance = Get-PubSafeValue { [int]$Shape.WizardTagInstance } "Group.WizardTagInstance"
        web_navigation_bar_set_name = Get-PubSafeValue { [string]$Shape.WebNavigationBarSetName } "Group.WebNavigationBarSetName"
        wizard = Get-ShapeWizardSnapshot -Shape $Shape
    }
    $nextAncestors = @($GroupAncestors) + @($ancestorRecord)

    for ($i = 1; $i -le $groupCount; $i++) {
        try {
            $child = $Shape.GroupItems.Item($i)
            Add-ShapeRecursive -Shape $child -PageIndex $PageIndex -TraversalPath "$TraversalPath/group[$i]" -Records $Records -GroupAncestors $nextAncestors
        }
        catch {
            [void]$Records.Add([ordered]@{
                page_index = $PageIndex
                traversal_path = "$TraversalPath/group[$i]"
                state = "group_enumeration_error"
                hresult = if ($_.Exception.HResult) { Format-PubHResult ([int]$_.Exception.HResult) } else { $null }
                message = $_.Exception.Message
                group_ancestors = $nextAncestors
            })
        }
    }
}

function Get-WebNavigationBarSetsSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        $Document
    )

    try {
        $sets = $Document.WebNavigationBarSets
        $count = [int]$sets.Count
        $items = @()

        for ($i = 1; $i -le $count; $i++) {
            try {
                $set = $sets.Item($i)
                $items += [ordered]@{
                    collection_index = $i
                    name = Get-PubSafeValue { [string]$set.Name } "WebNavigationBarSet.Name"
                    design = Get-PubSafeValue { [int]$set.Design } "WebNavigationBarSet.Design"
                    auto_update = Get-PubSafeValue { [bool]$set.AutoUpdate } "WebNavigationBarSet.AutoUpdate"
                    is_horizontal = Get-PubSafeValue { [bool]$set.IsHorizontal } "WebNavigationBarSet.IsHorizontal"
                    links_count = Get-PubSafeValue { [int]$set.Links.Count } "WebNavigationBarSet.Links.Count"
                }
            }
            catch {
                $items += [ordered]@{
                    collection_index = $i
                    state = "enumeration_error"
                    hresult = if ($_.Exception.HResult) { Format-PubHResult ([int]$_.Exception.HResult) } else { $null }
                    message = $_.Exception.Message
                }
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

$source = Get-PubFileRecord $SourcePub
if ($source.sha256 -ne $KnownHelpSha256) {
    throw "Read-only MORPH discovery пока привязан только к exact help.pub SHA-256=$KnownHelpSha256; получен $($source.sha256)"
}

$result = [ordered]@{
    schema = "pub-morph-target-discovery/v1"
    captured_at = [DateTimeOffset]::Now.ToString("o")
    source = $source
    publisher = $null
    document_wizard = $null
    web_navigation_bar_sets = $null
    shapes = @()
    selection_contract = [ordered]@{
        automatic_selection = $false
        stable_identity = "WizardTag + WizardTagInstance"
        rule = "Discovery is read-only. A target descriptor must be selected and pinned before any mutation. A candidate is not called ObjectTracking-backed solely because it is wizard-created."
    }
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

    $document = $application.Open($source.path, $true, $false)

    try {
        $wizard = $document.Wizard
        $result.document_wizard = [ordered]@{
            state = "value"
            id = Get-PubSafeValue { [int]$wizard.ID } "Document.Wizard.ID"
            name = Get-PubSafeValue { [string]$wizard.Name } "Document.Wizard.Name"
        }
    }
    catch {
        $result.document_wizard = [ordered]@{
            state = "error"
            hresult = if ($_.Exception.HResult) { Format-PubHResult ([int]$_.Exception.HResult) } else { $null }
            message = $_.Exception.Message
        }
    }

    $result.web_navigation_bar_sets = Get-WebNavigationBarSetsSnapshot -Document $document

    $records = New-Object System.Collections.ArrayList
    for ($pageIndex = 1; $pageIndex -le [int]$document.Pages.Count; $pageIndex++) {
        $page = $document.Pages.Item($pageIndex)
        for ($shapeIndex = 1; $shapeIndex -le [int]$page.Shapes.Count; $shapeIndex++) {
            $shape = $page.Shapes.Item($shapeIndex)
            Add-ShapeRecursive -Shape $shape -PageIndex $pageIndex -TraversalPath "page[$pageIndex]/shape[$shapeIndex]" -Records $records
        }
    }

    $result.shapes = @($records)
}
finally {
    if ($null -ne $document) {
        try { $document.Close() } catch {}
        try { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($document) } catch {}
    }
    Close-PubPublisherApplication $application
}

Write-PubJson -Value $result -Path $OutputPath
Write-Host "MORPH target discovery: $OutputPath"
