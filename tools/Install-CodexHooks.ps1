param(
    [string]$CodexDir = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }),
    [switch]$TrustDotfilesHooks
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw 'hook の実行には node が必要です。' }

$codexRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CodexDir)
$hooksDir = Join-Path $codexRoot 'hooks'
$configPath = Join-Path $codexRoot 'hooks.json'
$runnerPath = (Join-Path $hooksDir 'codex-check.mjs') -replace '\\', '/'
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Invoke-CodexAppServerRequest($Server, [int]$Id, [string]$Method, $Params) {
    $request = @{ jsonrpc = '2.0'; method = $Method }
    if ($Id) { $request.id = $Id; $request.params = $Params }
    $Server.StandardInput.WriteLine((ConvertTo-Json -InputObject $request -Depth 20 -Compress -EscapeHandling EscapeNonAscii))
    if (-not $Id) { return }

    $timeout = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(30))
    try {
        do {
            $line = $Server.StandardOutput.ReadLineAsync().WaitAsync($timeout.Token).GetAwaiter().GetResult()
            if ($null -eq $line) { throw "Codex app-server closed before answering $Method." }
            $response = ConvertFrom-Json -InputObject $line -AsHashtable
        } until ($response.id -eq $Id)
        if ($response.error) { throw "${Method}: $($response.error.message)" }
        return $response.result
    } finally {
        $timeout.Dispose()
    }
}

function Approve-DotfilesCodexHooks {
    $codexPath = (Get-Command codex -CommandType Application,ExternalScript -ErrorAction Ignore | Select-Object -First 1).Source
    if (-not $codexPath -and (Get-Command Get-AppxPackage -ErrorAction Ignore)) {
        $package = Get-AppxPackage -Name OpenAI.Codex | Select-Object -First 1
        if ($package) {
            $embedded = Join-Path $package.InstallLocation 'app/resources/codex.exe'
            if (Test-Path -LiteralPath $embedded -PathType Leaf) { $codexPath = $embedded }
        }
    }
    if (-not $codexPath) { throw 'Codex is required to approve the dotfiles hooks.' }

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path $PSHOME 'pwsh.exe'
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-Command', '& $env:DOTFILES_CODEX_EXE app-server --listen stdio://')) {
        $start.ArgumentList.Add($argument)
    }
    $start.Environment['DOTFILES_CODEX_EXE'] = $codexPath
    $start.Environment['CODEX_HOME'] = $codexRoot
    $start.WorkingDirectory = $codexRoot
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $utf8
    $server = [Diagnostics.Process]::Start($start)
    try {
        $null = $server.StandardError.ReadToEndAsync()
        $init = Invoke-CodexAppServerRequest $server 1 initialize @{
            clientInfo = @{ name = 'dotfiles'; version = '1' }
            capabilities = @{ experimentalApi = $true }
        }
        if ($init.codexHome -ne $codexRoot) { throw 'Codex app-server resolved an unexpected CODEX_HOME.' }
        Invoke-CodexAppServerRequest $server 0 initialized

        $state = Invoke-CodexAppServerRequest $server 2 'config/read' @{ includeLayers = $true }
        if ($state.config.features.hooks -eq $false) { throw 'Codex hooks are disabled in config.toml.' }
        $userLayer = $state.layers | Where-Object { $_.name.type -eq 'user' -and $_.name.file -eq (Join-Path $codexRoot 'config.toml') }
        if (-not $userLayer.version) { throw 'Codex did not return the user configuration version.' }

        $listParams = @{ cwds = @($codexRoot) }
        $discovered = Invoke-CodexAppServerRequest $server 3 'hooks/list' $listParams
        $hooks = @($discovered.data[0].hooks | Where-Object {
            if ($_.source -ne 'user' -or $_.sourcePath -ne $configPath -or $_.handlerType -ne 'command') { return $false }
            $registration = $registrations[$_.eventName]
            $_.matcher -ceq $registration.Matcher -and $_.timeoutSec -eq 10 -and -not $_.async -and
                $_.command -cin @($registration.Checks | ForEach-Object { "$commandPrefix$_ $digest" })
        })
        if ($hooks.Count -ne 3 -or @($hooks.command | Select-Object -Unique).Count -ne 3) {
            $warnings = $discovered.data[0].warnings -join ' '
            throw "Codex did not find all three expected dotfiles hooks. $warnings"
        }

        $updates = @{}
        foreach ($hook in $hooks | Where-Object { $_.enabled -and $_.trustStatus -ne 'trusted' }) {
            if ($hook.currentHash -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'Codex returned an invalid hook hash.' }
            $updates[$hook.key] = @{ trusted_hash = $hook.currentHash }
        }
        if ($updates.Count) {
            $write = Invoke-CodexAppServerRequest $server 4 'config/batchWrite' @{
                edits = @(@{ keyPath = 'hooks.state'; value = $updates; mergeStrategy = 'upsert' })
                expectedVersion = $userLayer.version
            }
            if ($write.status -ne 'ok') { throw 'Codex could not apply the hook approvals.' }
        }
        $verified = Invoke-CodexAppServerRequest $server 5 'hooks/list' $listParams
        foreach ($hook in $hooks | Where-Object enabled) {
            $actual = $verified.data[0].hooks | Where-Object { $_.key -ceq $hook.key }
            if (-not $actual.enabled -or $actual.trustStatus -ne 'trusted' -or $actual.currentHash -cne $hook.currentHash) {
                throw "Codex could not verify approval for $($hook.eventName) hook at $($hook.key)."
            }
        }
        $enabledCount = @($hooks | Where-Object enabled).Count
        Write-Host "Codex dotfiles hooks enabled: $enabledCount/$($hooks.Count)."
        if ($enabledCount -lt $hooks.Count) { Write-Warning 'Hooks disabled in Codex settings were left disabled.' }
    } finally {
        $server.StandardInput.Close()
        if (-not $server.WaitForExit(2000)) { $server.Kill($true); $server.WaitForExit() }
        $server.Dispose()
    }
}

