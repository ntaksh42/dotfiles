# Install the same global instructions for Claude Code and Codex.
param(
    [string]$ClaudeDir = (Join-Path $env:USERPROFILE '.claude'),
    [string]$CodexDir = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' })
)

$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '..\claude\CLAUDE.global.md'
$sourceHash = (Get-FileHash -LiteralPath $source).Hash
$destinations = @((Join-Path $ClaudeDir 'CLAUDE.md'), (Join-Path $CodexDir 'AGENTS.md'))

foreach ($destination in $destinations) {
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        if ((Get-FileHash -LiteralPath $destination).Hash -eq $sourceHash) { continue }
        $backup = "$destination.backup.$([guid]::NewGuid().ToString('N'))"
        Copy-Item -LiteralPath $destination -Destination $backup
        Write-Host "Backed up: $backup" -ForegroundColor Gray
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Force
    Write-Host "Installed instructions: $destination" -ForegroundColor Green
}

$override = Join-Path $CodexDir 'AGENTS.override.md'
if ((Test-Path -LiteralPath $override -PathType Leaf) -and
    -not [string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $override -Raw))) {
    Write-Warning "Codex uses $override instead of AGENTS.md. Review the override to use the shared instructions."
}
