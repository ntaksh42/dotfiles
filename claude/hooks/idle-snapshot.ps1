<#
.HOOK
{
  "event": "Notification",
  "matcher": "idle_prompt"
}
#>
# idle-snapshot.ps1
# Claude Code idle_prompt hook: saves session snapshot as HTML
# Output dir: $env:CLAUDE_IDLE_OUTPUT_DIR (fallback: ~/claude-idle-snapshots)

param()

$raw = $input | Out-String
try {
    $data = $raw | ConvertFrom-Json
} catch {
    Write-Error "Failed to parse hook input: $_"
    exit 1
}

$outputDir = if ($env:CLAUDE_IDLE_OUTPUT_DIR) {
    $env:CLAUDE_IDLE_OUTPUT_DIR
} else {
    Join-Path $HOME "claude-idle-snapshots"
}
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$sessionId = $data.session_id
$cwd       = $data.cwd
$now       = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$pcName    = [System.Environment]::MachineName

$gitBranch = ""
$gitStatus = ""
try {
    Push-Location $cwd
    $gitBranch = & git rev-parse --abbrev-ref HEAD 2>$null
    $gitStatus = (& git status --short 2>$null) -join "`n"
    Pop-Location
} catch {}

$recentMessages = @()
$transcriptPath = $data.transcript_path
if ($transcriptPath -and (Test-Path $transcriptPath)) {
    try {
        $lines = Get-Content $transcriptPath -Encoding UTF8
        $msgs  = @()
        foreach ($line in $lines) {
            if (-not $line.Trim()) { continue }
            try {
                $entry = $line | ConvertFrom-Json
                if ($entry.type -in @("user", "assistant") -and $entry.message) {
                    $role    = $entry.message.role
                    $content = $entry.message.content
                    $text    = ""
                    if ($content -is [System.Array]) {
                        $textBlocks = $content | Where-Object { $_.type -eq "text" }
                        $text = ($textBlocks | ForEach-Object { $_.text }) -join ""
                    } elseif ($content -is [string]) {
                        $text = $content
                    }
                    if ($text.Trim()) {
                        $msgs += [PSCustomObject]@{ role = $role; text = $text }
                    }
                }
            } catch {}
        }
        $recentMessages = $msgs | Select-Object -Last 3
    } catch {}
}

# HTML escape helper
function Escape-Html($str) {
    $str -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;'
}

# Build message blocks HTML
$msgHtml = ""
if ($recentMessages.Count -eq 0) {
    $msgHtml = "<p class='empty'>(no messages)</p>"
} else {
    foreach ($msg in $recentMessages) {
        $roleClass = if ($msg.role -eq "user") { "user" } else { "assistant" }
        $roleLabel = if ($msg.role -eq "user") { "User" } else { "Claude" }
        $preview = if ($msg.text.Length -gt 500) {
            (Escape-Html $msg.text.Substring(0, 500)) + "<span class='truncated'> ... (truncated)</span>"
        } else {
            Escape-Html $msg.text
        }
        # preserve line breaks
        $preview = $preview -replace "`n", "<br>"
        $msgHtml += @"
<div class="message $roleClass">
  <div class="role-label">$roleLabel</div>
  <div class="message-body">$preview</div>
</div>
"@
    }
}

# Git status block
$gitHtml = ""
if ($gitBranch) {
    $gitStatusEscaped = if ($gitStatus) { Escape-Html $gitStatus.Trim() } else { "(clean)" }
    $gitHtml = @"
<section>
  <h2>Git Status</h2>
  <table>
    <tr><th>Branch</th><td>$(Escape-Html $gitBranch)</td></tr>
  </table>
  <pre class="git-status">$gitStatusEscaped</pre>
</section>
"@
}

$html = @"
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<title>Claude Code Idle Snapshot</title>
<style>
  body { font-family: 'Segoe UI', sans-serif; background: #f5f5f5; margin: 0; padding: 24px; color: #222; }
  h1 { font-size: 1.4rem; color: #1a1a2e; border-bottom: 2px solid #4a90d9; padding-bottom: 8px; }
  h2 { font-size: 1.05rem; color: #333; margin-top: 24px; }
  section { background: #fff; border-radius: 8px; padding: 16px 20px; margin-bottom: 16px; box-shadow: 0 1px 4px rgba(0,0,0,.08); }
  table { border-collapse: collapse; width: 100%; }
  th, td { text-align: left; padding: 6px 10px; border-bottom: 1px solid #eee; font-size: 0.9rem; }
  th { width: 140px; color: #555; font-weight: 600; }
  pre.git-status { background: #1e1e1e; color: #d4d4d4; padding: 12px; border-radius: 6px; font-size: 0.85rem; margin-top: 10px; overflow-x: auto; }
  .message { border-radius: 6px; padding: 12px 14px; margin-bottom: 10px; }
  .message.user { background: #e8f0fe; border-left: 4px solid #4a90d9; }
  .message.assistant { background: #f0faf0; border-left: 4px solid #34a853; }
  .role-label { font-size: 0.75rem; font-weight: 700; text-transform: uppercase; letter-spacing: .05em; margin-bottom: 6px; color: #555; }
  .message-body { font-size: 0.9rem; line-height: 1.6; white-space: pre-wrap; }
  .truncated { color: #999; font-style: italic; }
  .empty { color: #999; font-style: italic; }
  .timestamp { font-size: 0.8rem; color: #888; text-align: right; margin-top: 4px; }
</style>
</head>
<body>
<h1>Claude Code Idle Snapshot</h1>
<p class="timestamp">Generated: $now</p>

<section>
  <h2>Session Info</h2>
  <table>
    <tr><th>Time</th><td>$now</td></tr>
    <tr><th>PC</th><td>$(Escape-Html $pcName)</td></tr>
    <tr><th>Session ID</th><td>$(Escape-Html $sessionId)</td></tr>
    <tr><th>Working Dir</th><td>$(Escape-Html $cwd)</td></tr>
  </table>
</section>

$gitHtml

<section>
  <h2>Recent Messages (last 3)</h2>
  $msgHtml
</section>

</body>
</html>
"@

$fileName   = "idle-$sessionId.html"
$outputFile = Join-Path $outputDir $fileName
$html | Set-Content -Path $outputFile -Encoding UTF8
