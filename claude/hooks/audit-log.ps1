<#
.HOOK
{
  "event": "PostToolUse"
}
#>
# audit-log.ps1
# 全ツール呼び出しをログファイルに記録するhook
# Output: $env:USERPROFILE\claude-audit.log

param()

$raw = $input | Out-String
try {
    $data = $raw | ConvertFrom-Json
} catch {
    exit 0
}

$logDir = $env:USERPROFILE
$logFile = Join-Path $logDir "claude-audit.log"

$toolInput = ""
try {
    $toolInput = $data.tool_input | ConvertTo-Json -Compress -Depth 3
    # 長すぎるログを防止（1000文字で切る）
    if ($toolInput.Length -gt 1000) {
        $toolInput = $toolInput.Substring(0, 1000) + "...(truncated)"
    }
} catch {
    $toolInput = "(parse error)"
}

$entry = [PSCustomObject]@{
    time       = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    session_id = $data.session_id
    tool       = $data.tool_name
    input      = $toolInput
} | ConvertTo-Json -Compress

$entry | Add-Content -Path $logFile -Encoding UTF8

exit 0
