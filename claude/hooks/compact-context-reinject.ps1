<#
.HOOK
{
  "event": "PostCompact"
}
#>
# compact-context-reinject.ps1
# コンテキスト圧縮後に指示ファイル（CLAUDE.md / AGENTS.md）の再読み込みを指示するhook（PostCompact）

$cwd = ""
try {
    $raw = $input | Out-String
    $data = $raw | ConvertFrom-Json
    $cwd = $data.cwd
} catch {}

$msg = @"
[Context Reinject] Compaction occurred. Important reminders:
- Re-read the instruction file (CLAUDE.md or AGENTS.md) in the project root before proceeding.
- Review any active tasks/plans to restore working context.
"@

if ($cwd) {
    foreach ($name in @("CLAUDE.md", "AGENTS.md")) {
        $path = Join-Path $cwd $name
        if (Test-Path $path) {
            $msg += "`n- $name found at: $path"
        }
    }
}

Write-Output $msg
exit 0
