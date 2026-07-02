<#
.HOOK
{
  "event": "PostToolUse",
  "matcher": "Task",
  "async": true
}
#>
# delegation-log.ps1
# サブエージェント委譲(Taskツール)をJSONLで記録し、委譲率・内訳の計測を可能にするhook
# Output: $env:USERPROFILE\claude-delegation.jsonl
# 集計例: Get-Content ~\claude-delegation.jsonl | ConvertFrom-Json | Group-Object subagent_type

param()

$raw = $input | Out-String
try {
    $data = $raw | ConvertFrom-Json
} catch {
    exit 0
}

$logFile = Join-Path $env:USERPROFILE "claude-delegation.jsonl"
$ti = $data.tool_input

[PSCustomObject]@{
    time          = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    session_id    = $data.session_id
    subagent_type = $ti.subagent_type
    model         = $ti.model
    description   = $ti.description
    prompt_chars  = if ($ti.prompt) { $ti.prompt.Length } else { 0 }
} | ConvertTo-Json -Compress | Add-Content -Path $logFile -Encoding UTF8

exit 0
