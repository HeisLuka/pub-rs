param(
    [Parameter(Mandatory = $false)]
    [string]$OutputRoot = (Join-Path $PSScriptRoot "out"),

    [Parameter(Mandatory = $false)]
    [string[]]$Cases = @(
        "page-number-field",
        "page-number-literal",
        "page-number-unlinked",
        "date-field",
        "date-literal",
        "date-unlinked",
        "hyperlink-plain",
        "hyperlink-url",
        "hyperlink-email",
        "hyperlink-file",
        "hyperlink-pageid"
    ),

    [Parameter(Mandatory = $false)]
    [string[]]$SaveFormats = @("current", "publisher2000", "publisher98"),

    [switch]$Visible
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Числовые значения взяты из Microsoft Publisher Object Model.
# Они являются публичными COM enum-значениями, а НЕ on-disk TOKN/wire enum.
$PbFilePublication = 1
$PbFilePublisher98 = 2
$PbFilePublisher2000 = 3
$PbTextOrientationHorizontal = 1
$PbHlinkTargetTypeURL = 1
$PbHlinkTargetTypeEmail = 2
$PbHlinkTargetTypePageID = 7
$PbDateLong = 2

$SaveFormatMap = @{
    current = $PbFilePublication
    publisher98 = $PbFilePublisher98
    publisher2000 = $PbFilePublisher2000
}

function Get-SafeValue {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Getter,
        [Parameter(Mandatory = $true)]
        [string]$Member
    )

    try {
        return [ordered]@{
            state = "value"
            member = $Member
            value = & $Getter
        }
    }
    catch {
        $hresult = $null
        if ($_.Exception.HResult) {
            $hresult = ('0x{0:X8}' -f ([uint32]$_.Exception.HResult))
        }

        return [ordered]@{
            state = "error"
            member = $Member
            hresult = $hresult
            message = $_.Exception.Message
        }
    }
}

function Get-PublisherIdentity {
    param(
        [Parameter(Mandatory = $true)]
        $Application
    )

    return [ordered]@{
        version = Get-SafeValue { [string]$Application.Version } "Application.Version"
        build = Get-SafeValue { [string]$Application.Build } "Application.Build"
        name = Get-SafeValue { [string]$Application.Name } "Application.Name"
    }
}

function Get-OracleTag {
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

function Get-TextSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        $Shape
    )

    $frame = $Shape.TextFrame
    $range = $frame.TextRange

    $fields = @()
    try {
        for ($i = 1; $i -le [int]$range.Fields.Count; $i++) {
            $field = $range.Fields.Item($i)
            $fields += [ordered]@{
                index = $i
                type = Get-SafeValue { [int]$field.Type } "Field.Type"
                code = Get-SafeValue { [string]$field.Code } "Field.Code"
                result = Get-SafeValue { [string]$field.Result } "Field.Result"
                text = Get-SafeValue { [string]$field.TextRange.Text } "Field.TextRange.Text"
            }
        }
    }
    catch {
        $fields += [ordered]@{
            index = $null
            enumeration_error = $_.Exception.Message
        }
    }

    $hyperlinks = @()
    try {
        for ($i = 1; $i -le [int]$range.Hyperlinks.Count; $i++) {
            $hyperlink = $range.Hyperlinks.Item($i)
            $hyperlinks += [ordered]@{
                index = $i
                type = Get-SafeValue { [int]$hyperlink.Type } "Hyperlink.Type"
                target_type = Get-SafeValue { [int]$hyperlink.TargetType } "Hyperlink.TargetType"
                address = Get-SafeValue { [string]$hyperlink.Address } "Hyperlink.Address"
                page_id = Get-SafeValue { [int]$hyperlink.PageID } "Hyperlink.PageID"
                text_to_display = Get-SafeValue { [string]$hyperlink.TextToDisplay } "Hyperlink.TextToDisplay"
                email_subject = Get-SafeValue { [string]$hyperlink.EmailSubject } "Hyperlink.EmailSubject"
            }
        }
    }
    catch {
        $hyperlinks += [ordered]@{
            index = $null
            enumeration_error = $_.Exception.Message
        }
    }

    return [ordered]@{
        text = Get-SafeValue { [string]$range.Text } "TextRange.Text"
        fields = $fields
        hyperlinks = $hyperlinks
    }
}