$files = @('codex-check.mjs', 'reply-check.mjs', 'verify-check.mjs', 'japanese-check.mjs')
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
    PreToolUse = @{ Checks = @('japanese-check'); Matcher = '^(apply_patch|Bash|Edit|Write)$' }
}
$commandPrefix = 'node "' + $runnerPath + '" '
$managedCommand = '^' + [regex]::Escape($commandPrefix) + '(?:reply-check|verify-check|japanese-check|jp-deslop-check)(?:\s|$)'
foreach ($event in $registrations.Keys) {
    $group = [ordered]@{
        hooks = @(foreach ($check in $registrations[$event].Checks) {
            [ordered]@{ type = 'command'; command = "$commandPrefix$check $digest"; timeout = 10 }
        })
    }
    if ($registrations[$event].Matcher) { $group.matcher = $registrations[$event].Matcher }
    # Codex uses the group index in its persisted hook settings.
    $placed = $false
    $groups = @(foreach ($entry in $config.hooks[$event]) {
        if ($null -eq $entry) { continue }
        $others = @($entry.hooks | Where-Object { $_.type -ne 'command' -or $_.command -cnotmatch $managedCommand })
        if ($others.Count -eq 0 -and $entry.hooks.Count -gt 0) {
            if (-not $placed) { $group; $placed = $true }
            continue
        }
        $entry.hooks = $others
        $entry
    })
    $config.hooks[$event] = @(if ($placed) { $groups } else { $groups + $group })
}

New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null
foreach ($file in $files) {
    $target = Join-Path $hooksDir $file
    if (-not (Test-Path -LiteralPath $target) -or [IO.File]::ReadAllText($target) -cne $contents[$file]) {
        [IO.File]::WriteAllText($target, $contents[$file], $utf8)
    }
}

# 旧名（スキル名の変更前）の hook ファイルを取り除く。登録は $managedCommand が旧名も含めて置き換える
$legacyHook = Join-Path $hooksDir 'jp-deslop-check.mjs'
if (Test-Path -LiteralPath $legacyHook) { Remove-Item -LiteralPath $legacyHook -Force }

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
if ($TrustDotfilesHooks) { Approve-DotfilesCodexHooks }
else { Write-Host '初回と hook の内容が変わるたびに、Codex の /hooks で承認してください。' }
