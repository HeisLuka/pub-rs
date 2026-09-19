param(
    [Parameter(Mandatory = $true)]
    [string]$RunContextPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$runtimeRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $runtimeRoot "PubRuntime.psm1") -Force

$ExpectedSourceSha256 = "cabf449064f9151d279a3d8dbba777a3e18f3a8863ff60f940523ee4cd056a44"
$ExpectedDeletedPageId = 33554728
$ExpectedSourcePageId = 33554698

function Get-PageSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        $Document,
        [Parameter(Mandatory = $true)]
        [string]$Phase
    )

    $pages = @()
    for ($index = 1; $index -le [int]$Document.Pages.Count; $index++) {
        $page = $Document.Pages.Item($index)
        $pages += [ordered]@{
            index = $index
            page_id = Get-PubSafeValue { [int]$page.PageID } "Page.PageID"
            name = Get-PubSafeValue { [string]$page.Name } "Page.Name"
            page_type = Get-PubSafeValue { [int]$page.PageType } "Page.PageType"
            width = Get-PubSafeValue { [double]$page.Width } "Page.Width"
            height = Get-PubSafeValue { [double]$page.Height } "Page.Height"
        }
    }

    return [ordered]@{
        phase = $Phase
        page_count = [int]$Document.Pages.Count
        pages = $pages
    }
}

$context = Get-Content -LiteralPath $RunContextPath -Raw | ConvertFrom-Json
$sourceRecord = Get-PubFileRecord ([string]$context.source_pub)

if ($sourceRecord.sha256 -ne $ExpectedSourceSha256) {
    throw "OID-WATERMARK-01 требует exact example_multipage.pub SHA-256 $ExpectedSourceSha256, получен $($sourceRecord.sha256)"
}

$outputPath = Join-Path ([string]$context.output_dir) "oid-watermark-01.pub"
if (Test-Path -LiteralPath $outputPath) {
    throw "Working copy уже существует и не должна перезаписываться: $outputPath"
}

# Рабочую копию создаём ДО запуска Publisher. Это позволяет вызвать Document.Save()
# на файле того же формата, в котором он был открыт, не изменяя bound input.
$workingBinding = Copy-PubBoundFile -Source ([string]$context.source_pub) -Destination $outputPath

