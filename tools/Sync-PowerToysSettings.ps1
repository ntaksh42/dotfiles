<#
.SYNOPSIS
    PowerToys の設定ファイルと app-settings/powertoys/ を同期する。

.DESCRIPTION
    -Direction Pull: 実環境 -> リポジトリ（バックアップ）。
    -Direction Push（既定）: リポジトリ -> 実環境（復元）。PowerToys が起動中なら
    停止してからコピーし、復元後に再起動する。
    -WhatIf で実際にコピーせず対象だけ確認できる。

    対象は PowerToys 公式の Back up & restore と同じ設定ファイル
    （各モジュールの settings.json、FancyZones のレイアウト・ホットキー・テンプレート、
    Keyboard Manager の default.json）。次は対象外。
    - Workspaces\workspaces.json、NewPlus\settings.json: ユーザー名を含むパスが入るため
    - FancyZones の applied-layouts / default-layouts / app-zone-history: 公式バックアップの対象外
      （復元後にモニターごとのレイアウトを選び直す）
    ルートの settings.json は、公式バックアップと同じく powertoys_version を除いて保存する。

.EXAMPLE
    pwsh -File tools/Sync-PowerToysSettings.ps1 -Direction Pull
    pwsh -File tools/Sync-PowerToysSettings.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Push', 'Pull')]
    [string]$Direction = 'Push',

    # テスト用に実環境側のルートを差し替えられる
    [string]$EnvRoot = (Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys')
)

$ErrorActionPreference = "Stop"
$isRealEnv = $EnvRoot -eq (Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys')

$repoRoot = Split-Path -Parent $PSScriptRoot
$repoDir  = Join-Path $repoRoot 'app-settings\powertoys'

# ユーザー名入りのパスを含むため同期しないモジュール
$excludeModules = @('NewPlus')

$fixedFiles = @(
    'FancyZones\custom-layouts.json'
    'FancyZones\layout-hotkeys.json'
    'FancyZones\layout-templates.json'
    'Keyboard Manager\default.json'
)

# root 配下の対象ファイル（root からの相対パス）を返す
function Get-TargetFiles([string]$root) {
    if (-not (Test-Path $root)) { return @() }
    $rel = @('settings.json')
    $rel += Get-ChildItem $root -Directory | Where-Object Name -notin $excludeModules | ForEach-Object { Join-Path $_.Name 'settings.json' }
    $rel += $fixedFiles
    $rel | Where-Object { Test-Path (Join-Path $root $_) }
}

if ($Direction -eq 'Pull') { $srcRoot = $EnvRoot; $dstRoot = $repoDir }
else                       { $srcRoot = $repoDir; $dstRoot = $EnvRoot }

$files = @(Get-TargetFiles $srcRoot)
if ($files.Count -eq 0) {
    Write-Warning "コピー元に対象ファイルがありません: $srcRoot"
    return
}

# 復元時は PowerToys が設定を書き戻すため、停止してからコピーする（-EnvRoot 差し替え時は対象外）
$restartExe = $null
if ($Direction -eq 'Push' -and $isRealEnv) {
    $running = @(Get-Process -Name 'PowerToys*' -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        $restartExe = ($running | Where-Object Name -eq 'PowerToys' | Select-Object -First 1).Path
        if ($PSCmdlet.ShouldProcess('PowerToys', '停止')) {
            $running | Stop-Process -Force
            Start-Sleep -Seconds 1
        }
    }
}

foreach ($rel in $files) {
    $src = Join-Path $srcRoot $rel
    $dst = Join-Path $dstRoot $rel

    if ($PSCmdlet.ShouldProcess($dst, "$Direction コピー ($src)")) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
        if ($Direction -eq 'Pull' -and $rel -eq 'settings.json') {
            $json = Get-Content $src -Raw | ConvertFrom-Json
            $json.PSObject.Properties.Remove('powertoys_version')
            $json | ConvertTo-Json -Depth 20 -Compress | Set-Content $dst -Encoding utf8NoBOM
        } else {
            Copy-Item -Path $src -Destination $dst -Force
        }
        Write-Host "[OK] $Direction`: $rel"
    }
}

# Install-PowerToysSettings.ps1 が取得対象を知るための一覧（バックアップのたびに更新する）
if ($Direction -eq 'Pull' -and $PSCmdlet.ShouldProcess((Join-Path $repoDir 'manifest.txt'), 'manifest 更新')) {
    ($files -replace '\\', '/') | Set-Content (Join-Path $repoDir 'manifest.txt') -Encoding utf8NoBOM
}

if ($restartExe -and $PSCmdlet.ShouldProcess($restartExe, '再起動')) {
    Start-Process $restartExe
}
