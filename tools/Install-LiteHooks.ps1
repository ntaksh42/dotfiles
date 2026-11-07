# claude/hooks/lite-hook.mjs と toast-send.ps1 を ~/.claude/hooks/ へ置き、~/.claude/settings.json の hooks に登録する。
# toast 通知とセッション名を settings hook で行う（Mod が動くセッションでは lite-hook.mjs が何もしない）。
# 他ツールが書いた hooks は残し、lite-hook.mjs を指す hook だけ入れ替える。
# 使い方: pwsh -NoProfile -File tools/Install-LiteHooks.ps1 [-ClaudeDir <path>]
param(
    [string]$ClaudeDir = (Join-Path $env:USERPROFILE '.claude')
)

$ErrorActionPreference = 'Stop'

$rawBase = 'https://raw.githubusercontent.com/ntaksh42/dotfiles/main'
$files = @(
    @{ Source = '..\claude\hooks\lite-hook.mjs'; Remote = 'claude/hooks/lite-hook.mjs'; Name = 'lite-hook.mjs' }
    @{ Source = '..\claude\mods\dotfiles\scripts\toast-send.ps1'; Remote = 'claude/mods/dotfiles/scripts/toast-send.ps1'; Name = 'toast-send.ps1' }
)
$hooksDir = Join-Path $ClaudeDir 'hooks'
$settingsFile = Join-Path $ClaudeDir 'settings.json'

if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw 'node が見つからない（hook の実行に必要）' }

New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null
foreach ($f in $files) {
    $source = Join-Path $PSScriptRoot $f.Source
    $target = Join-Path $hooksDir $f.Name
    if (Test-Path -LiteralPath $source) {
        Copy-Item -LiteralPath $source -Destination $target -Force
    } else {
        # Install-DevTools は GitHub から本スクリプトだけを一時フォルダへ取得して実行するため、手元に hook が無い
        $content = (Invoke-WebRequest -Uri "$rawBase/$($f.Remote)" -UseBasicParsing).Content
        [System.IO.File]::WriteAllText($target, $content, (New-Object System.Text.UTF8Encoding $false))
    }
    Write-Host "配置: $target"
}

$script = (Join-Path $hooksDir 'lite-hook.mjs') -replace '\\', '/'
# イベント名 → mode と matcher。plugin の hooks.json にあった登録をそのまま移した
$events = [ordered]@{
    UserPromptSubmit   = @{ Mode = 'prompt' }
    Stop               = @{ Mode = 'stop' }
    StopFailure        = @{ Mode = 'stop-failure' }
    Notification       = @{ Mode = 'notification' }
    PostToolUse        = @{ Mode = 'post-tool'; Matcher = 'Bash|PowerShell' }
    PostToolUseFailure = @{ Mode = 'post-tool-failure'; Matcher = 'Bash|PowerShell' }
}

$settings = if (Test-Path -LiteralPath $settingsFile) {
    Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
    [pscustomobject]@{}
}
if (-not $settings.PSObject.Properties['hooks']) {
    $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
}

foreach ($name in $events.Keys) {
    $spec = $events[$name]
    $existing = if ($settings.hooks.PSObject.Properties[$name]) { @($settings.hooks.$name) } else { @() }
    # lite-hook.mjs を指す hook を除き（空になったエントリごと）、他の hook は残す
    $kept = @(foreach ($entry in $existing) {
        $others = @($entry.hooks | Where-Object { $_.command -notlike '*lite-hook.mjs*' })
        if ($others.Count -eq 0) { continue }
        $entry.hooks = $others
        $entry
    })
    $entry = [ordered]@{}
    if ($spec.Matcher) { $entry.matcher = $spec.Matcher }
    $entry.hooks = @([pscustomobject]@{ type = 'command'; command = ('node "{0}" {1}' -f $script, $spec.Mode) })
    $value = @($kept) + [pscustomobject]$entry
    if ($settings.hooks.PSObject.Properties[$name]) { $settings.hooks.$name = $value }
    else { $settings.hooks | Add-Member -NotePropertyName $name -NotePropertyValue $value }
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
Write-Host 'Claude Code を再起動すると反映される。'
