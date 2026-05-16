<#
.HOOK
{
  "event": "Stop",
  "async": true
}
#>
# session-end-summary.ps1
# Claudeの応答ターン終了時にセッション活動をJSONLで記録するhook
# Output: $env:USERPROFILE\claude-sessions\activity.jsonl

param()

$raw = $input | Out-String
try {
    $data = $raw | ConvertFrom-Json
} catch {
    exit 0
}

$outputDir = Join-Path $env:USERPROFILE "claude-sessions"
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$sessionId = $data.session_id
$cwd       = $data.cwd

$gitBranch = ""
try {
    if ($cwd -and (Test-Path $cwd)) {
        Push-Location $cwd
        $gitBranch = & git rev-parse --abbrev-ref HEAD 2>$null
        Pop-Location
    }
} catch {}

# transcript から最後のアシスタントメッセージを1件取得
$lastAssistantText = ""
$transcriptPath = $data.transcript_path
if ($transcriptPath -and (Test-Path $transcriptPath)) {
    try {
        $lines = Get-Content $transcriptPath -Encoding UTF8
        foreach ($line in ($lines | Select-Object -Last 50)) {
            if (-not $line.Trim()) { continue }
            try {
                $entry = $line | ConvertFrom-Json
                if ($entry.type -eq "assistant" -and $entry.message) {
                    $content = $entry.message.content
                    $text = ""
                    if ($content -is [System.Array]) {
                        $text = ($content | Where-Object { $_.type -eq "text" } | ForEach-Object { $_.text }) -join ""
                    } elseif ($content -is [string]) {
                        $text = $content
                    }
                    if ($text.Trim()) { $lastAssistantText = $text }
                }
            } catch {}
        }
        if ($lastAssistantText.Length -gt 300) {
            $lastAssistantText = $lastAssistantText.Substring(0, 300) + "..."
        }
    } catch {}
}

$record = [PSCustomObject]@{
    time         = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    session_id   = $sessionId
    cwd          = $cwd
    git_branch   = $gitBranch
    last_message = $lastAssistantText
} | ConvertTo-Json -Compress

$logFile = Join-Path $outputDir "activity.jsonl"
$record | Add-Content -Path $logFile -Encoding UTF8

exit 0
