param(
    [switch]$Check,
    [string]$ClaudeDir = $(if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { $env:USERPROFILE }),
    [string]$CodexDir = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' })
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) { throw 'Codex の TOML を編集するには uv が必要です。' }
if (-not $Check -and -not (Get-Command claude -ErrorAction SilentlyContinue)) { throw 'Claude Code への登録には claude が必要です。' }

function Read-OptionalFile([string]$Path) {
    if (Test-Path -LiteralPath $Path) { [IO.File]::ReadAllText($Path) }
}

function Write-Config([string]$Path, [string]$Content) {
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    if (Test-Path -LiteralPath $Path) {
        Copy-Item -LiteralPath $Path -Destination "$Path.backup.$(Get-Date -Format 'yyyyMMdd-HHmmss.fffffff')"
    }
    $temp = Join-Path $parent ('.dotfiles-' + [guid]::NewGuid())
    try {
        [IO.File]::WriteAllText($temp, $Content)
        [IO.File]::Move($temp, $Path, $true)
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp }
    }
}

$claudeRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ClaudeDir)
$codexRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CodexDir)
$claudeConfig = Join-Path $claudeRoot '.claude.json'
$codexConfig = Join-Path $codexRoot 'config.toml'
$claudeOriginal = Read-OptionalFile $claudeConfig
$codexOriginal = Read-OptionalFile $codexConfig
$claudeSettings = if ($null -ne $claudeOriginal) { ConvertFrom-Json -InputObject $claudeOriginal -AsHashtable } else { [ordered]@{} }
if ($claudeSettings -isnot [System.Collections.IDictionary]) { throw '.claude.json のルートはオブジェクトで指定してください。' }

$base = 'https://raw.githubusercontent.com/ntaksh42/dotfiles/main'
$tempRoot = (Resolve-Path -LiteralPath ([IO.Path]::GetTempPath())).Path.TrimEnd('\', '/')
$staging = Join-Path $tempRoot ('dotfiles-mcp-' + [guid]::NewGuid())
if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($staging)) -ne $tempRoot) { throw '一時フォルダのパスが無効です。' }
New-Item -ItemType Directory -Path $staging | Out-Null
try {
    foreach ($file in @('claude/mcp/servers.json', 'tools/update-mcp-toml.py')) {
        $source = Join-Path $PSScriptRoot "../$file"
        $target = Join-Path $staging (Split-Path -Leaf $file)
        $content = if (Test-Path -LiteralPath $source) {
            [IO.File]::ReadAllText($source)
        } else {
            (Invoke-WebRequest -Uri "$base/$file").Content
        }
        [IO.File]::WriteAllText($target, $content.Replace([string][char]13 + [char]10, [string][char]10))
    }
    $manifest = Join-Path $staging 'servers.json'
    $helper = Join-Path $staging 'update-mcp-toml.py'
    $desired = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json -AsHashtable
    $claudeChanges = [ordered]@{}
    foreach ($name in $desired.Keys) {
        $server = $desired[$name]
        if ($name -cnotmatch '^[a-zA-Z0-9_-]+$' -or $server.Count -ne 2 -or
            $server.type -cne 'http' -or $server.url -cnotmatch '^https://\S+$') {
            throw "servers.json の MCP 設定が無効です ($name)。"
        }
        $current = if ($claudeSettings.mcpServers) { $claudeSettings.mcpServers[$name] }
        if ($current.Count -eq $server.Count -and $current.type -ceq $server.type -and $current.url -ceq $server.url) { continue }
        $claudeChanges[$name] = if ($null -ne $current) { '更新' } else { '追加' }
    }

    $stagedToml = Join-Path $staging 'config.toml'
    if ($null -ne $codexOriginal) { [IO.File]::WriteAllText($stagedToml, $codexOriginal) }
    $planJson = & uv run --quiet --no-project --script $helper $stagedToml $manifest
    if ($LASTEXITCODE -ne 0) { throw 'Codex MCP の設定差分を作れませんでした。' }
    $codexPlan = ConvertFrom-Json -InputObject ($planJson -join [char]10) -AsHashtable

    foreach ($name in $claudeChanges.Keys) { Write-Host "Claude Code $($claudeChanges[$name]) $name → $($desired[$name].url)" }
    foreach ($name in $codexPlan.changes.Keys) { Write-Host "Codex $($codexPlan.changes[$name]) $name → $($desired[$name].url)" }
    if (-not $claudeChanges.Count -and -not $codexPlan.changes.Count) { Write-Host 'MCP 設定に差分はありません。' }
    if ($Check) { return }

    # Let Claude write the user JSON in staging so an add failure leaves the original intact.
    if ($claudeChanges.Count) {
        $stagedJson = Join-Path $staging '.claude.json'
        if ($null -ne $claudeOriginal) { [IO.File]::WriteAllText($stagedJson, $claudeOriginal) }
        $previousClaudeDir = $env:CLAUDE_CONFIG_DIR
        try {
            $env:CLAUDE_CONFIG_DIR = $staging
            foreach ($name in $claudeChanges.Keys) {
                if ($claudeChanges[$name] -eq '更新') {
                    & claude mcp remove --scope user $name | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "Claude Code の $name を更新できませんでした。" }
                }
                ConvertTo-Json -InputObject $desired[$name] -Compress | & claude mcp add-json --scope user $name - | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Claude Code に $name を登録できませんでした。" }
            }
        } finally {
            $env:CLAUDE_CONFIG_DIR = $previousClaudeDir
        }
        $stagedSettings = Get-Content -LiteralPath $stagedJson -Raw | ConvertFrom-Json -AsHashtable
        # Preserve unrelated settings even if this version of the CLI migrated them in staging.
        if (-not $claudeSettings.mcpServers) { $claudeSettings.mcpServers = [ordered]@{} }
        foreach ($name in $claudeChanges.Keys) {
            $claudeSettings.mcpServers[$name] = $stagedSettings.mcpServers[$name]
        }
    }

    if ((Read-OptionalFile $claudeConfig) -cne $claudeOriginal -or (Read-OptionalFile $codexConfig) -cne $codexOriginal) {
        throw '処理中に設定が変わりました。もう一度実行してください。'
    }
    if ($claudeChanges.Count) { Write-Config $claudeConfig (ConvertTo-Json -InputObject $claudeSettings -Depth 100) }
    if ($codexPlan.changes.Count) { Write-Config $codexConfig $codexPlan.content }

    $installed = Join-Path $codexRoot 'dotfiles-mcp'
    New-Item -ItemType Directory -Path $installed -Force | Out-Null
    foreach ($file in @($manifest, $helper)) { Copy-Item -LiteralPath $file -Destination $installed -Force }
    Write-Host 'Context7 を使うときは Claude Code の /mcp または codex mcp login context7 でサインインしてください。'
} finally {
    # $staging is a new directory with an absolute path directly under $tempRoot.
    [IO.Directory]::Delete($staging, $true)
}
