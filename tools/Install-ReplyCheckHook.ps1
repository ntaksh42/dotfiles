# claude/hooks/reply-check.mjs を ~/.claude/hooks/ へ置き、~/.claude/settings.json の Stop・UserPromptSubmit・PostToolUse の hook に登録する。
# 既存の hooks は残し、reply-check.mjs の登録を exec form に揃える。
# 使い方: pwsh -NoProfile -File tools/Install-ReplyCheckHook.ps1 [-ClaudeDir <path>]
param(
    [string]$ClaudeDir = (Join-Path $env:USERPROFILE '.claude')
)

$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot '..\claude\hooks\reply-check.mjs'
$remote = 'https://raw.githubusercontent.com/ntaksh42/dotfiles/main/claude/hooks/reply-check.mjs'
$hooksDir = Join-Path $ClaudeDir 'hooks'
$target = Join-Path $hooksDir 'reply-check.mjs'
$settingsFile = Join-Path $ClaudeDir 'settings.json'

if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw 'node が見つからない（hook の実行に必要）' }

New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null
if (Test-Path -LiteralPath $source) {
    Copy-Item -LiteralPath $source -Destination $target -Force
} else {
    # Install-DevTools は GitHub から本スクリプトだけを一時フォルダへ取得して実行するため、手元に hook が無い
    $content = (Invoke-WebRequest -Uri $remote -UseBasicParsing).Content
    [System.IO.File]::WriteAllText($target, $content, (New-Object System.Text.UTF8Encoding $false))
}
Write-Host "配置: $target"

$hookPath = $target -replace '\\', '/'
$hook = [pscustomobject]@{ type = 'command'; command = 'node'; args = @($hookPath); timeout = 10; onFailure = 'continue' }

$settings = if (Test-Path -LiteralPath $settingsFile) {
    Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
    [pscustomobject]@{}
}

if (-not $settings.PSObject.Properties['hooks']) {
    $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
}
# Stop で長い返信を止め、UserPromptSubmit で毎ターン基準を差し込み、PostToolUse でコミット・push・PR 作成の直後にも差し込む
# （同じスクリプトが hook_event_name で分岐する）。値は matcher（$null なら付けない）
$events = [ordered]@{
    Stop             = $null
    UserPromptSubmit = $null
    PostToolUse      = 'Bash|PowerShell|mcp__.*__(create|update)_pull_request'
}
foreach ($event in $events.Keys) {
    $matcher = $events[$event]
    if (-not $settings.hooks.PSObject.Properties[$event]) {
        $settings.hooks | Add-Member -NotePropertyName $event -NotePropertyValue @()
    }
    $kept = @(foreach ($entry in $settings.hooks.$event) {
        $others = @($entry.hooks | Where-Object {
            $shellForm = $_.command -match '^node\s+"(?:[^"]*[\\/])?reply-check\.mjs"(?:\s|$)'
            $execForm = $_.command -eq 'node' -and @($_.args)[0] -match '(?:^|[\\/])reply-check\.mjs$'
            -not ($_.type -eq 'command' -and ($shellForm -or $execForm))
        })
        if ($others.Count -eq 0 -and $entry.hooks.Count -gt 0) { continue }
        $entry.hooks = $others
        $entry
    })
    $entry = [pscustomobject]@{ hooks = @($hook) }
    if ($matcher) { $entry | Add-Member -NotePropertyName matcher -NotePropertyValue $matcher }
    $settings.hooks.$event = $kept + $entry
}

if (Test-Path -LiteralPath $settingsFile) {
    $backup = "$settingsFile.backup.$(Get-Date -Format 'yyyyMMdd-HHmmss.fffffff')"
    Copy-Item -LiteralPath $settingsFile -Destination $backup
    Write-Host "バックアップ: $backup"
}

$json = $settings | ConvertTo-Json -Depth 32
$null = $json | ConvertFrom-Json
[System.IO.File]::WriteAllText($settingsFile, $json, (New-Object System.Text.UTF8Encoding $false))
Write-Host "更新: $settingsFile"
Write-Host 'Claude Code を再起動すると反映される。無効にするときは環境変数 REPLY_CHECK=off。'
