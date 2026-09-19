param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePub,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = (Join-Path $PSScriptRoot "morph-scenario-options.json")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$runtimeRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $runtimeRoot "PubRuntime.psm1") -Force

function Get-WizardValuesSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        $Property
    )

    try {
        $values = $Property.Values
        $count = [int]$values.Count
        $items = @()

        for ($i = 1; $i -le $count; $i++) {
            try {
                $value = $values.Item($i)
                $items += [ordered]@{
                    collection_index = $i
                    id = Get-PubSafeValue { [int]$value.ID } "WizardValue.ID"
                    name = Get-PubSafeValue { [string]$value.Name } "WizardValue.Name"
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
$application = $null
$document = $null

$result = [ordered]@{
    schema = "pub-morph-scenario-01/options/v1"
    captured_at = [DateTimeOffset]::Now.ToString("o")
    source = $source
    publisher = $null
    wizard = $null
    selection_rule = "Этот probe только перечисляет runtime values. Target wizard/design выбирается отдельно и фиксируется до mutation run."
}

try {
    $application = New-PubPublisherApplication
    $result.publisher = [ordered]@{
        version = Get-PubSafeValue { [string]$application.Version } "Application.Version"
        build = Get-PubSafeValue { [string]$application.Build } "Application.Build"
        path = Get-PubSafeValue { [string]$application.Path } "Application.Path"
    }

    $document = $application.Open($source.path, $true, $false)
    $wizard = $document.Wizard

    $properties = @()
    $count = [int]$wizard.Properties.Count

    for ($i = 1; $i -le $count; $i++) {
        try {
            $property = $wizard.Properties.Item($i)
            $properties += [ordered]@{
                collection_index = $i
                id = Get-PubSafeValue { [int]$property.ID } "WizardProperty.ID"
                name = Get-PubSafeValue { [string]$property.Name } "WizardProperty.Name"
                current_value_id = Get-PubSafeValue { [int]$property.CurrentValueId } "WizardProperty.CurrentValueId"
                enabled = Get-PubSafeValue { [bool]$property.Enabled } "WizardProperty.Enabled"
                values = Get-WizardValuesSnapshot -Property $property
            }
        }
        catch {
            $properties += [ordered]@{
                collection_index = $i
                state = "enumeration_error"
                hresult = if ($_.Exception.HResult) { Format-PubHResult ([int]$_.Exception.HResult) } else { $null }
                message = $_.Exception.Message
            }
        }
    }

    $result.wizard = [ordered]@{
        id = Get-PubSafeValue { [int]$wizard.ID } "Wizard.ID"
        name = Get-PubSafeValue { [string]$wizard.Name } "Wizard.Name"
        properties_count = $count
        properties = $properties
    }
}
finally {
    if ($null -ne $document) {
        try { $document.Close() } catch {}
        try { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($document) } catch {}
    }
    Close-PubPublisherApplication $application
}

Write-PubJson -Value $result -Path $OutputPath
Write-Host "Wizard options: $OutputPath"
