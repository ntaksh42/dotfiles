<#
.SYNOPSIS
    dotfiles の app-settings/powertoys/ を PowerToys の設定フォルダへ配置する。

.DESCRIPTION
    Install-DevTools の 'PowerToys settings' から実行される。manifest.txt に載った
    ファイルを GitHub から取得し、全ファイルが有効な JSON であることを確認してから
    書き込む。既存ファイルが異なる場合は .backup.<日時> を残す。
    PowerToys が起動中なら停止してから書き込み、書き込み後に再起動する。
    manifest.txt は tools/Sync-PowerToysSettings.ps1 -Direction Pull が更新する。
#>
param(
    [string]$BaseUri = 'https://raw.githubusercontent.com/ntaksh42/dotfiles/main',

    # テスト用に配置先を差し替えられる
    [string]$DestRoot = (Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys')
)

$ErrorActionPreference = 'Stop'
$isRealEnv = $DestRoot -eq (Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys')
$sourceUri = "$BaseUri/app-settings/powertoys"

$manifest = @((Invoke-WebRequest -Uri "$sourceUri/manifest.txt" -UseBasicParsing).Content -split "`r?`n" | Where-Object { $_ })
if ($manifest.Count -eq 0) { throw 'manifest.txt が空です。' }

# 途中で失敗して設定が中途半端にならないよう、先に全ファイルを取得して検証する
$files = foreach ($rel in $manifest) {
    $text = (Invoke-WebRequest -Uri "$sourceUri/$([uri]::EscapeUriString($rel))" -UseBasicParsing).Content
    try { $null = $text | ConvertFrom-Json }
    catch { throw "取得した $rel が不正な JSON のため中断しました（$($_.Exception.Message)）。設定は変更していません。" }
    [PSCustomObject]@{ Rel = $rel; Text = $text }
}

# PowerToys は終了時に設定を書き戻すため、起動中なら停止してから書き込む
$restartExe = $null
if ($isRealEnv) {
    $running = @(Get-Process -Name 'PowerToys*' -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        $restartExe = ($running | Where-Object Name -eq 'PowerToys' | Select-Object -First 1).Path
        $running | Stop-Process -Force
        Start-Sleep -Seconds 1
    }
}

$utf8NoBom = New-Object Text.UTF8Encoding $false
foreach ($f in $files) {
    $dest = Join-Path $DestRoot ($f.Rel -replace '/', '\')
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    if ((Test-Path -LiteralPath $dest -PathType Leaf) -and
        ([IO.File]::ReadAllText($dest) -cne $f.Text)) {
        Copy-Item -LiteralPath $dest -Destination "$dest.backup.$(Get-Date -Format 'yyyyMMdd-HHmmss')" -Force
    }
    [IO.File]::WriteAllText($dest, $f.Text, $utf8NoBom)
    Write-Host "  [OK] $($f.Rel)"
}

if ($restartExe) { Start-Process $restartExe }
