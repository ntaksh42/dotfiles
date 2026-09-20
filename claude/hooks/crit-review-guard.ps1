<#
.HOOK
{
  "event": "PreToolUse",
  "matcher": "Bash"
}
#>
# crit-review-guard.ps1
# git commit 実行前に crit レビューが完了しているか確認し、未実施・未解決コメントありなら実行をブロックする。

param()

try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}

$raw = $input | Out-String
try {
    $data = $raw | ConvertFrom-Json
} catch {
    exit 0
}

$command = [string]$data.tool_input.command
if ($command -notmatch '\bgit\s+commit\b') {
    exit 0
}

if (-not (Get-Command crit -ErrorAction SilentlyContinue)) {
    exit 0
}

function Block($reason) {
    $obj = [PSCustomObject]@{ decision = "block"; reason = $reason }
    Write-Output ($obj | ConvertTo-Json -Compress)
    exit 0
}

try {
    $statusJson = crit status --json 2>$null | Out-String
    $status = $statusJson | ConvertFrom-Json
} catch {
    exit 0
}

if (-not $status.review_file_exists) {
    Block "コミット前に crit レビューを実施してください（crit を実行し、ユーザーの Finish Review を待つ）。"
}

try {
    $commentsJson = crit comments --json 2>$null | Out-String
    $comments = $commentsJson | ConvertFrom-Json
} catch {
    $comments = @()
}

$unresolved = @($comments | Where-Object { -not $_.resolved })
if ($unresolved.Count -gt 0) {
    Block "crit レビューに未解決のコメントが $($unresolved.Count) 件あります。対応してから再度コミットしてください（crit comments で確認）。"
}

exit 0
