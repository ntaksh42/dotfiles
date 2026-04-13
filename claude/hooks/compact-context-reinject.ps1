<#
.HOOK
{
  "event": "SessionStart",
  "matcher": "compact"
}
#>
# compact-context-reinject.ps1
# Compact発生後にCLAUDE.mdの再読み込みを指示するhook

$cwd = ""
try {
    $raw = $input | Out-String
    $data = $raw | ConvertFrom-Json
    $cwd = $data.cwd
} catch {}

$msg = @"
[Context Reinject] Compaction occurred. Important reminders:
- Re-read CLAUDE.md in the project root before proceeding.
- Review any active tasks/plans to restore working context.
"@

if ($cwd) {
    $claudeMd = Join-Path $cwd "CLAUDE.md"
    if (Test-Path $claudeMd) {
        $msg += "`n- CLAUDE.md found at: $claudeMd"
    }
}

Write-Output $msg
exit 0