function Get-DocumentSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        $Application,
        [Parameter(Mandatory = $true)]
        $Document,
        [Parameter(Mandatory = $true)]
        [string]$Phase,
        [Parameter(Mandatory = $true)]
        [string]$CaseId,
        [Parameter(Mandatory = $true)]
        [string]$SaveFormatName
    )

    $pages = @()
    for ($pageIndex = 1; $pageIndex -le [int]$Document.Pages.Count; $pageIndex++) {
        $page = $Document.Pages.Item($pageIndex)
        $shapes = @()

        for ($shapeIndex = 1; $shapeIndex -le [int]$page.Shapes.Count; $shapeIndex++) {
            $shape = $page.Shapes.Item($shapeIndex)
            $shapeSnapshot = [ordered]@{
                collection_index = $shapeIndex
                oracle_tag = Get-OracleTag $shape
                id = Get-SafeValue { [int]$shape.ID } "Shape.ID"
                name = Get-SafeValue { [string]$shape.Name } "Shape.Name"
                type = Get-SafeValue { [int]$shape.Type } "Shape.Type"
                has_text_frame = Get-SafeValue { [int]$shape.HasTextFrame } "Shape.HasTextFrame"
            }

            try {
                if ([int]$shape.HasTextFrame -ne 0) {
                    $shapeSnapshot.text = Get-TextSnapshot $shape
                }
            }
            catch {
                $shapeSnapshot.text = [ordered]@{
                    error = $_.Exception.Message
                }
            }

            $shapes += $shapeSnapshot
        }

        $pages += [ordered]@{
            collection_index = $pageIndex
            page_id = Get-SafeValue { [int]$page.PageID } "Page.PageID"
            page_number = Get-SafeValue { [string]$page.PageNumber } "Page.PageNumber"
            shapes = $shapes
        }
    }

    return [ordered]@{
        schema = "pub-com-oracle/tokn-runtime-01/v1"
        phase = $Phase
        case_id = $CaseId
        save_format = $SaveFormatName
        publisher = Get-PublisherIdentity $Application
        document = [ordered]@{
            save_format = Get-SafeValue { [int]$Document.SaveFormat } "Document.SaveFormat"
            pages = $pages
        }
    }
}

function Add-OracleTextbox {
    param(
        [Parameter(Mandatory = $true)]
        $Page,
        [Parameter(Mandatory = $true)]
        [string]$CaseId
    )

    $shape = $Page.Shapes.AddTextbox(
        $PbTextOrientationHorizontal,
        72,
        72,
        360,
        72
    )
    $shape.Tags.Add("PUB_ORACLE_ID", "TOKN_RUNTIME_01::$CaseId") | Out-Null
    return $shape
}