$result = [ordered]@{
    schema = "pub-oid-watermark-01/runtime/v2"
    experiment_id = [string]$context.experiment_id
    case_id = [string]$context.case_id
    source = $sourceRecord
    working_copy_initial = $workingBinding
    publisher = $null
    before = $null
    delete = [ordered]@{
        expected_page_index = 2
        expected_page_id = $ExpectedDeletedPageId
        observed_page_id = $null
        page_count_before = $null
        page_count_after = $null
        state = "not_attempted"
    }
    duplicate = [ordered]@{
        source_page_index = 1
        expected_source_page_id = $ExpectedSourcePageId
        observed_source_page_id = $null
        page_count_before = $null
        page_count_after = $null
        returned_page_id = $null
        returned_page_name = $null
        state = "not_attempted"
        hresult = $null
        message = $null
    }
    after_mutation = $null
    save = [ordered]@{
        method = "Document.Save"
        state = "not_attempted"
        path = $outputPath
        sha256 = $null
        size = $null
        hresult = $null
        message = $null
    }
    reopen = $null
    guardrails = @(
        "Adapter воспроизводит только exact Page.Delete -> Page.Duplicate -> Document.Save arm на bound fixture.",
        "Page.Duplicate вызывается без аргументов; отдельное переименование страницы запрещено как лишняя semantic mutation.",
        "Document.SaveAs не используется: скрытая конверсия в формат текущей версии Publisher изменила бы эксперимент.",
        "COM PageID/Name являются semantic oracle; Oid, PAGE seqNum и DwNextUniqueOid должны извлекаться отдельным raw-анализом.",
        "Returned COM object после Duplicate не считается persisted identity до Save/Close/reopen.",
        "Совпадение ожидаемого перехода 7 -> (2,7) -> 8 нельзя объявлять до raw-разбора output PUB."
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

    # Открываем exact working copy, а не immutable input.
    $document = $application.Open($outputPath, $false, $false)
    $result.before = Get-PageSnapshot -Document $document -Phase "before"

    if ([int]$document.Pages.Count -lt 2) {
        throw "Fixture должен содержать как минимум две страницы"
    }

    $result.delete.page_count_before = [int]$document.Pages.Count
    $deletePage = $document.Pages.Item(2)
    $deletePageId = [int]$deletePage.PageID
    $result.delete.observed_page_id = $deletePageId
    if ($deletePageId -ne $ExpectedDeletedPageId) {
        throw "Page index 2 имеет неожиданный PageID: ожидался $ExpectedDeletedPageId, получен $deletePageId"
    }

    $deletePage.Delete()
    $result.delete.page_count_after = [int]$document.Pages.Count
    if ($result.delete.page_count_after -ne ($result.delete.page_count_before - 1)) {
        throw "После Page.Delete число страниц изменилось не на -1: было $($result.delete.page_count_before), стало $($result.delete.page_count_after)"
    }
    $result.delete.state = "ok"

    $sourcePage = $document.Pages.Item(1)
    $sourcePageId = [int]$sourcePage.PageID
    $result.duplicate.observed_source_page_id = $sourcePageId
    if ($sourcePageId -ne $ExpectedSourcePageId) {
        throw "После удаления page 1 имеет неожиданный PageID: ожидался $ExpectedSourcePageId, получен $sourcePageId"
    }

    try {
        $result.duplicate.page_count_before = [int]$document.Pages.Count

        # По Publisher Object Model Page.Duplicate не принимает аргументов.
        # Имя новой страницы намеренно не меняем: это была бы отдельная semantic mutation.
        $newPage = $sourcePage.Duplicate()

        $result.duplicate.page_count_after = [int]$document.Pages.Count
        if ($result.duplicate.page_count_after -ne ($result.duplicate.page_count_before + 1)) {
            throw "После Page.Duplicate число страниц изменилось не на +1: было $($result.duplicate.page_count_before), стало $($result.duplicate.page_count_after)"
        }

        $result.duplicate.returned_page_id = Get-PubSafeValue { [int]$newPage.PageID } "Duplicate.PageID"
        $result.duplicate.returned_page_name = Get-PubSafeValue { [string]$newPage.Name } "Duplicate.Name"
        $result.duplicate.state = "ok"
    }
    catch {
        $result.duplicate.state = "error"
        if ($_.Exception.HResult) {
            $result.duplicate.hresult = Format-PubHResult ([int]$_.Exception.HResult)
        }
        $result.duplicate.message = $_.Exception.Message
        throw
    }

    $result.after_mutation = Get-PageSnapshot -Document $document -Phase "after_mutation"

    try {
        # Это намеренно Save(), а не SaveAs(..., pbFilePublication):
        # нужно сохранить в формате, в котором exact working copy была открыта.
        $document.Save()
        $saved = Get-PubFileRecord $outputPath
        $result.save.state = "ok"
        $result.save.sha256 = $saved.sha256
        $result.save.size = $saved.size
    }
    catch {
        $result.save.state = "error"
        if ($_.Exception.HResult) {
            $result.save.hresult = Format-PubHResult ([int]$_.Exception.HResult)
        }
        $result.save.message = $_.Exception.Message
        throw
    }
}
finally {
    if ($null -ne $document) {
        try { $document.Close() } catch {}
        try { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($document) } catch {}
    }
    Close-PubPublisherApplication $application
}

if ($result.save.state -eq "ok") {
    $reopenApplication = $null
    $reopenDocument = $null
    try {
        $reopenApplication = New-PubPublisherApplication
        $reopenDocument = $reopenApplication.Open([string]$result.save.path, $true, $false)
        $result.reopen = Get-PageSnapshot -Document $reopenDocument -Phase "reopen"
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
            try { $reopenDocument.Close() } catch {}
            try { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($reopenDocument) } catch {}
        }
        Close-PubPublisherApplication $reopenApplication
    }
}

Write-PubJson -Value $result -Path (Join-Path ([string]$context.oracle_dir) "oid-watermark-runtime.json")
