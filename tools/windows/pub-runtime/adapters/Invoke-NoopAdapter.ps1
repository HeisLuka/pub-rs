param(
    [Parameter(Mandatory = $true)]
    [string]$RunContextPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$context = Get-Content -LiteralPath $RunContextPath -Raw | ConvertFrom-Json

$result = [ordered]@{
    schema = "pub-runtime/noop-adapter/v1"
    experiment_id = [string]$context.experiment_id
    case_id = [string]$context.case_id
    source_pub = [string]$context.source_pub
    note = "No-op adapter проверяет только envelope/provenance layout и не создаёт native Publisher evidence."
    captured_at = [DateTimeOffset]::Now.ToString("o")
}

$resultPath = Join-Path ([string]$context.logs_dir) "noop-result.json"
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath -Encoding utf8
