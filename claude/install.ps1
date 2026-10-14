# Claude Code dotfiles installer for Windows
# Usage: .\install.ps1
# skills・hooks は claude/mods/ の plugin として Install-DevTools が導入する。
# このスクリプトは CLAUDE.md と settings.json の配置だけを行う。

param()

$ErrorActionPreference = "Stop"

# Paths
$ScriptDir       = Split-Path -Parent $MyInvocation.MyCommand.Path
$ClaudeDir       = Join-Path $env:USERPROFILE ".claude"
$TemplateFile    = Join-Path $ScriptDir "settings.template.json"
$GlobalClaudeMd  = Join-Path $ScriptDir "CLAUDE.global.md"

Write-Host "Claude Code dotfiles installer" -ForegroundColor Cyan
Write-Host "==============================" -ForegroundColor Cyan
Write-Host ""

# Create .claude directory if not exists
if (-not (Test-Path $ClaudeDir)) {
    Write-Host "Creating $ClaudeDir ..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $ClaudeDir | Out-Null
}

# Backup existing settings.json
$SettingsFile = Join-Path $ClaudeDir "settings.json"
if (Test-Path $SettingsFile) {
    $BackupFile = Join-Path $ClaudeDir "settings.json.backup.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Write-Host "Backing up existing settings.json to $BackupFile" -ForegroundColor Yellow
    Copy-Item $SettingsFile $BackupFile
}

# Copy global CLAUDE.md (CLAUDE.global.md -> ~/.claude/CLAUDE.md)
if (Test-Path $GlobalClaudeMd) {
    Write-Host "Copying global CLAUDE.md..." -ForegroundColor Green
    $ClaudeMdDest = Join-Path $ClaudeDir "CLAUDE.md"
    if (Test-Path $ClaudeMdDest) {
        $ClaudeMdBackup = Join-Path $ClaudeDir "CLAUDE.md.backup.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Write-Host "  Backing up existing CLAUDE.md to $ClaudeMdBackup" -ForegroundColor Yellow
        Copy-Item $ClaudeMdDest $ClaudeMdBackup
    }
    Copy-Item $GlobalClaudeMd $ClaudeMdDest -Force
    Write-Host "  - CLAUDE.md (from CLAUDE.global.md)" -ForegroundColor Gray
}

# Set ENABLE_TOOL_SEARCH environment variable if not exists
$envName = "ENABLE_TOOL_SEARCH"
$currentValue = [Environment]::GetEnvironmentVariable($envName, "User")
if (-not $currentValue) {
    Write-Host "Setting $envName environment variable..." -ForegroundColor Green
    [Environment]::SetEnvironmentVariable($envName, "true", "User")
    $env:ENABLE_TOOL_SEARCH = "true"
    Write-Host "  - $envName = true (User scope)" -ForegroundColor Gray
} else {
    Write-Host "$envName already set: $currentValue" -ForegroundColor Gray
}

# Generate settings.json from template
Write-Host "Generating settings.json..." -ForegroundColor Green
$template = Get-Content $TemplateFile -Raw -Encoding UTF8
# JSON テキストへの埋め込みなのでバックスラッシュを1段だけエスケープする
$repoDirEscaped = (Split-Path -Parent $ScriptDir) -replace '\\', '\\'
$settings = $template -replace '\{\{REPO_DIR\}\}', $repoDirEscaped
$null = $settings | ConvertFrom-Json

# PS 5.1 の -Encoding UTF8 は BOM を付けるため、BOM なし UTF-8 を明示して書き出す
[System.IO.File]::WriteAllText($SettingsFile, $settings, (New-Object System.Text.UTF8Encoding $false))
Write-Host "  - $SettingsFile" -ForegroundColor Gray

Write-Host ""
Write-Host "Installation complete!" -ForegroundColor Green
Write-Host "Run Install-DevTools to install the dotfiles plugins (skills, hooks, mods)." -ForegroundColor Yellow
Write-Host "Note: Restart Claude Code for changes to take effect." -ForegroundColor Yellow
