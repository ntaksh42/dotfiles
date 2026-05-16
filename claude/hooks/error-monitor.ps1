<#
.HOOK
{
  "event": "PostToolUseFailure",
  "async": true
}
#>
# error-monitor.ps1
# ツール失敗をJSONLログに記録するhook（PostToolUseFailure）
# Output: $env:USERPROFILE\claude-errors.jsonl

param()

$raw = $input | Out-String
try {
    $data = $raw | ConvertFrom-Json
} catch {
    exit 0
}

$logFile = Join-Path $env:USERPROFILE "claude-errors.jsonl"

$toolInput = ""
try {
    $toolInput = $data.tool_input | ConvertTo-Json -Compress -Depth 3
    if ($toolInput.Length -gt 500) { $toolInput = $toolInput.Substring(0, 500) + "...(truncated)" }
} catch {}

$errorMsg = ""
try {
    $errorMsg = if ($data.error) { $data.error } elseif ($data.tool_response) { $data.tool_response | ConvertTo-Json -Compress } else { "(unknown)" }
    if ($errorMsg.Length -gt 500) { $errorMsg = $errorMsg.Substring(0, 500) + "...(truncated)" }
} catch {}

$entry = [PSCustomObject]@{
    time       = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    session_id = $data.session_id
    tool       = $data.tool_name
    input      = $toolInput
    error      = $errorMsg
    cwd        = $data.cwd
} | ConvertTo-Json -Compress

$entry | Add-Content -Path $logFile -Encoding UTF8

exit 0
