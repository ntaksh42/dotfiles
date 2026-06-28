<#
.HOOK
{
  "event": "PostToolUse",
  "matcher": "Bash",
  "async": true
}
#>
<#
.SYNOPSIS
  Bash ツールのエラーを検知し、Slack にメンション付きで通知する。

.DESCRIPTION
  PostToolUse(Bash) で stdin から JSON を受け取り、tool_response の
  exit_code / stderr からエラーを判定する。エラーなら Slack Incoming
  Webhook にメンション付きで POST する。

  必要な環境変数（未設定なら何もせず終了する）:
    SLACK_WEBHOOK_URL  Incoming Webhook の URL（秘密情報。コミットしない）
    SLACK_MENTION_ID   メンション先のメンバーID（例: U01ABCDE）。省略可
#>

$ErrorActionPreference = "Stop"

# Webhook 未設定なら何もしない（このマシンで通知を使わない場合）
$webhook = $env:SLACK_WEBHOOK_URL
if (-not $webhook) { exit 0 }

# stdin から hook コンテキスト(JSON)を読む
$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }

try {
    $ctx = $raw | ConvertFrom-Json
} catch {
    exit 0
}

$tool = $ctx.tool_input
$resp = $ctx.tool_response

# exit code と stderr を確認
$exitCode = $null
if ($resp.PSObject.Properties.Name -contains "exit_code") {
    $exitCode = $resp.exit_code
}

$stderr = ""
if ($resp.PSObject.Properties.Name -contains "stderr") {
    $stderr = $resp.stderr
}

# エラー判定: exit code が 0 以外、または stderr に error/exception 等
$isError = $false
if ($null -ne $exitCode -and $exitCode -ne 0) {
    $isError = $true
}
if ($stderr -match '(?i)\b(error|exception|fatal|panic|traceback)\b') {
    $isError = $true
}

if (-not $isError) { exit 0 }

# 通知メッセージを組み立て
$cmd = if ($tool.PSObject.Properties.Name -contains "command") { $tool.command } else { "(unknown)" }
$shortCmd = if ($cmd.Length -gt 80) { $cmd.Substring(0, 80) + "..." } else { $cmd }

$header = ":rotating_light: Claude Code エラー検知"
$mention = if ($env:SLACK_MENTION_ID) { "<@$($env:SLACK_MENTION_ID)> " } else { "" }
$detail = "``$shortCmd``"
if ($null -ne $exitCode) { $detail += " (exit $exitCode)" }

$text = "$mention$header`n$detail"

$payload = @{ text = $text } | ConvertTo-Json -Compress

# Slack へ POST。通知失敗で Claude の動作を止めないよう握りつぶす
try {
    Invoke-RestMethod -Uri $webhook -Method Post -ContentType 'application/json' -Body $payload | Out-Null
} catch {
    # 通知失敗は無視（ネットワーク不通など）
}

exit 0
