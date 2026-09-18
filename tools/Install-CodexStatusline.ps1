<#
.SYNOPSIS
    Codex の Windows Terminal 用ステータスラインを現在ユーザーへ配置する。
#>
[CmdletBinding()]
param(
    [string]$BaseUri = 'https://raw.githubusercontent.com/ntaksh42/dotfiles/main'
)

$ErrorActionPreference = 'Stop'

$target = Join-Path $env:LOCALAPPDATA 'CodexStatusline'
$files = @('app-settings/codex-statusline/codex_statusline.py', 'app-settings/codex-statusline/codex-wt.ps1')
New-Item -ItemType Directory -Force -Path $target | Out-Null

foreach ($relativePath in $files) {
    $destination = Join-Path $target (Split-Path -Leaf $relativePath)
    Invoke-WebRequest -Uri "$BaseUri/$relativePath" -OutFile $destination
    Unblock-File -LiteralPath $destination -ErrorAction SilentlyContinue
}

Write-Host "[OK] Codex statusline installed: $target" -ForegroundColor Green
Write-Host 'Restart PowerShell or run . $PROFILE to use it.' -ForegroundColor Gray
