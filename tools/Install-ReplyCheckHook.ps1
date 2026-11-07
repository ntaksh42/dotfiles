# claude/hooks/reply-check.mjs を ~/.claude/hooks/ へ置き、~/.claude/settings.json の Stop hook に登録する。
# 既存の hooks（Orca など他ツールが書いたもの）は残し、同じ hook が登録済みなら何もしない。
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

$command = 'node "{0}"' -f ($target -replace '\\', '/')

$settings = if (Test-Path -LiteralPath $settingsFile) {
    Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
    [pscustomobject]@{}
}

if (-not $settings.PSObject.Properties['hooks']) {
    $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
}
if (-not $settings.hooks.PSObject.Properties['Stop']) {
    $settings.hooks | Add-Member -NotePropertyName Stop -NotePropertyValue @()
}

$registered = @($settings.hooks.Stop | ForEach-Object { $_.hooks } | Where-Object { $_.command -like '*reply-check.mjs*' })
if ($registered.Count -gt 0) {
    # 登録済みなら、コマンドだけ現在のパスに揃える
    foreach ($h in $registered) { $h.command = $command }
    Write-Host '登録済み: コマンドを更新'
} else {
    $entry = [pscustomobject]@{ hooks = @([pscustomobject]@{ type = 'command'; command = $command; timeout = 10 }) }
    $settings.hooks.Stop = @($settings.hooks.Stop) + $entry
    Write-Host '登録: Stop hook を追加'
}

if (Test-Path -LiteralPath $settingsFile) {
    $backup = "$settingsFile.backup.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $settingsFile -Destination $backup
    Write-Host "バックアップ: $backup"
}

$json = $settings | ConvertTo-Json -Depth 32
$null = $json | ConvertFrom-Json
[System.IO.File]::WriteAllText($settingsFile, $json, (New-Object System.Text.UTF8Encoding $false))
Write-Host "更新: $settingsFile"
Write-Host 'Claude Code を再起動すると反映される。無効にするときは環境変数 REPLY_CHECK=off。'
