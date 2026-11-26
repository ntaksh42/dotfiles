param(
    [string]$CodexDir = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' })
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw 'hook の実行には node が必要です。' }

$codexRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CodexDir)
$hooksDir = Join-Path $codexRoot 'hooks'
$configPath = Join-Path $codexRoot 'hooks.json'
$runnerPath = (Join-Path $hooksDir 'codex-check.mjs') -replace '\\', '/'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$files = @('codex-check.mjs', 'reply-check.mjs', 'verify-check.mjs', 'jp-deslop-check.mjs')
$contents = [ordered]@{}
foreach ($file in $files) {
    $source = Join-Path $PSScriptRoot "../claude/hooks/$file"
    $content = if (Test-Path -LiteralPath $source) {
        [IO.File]::ReadAllText($source)
    } else {
        (Invoke-WebRequest -Uri "https://raw.githubusercontent.com/ntaksh42/dotfiles/main/claude/hooks/$file").Content
    }
    $contents[$file] = $content.Replace([string][char]13 + [char]10, [string][char]10)
}

# Codex trusts the command definition. Include the bundle hash so script updates also require review.
$digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes(($contents.Values -join [char]0))))
$original = if (Test-Path -LiteralPath $configPath) { [IO.File]::ReadAllText($configPath) }
$config = if ($null -ne $original) { ConvertFrom-Json -AsHashtable -InputObject $original } else { [ordered]@{} }
if ($config -isnot [System.Collections.IDictionary]) { throw 'hooks.json のルートはオブジェクトで指定してください。' }
if (-not $config.Contains('hooks')) { $config.hooks = [ordered]@{} }
if ($config.hooks -isnot [System.Collections.IDictionary]) { throw 'hooks はオブジェクトで指定してください。' }
$before = ConvertTo-Json -InputObject $config -Depth 100

$registrations = [ordered]@{
    Stop = @{ Checks = @('reply-check', 'verify-check') }
    PreToolUse = @{ Checks = @('jp-deslop-check'); Matcher = '^(apply_patch|Bash|Edit|Write)$' }
}
$commandPrefix = 'node "' + $runnerPath + '" '
$managedCommand = '^' + [regex]::Escape($commandPrefix) + '(?:reply-check|verify-check|jp-deslop-check)(?:\s|$)'
foreach ($event in $registrations.Keys) {
    $groups = @(foreach ($entry in $config.hooks[$event]) {
        if ($null -eq $entry) { continue }
        $others = @($entry.hooks | Where-Object { $_.type -ne 'command' -or $_.command -cnotmatch $managedCommand })
        if ($others.Count -eq 0 -and $entry.hooks.Count -gt 0) { continue }
        $entry.hooks = $others
        $entry
    })
    $group = [ordered]@{
        hooks = @(foreach ($check in $registrations[$event].Checks) {
            [ordered]@{ type = 'command'; command = "$commandPrefix$check $digest"; timeout = 10 }
        })
    }
    if ($registrations[$event].Matcher) { $group.matcher = $registrations[$event].Matcher }
    $config.hooks[$event] = $groups + $group
}

New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null
foreach ($file in $files) {
    $target = Join-Path $hooksDir $file
    if (-not (Test-Path -LiteralPath $target) -or [IO.File]::ReadAllText($target) -cne $contents[$file]) {
        [IO.File]::WriteAllText($target, $contents[$file], $utf8)
    }
}

$json = ConvertTo-Json -InputObject $config -Depth 100
if ($json -cne $before) {
    if ($null -ne $original) {
        $backup = "$configPath.backup.$(Get-Date -Format 'yyyyMMdd-HHmmss.fffffff')"
        Copy-Item -LiteralPath $configPath -Destination $backup
        Write-Host "バックアップ $backup"
    }
    [IO.File]::WriteAllText($configPath, $json, $utf8)
    Write-Host "更新 $configPath"
} else {
    Write-Host "変更なし $configPath"
}
Write-Host '初回と hook の内容が変わるたびに、Codex の /hooks で承認してください。'