function Initialize-Case {
    param(
        [Parameter(Mandatory = $true)]
        $Document,
        [Parameter(Mandatory = $true)]
        [string]$CaseId
    )

    $page1 = $Document.Pages.Item(1)

    if ([int]$Document.Pages.Count -lt 2) {
        $Document.Pages.Add(1, 1) | Out-Null
    }
    $page2 = $Document.Pages.Item(2)

    $shape = Add-OracleTextbox $page1 $CaseId
    $range = $shape.TextFrame.TextRange

    switch ($CaseId) {
        "page-number-field" {
            $range.InsertPageNumber() | Out-Null
        }
        "page-number-literal" {
            $range.Text = [string]$page1.PageNumber
        }
        "page-number-unlinked" {
            $range.InsertPageNumber() | Out-Null
            $field = $shape.TextFrame.TextRange.Fields.Item(1)
            $field.Unlink()
        }
        "date-field" {
            $range.InsertDateTime($PbDateLong, $true) | Out-Null
        }
        "date-literal" {
            $range.InsertDateTime($PbDateLong, $false) | Out-Null
        }
        "date-unlinked" {
            $range.InsertDateTime($PbDateLong, $true) | Out-Null
            $field = $shape.TextFrame.TextRange.Fields.Item(1)
            $field.Unlink()
        }
        "hyperlink-plain" {
            $range.Text = "PUB-TOKN-LINK"
        }
        "hyperlink-url" {
            $range.Text = "PUB-TOKN-LINK"
            $range.Hyperlinks.Add(
                $range,
                "https://example.com/pub-tokn-runtime-01",
                $PbHlinkTargetTypeURL,
                0,
                "PUB-TOKN-LINK"
            ) | Out-Null
        }
        "hyperlink-email" {
            $range.Text = "PUB-TOKN-LINK"
            $range.Hyperlinks.Add(
                $range,
                "mailto:tokn-runtime-01@example.invalid?subject=TOKN",
                $PbHlinkTargetTypeEmail,
                0,
                "PUB-TOKN-LINK"
            ) | Out-Null
        }
        "hyperlink-file" {
            $range.Text = "PUB-TOKN-LINK"
            $range.Hyperlinks.Add(
                $range,
                "C:\\TOKN-RUNTIME-01\\fixture.txt",
                $PbHlinkTargetTypeURL,
                0,
                "PUB-TOKN-LINK"
            ) | Out-Null
        }
        "hyperlink-pageid" {
            $range.Text = "PUB-TOKN-LINK"
            $range.Hyperlinks.Add(
                $range,
                "",
                $PbHlinkTargetTypePageID,
                [int]$page2.PageID,
                "PUB-TOKN-LINK"
            ) | Out-Null
        }
        default {
            throw "Неизвестный case: $CaseId"
        }
    }

    return [ordered]@{
        page1_id = [int]$page1.PageID
        page2_id = [int]$page2.PageID
        shape_id = [int]$shape.ID
        oracle_tag = "TOKN_RUNTIME_01::$CaseId"
    }
}

function New-PublisherApplication {
    $application = New-Object -ComObject Publisher.Application

    if ($Visible) {
        try {
            $application.ActiveWindow.Visible = $true
        }
        catch {
            # До создания документа ActiveWindow может быть недоступен.
        }
    }

    return $application
}

function Close-PublisherApplication {
    param(
        [Parameter(Mandatory = $false)]
        $Application
    )

    if ($null -eq $Application) {
        return
    }

    try {
        $Application.Quit()
    }
    catch {
        Write-Warning "Publisher.Quit завершился ошибкой: $($_.Exception.Message)"
    }

    try {
        [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($Application)
    }
    catch {
        # Освобождение COM RCW — best effort; ошибка не должна маскировать результат опыта.
    }

    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}

function Invoke-OneCase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CaseId,
        [Parameter(Mandatory = $true)]
        [string]$SaveFormatName,
        [Parameter(Mandatory = $true)]
        [string]$CaseOutputRoot
    )

    if (-not $SaveFormatMap.ContainsKey($SaveFormatName)) {
        throw "Неизвестный save format: $SaveFormatName"
    }

    $caseDir = Join-Path $CaseOutputRoot "$CaseId--$SaveFormatName"
    New-Item -ItemType Directory -Force -Path $caseDir | Out-Null

    $pubPath = Join-Path $caseDir "$CaseId--$SaveFormatName.pub"
    $prePath = Join-Path $caseDir "pre-save.json"
    $reopenPath = Join-Path $caseDir "reopen.json"

    $application = $null
    try {
        $application = New-PublisherApplication
        $document = $application.Documents.Add()
        $seed = Initialize-Case $document $CaseId

        if ($Visible) {
            try {
                $application.ActiveWindow.Visible = $true
            }
            catch {
                Write-Warning "Не удалось показать окно Publisher: $($_.Exception.Message)"
            }
        }

        $pre = Get-DocumentSnapshot $application $document "pre-save" $CaseId $SaveFormatName
        $pre.seed = $seed
        $pre | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $prePath -Encoding utf8

        $document.SaveAs($pubPath, [int]$SaveFormatMap[$SaveFormatName], $false)
    }
    finally {
        Close-PublisherApplication $application
    }

    $application = $null
    try {
        $application = New-PublisherApplication
        $document = $application.Open($pubPath, $true, $false)
        $reopen = Get-DocumentSnapshot $application $document "reopen" $CaseId $SaveFormatName
        $reopen | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $reopenPath -Encoding utf8
    }
    finally {
        Close-PublisherApplication $application
    }

    $file = Get-Item -LiteralPath $pubPath
    $hash = Get-FileHash -LiteralPath $pubPath -Algorithm SHA256

    return [ordered]@{
        case_id = $CaseId
        save_format = $SaveFormatName
        pub_path = $file.FullName
        size = $file.Length
        sha256 = $hash.Hash.ToLowerInvariant()
        pre_save_snapshot = (Get-Item -LiteralPath $prePath).FullName
        reopen_snapshot = (Get-Item -LiteralPath $reopenPath).FullName
        status = "ok"
    }
}

$resolvedOutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
New-Item -ItemType Directory -Force -Path $resolvedOutputRoot | Out-Null

$runStarted = [DateTimeOffset]::Now
$probeApplication = $null
try {
    $probeApplication = New-PublisherApplication
    $publisherIdentity = Get-PublisherIdentity $probeApplication
}
catch {
    throw "Microsoft Publisher COM automation недоступна. Нужен Windows с установленным desktop Microsoft Publisher. Причина: $($_.Exception.Message)"
}
finally {
    Close-PublisherApplication $probeApplication
}

$results = @()
foreach ($caseId in $Cases) {
    foreach ($saveFormat in $SaveFormats) {
        Write-Host "TOKN-RUNTIME-01: $caseId / $saveFormat"
        try {
            $results += Invoke-OneCase $caseId $saveFormat $resolvedOutputRoot
        }
        catch {
            $results += [ordered]@{
                case_id = $caseId
                save_format = $saveFormat
                status = "error"
                message = $_.Exception.Message
                hresult = if ($_.Exception.HResult) {
                    ('0x{0:X8}' -f ([uint32]$_.Exception.HResult))
                }
                else {
                    $null
                }
            }
            Write-Warning "$caseId / $saveFormat: $($_.Exception.Message)"
        }
    }
}

$manifest = [ordered]@{
    schema = "pub-tokn-runtime-01/manifest/v1"
    started_at = $runStarted.ToString("o")
    finished_at = [DateTimeOffset]::Now.ToString("o")
    publisher = $publisherIdentity
    environment = [ordered]@{
        os = [System.Environment]::OSVersion.VersionString
        machine = [System.Environment]::MachineName
        powershell = $PSVersionTable.PSVersion.ToString()
    }
    constants = [ordered]@{
        pbFilePublication = $PbFilePublication
        pbFilePublisher98 = $PbFilePublisher98
        pbFilePublisher2000 = $PbFilePublisher2000
        pbTextOrientationHorizontal = $PbTextOrientationHorizontal
        pbHlinkTargetTypeURL = $PbHlinkTargetTypeURL
        pbHlinkTargetTypeEmail = $PbHlinkTargetTypeEmail
        pbHlinkTargetTypePageID = $PbHlinkTargetTypePageID
        pbDateLong = $PbDateLong
    }
    guardrails = @(
        "PbFieldType и PbHlinkTargetType — публичные COM enum; числовое равенство с TOKN wire kinds не предполагается.",
        "Результат опыта относится к зафиксированной Publisher Version/Build и выбранному SaveAs writer family.",
        "pre-save COM snapshot и reopen snapshot — semantic oracle, а не прямое описание raw PUB bytes.",
        "Native claim повышается только после отдельного бинарного разбора сохранённых PUB."
    )
    cases = $results
}

$manifestPath = Join-Path $resolvedOutputRoot "manifest.json"
$manifest | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $manifestPath -Encoding utf8

$okCount = @($results | Where-Object { $_.status -eq "ok" }).Count
$errorCount = @($results | Where-Object { $_.status -ne "ok" }).Count

Write-Host ""
Write-Host "TOKN-RUNTIME-01 завершён."
Write-Host "Успешных вариантов: $okCount"
Write-Host "Ошибок: $errorCount"
Write-Host "Manifest: $manifestPath"

if ($errorCount -gt 0) {
    exit 2
}
