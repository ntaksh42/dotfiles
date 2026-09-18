<#
.SYNOPSIS
    app-settings/ 配下の設定ファイルと実環境の配置先を同期する。

.DESCRIPTION
    -Direction Push（既定）: リポジトリの管理元 → 実環境の配置先へコピーする。
    -Direction Pull: 実環境の配置先 → リポジトリの管理元へコピーする（実運用側での
    編集をリポジトリへ取り込む）。
    -WhatIf で実際にコピーせず対象だけ確認できる。

.EXAMPLE
    pwsh -File tools/Sync-AppSettings.ps1
    pwsh -File tools/Sync-AppSettings.ps1 -Direction Pull -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Push', 'Pull')]
    [string]$Direction = 'Push'
)

$ErrorActionPreference = "Stop"

# リポジトリルート（このスクリプトの 1 つ上）を基準にする
$repoRoot = Split-Path -Parent $PSScriptRoot

# PowerShell 7 のプロファイルパス（OneDrive の Documents リダイレクトに追従）。
# $PROFILE は実行ホスト依存で、powershell.exe (5.1) で実行すると WindowsPowerShell 側に
# コピーされてしまう（プロファイルは PS7 専用構文を含む）ため使わない。
$pwsh7Profile = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Microsoft.PowerShell_profile.ps1'

# 同期マッピング: リポジトリ管理元（repo 相対） <-> 実環境の配置先
$mappings = @(
    @{ Repo = "app-settings\pwsh\Microsoft.PowerShell_profile.ps1"; Env = $pwsh7Profile }
    @{ Repo = "app-settings\starship\starship.toml"; Env = Join-Path $HOME ".config\starship.toml" }
)

foreach ($m in $mappings) {
    $repoPath = Join-Path $repoRoot $m.Repo
    $envPath  = $m.Env

    if ($Direction -eq 'Push') {
        $src = $repoPath; $dst = $envPath
    } else {
        $src = $envPath; $dst = $repoPath
    }

    if (-not (Test-Path $src)) {
        Write-Warning "コピー元が見つかりません: $src （スキップ）"
        continue
    }

    $dstDir = Split-Path -Parent $dst
    if (-not (Test-Path $dstDir)) {
        if ($PSCmdlet.ShouldProcess($dstDir, "ディレクトリ作成")) {
            New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
        }
    }

    if ($PSCmdlet.ShouldProcess($dst, "$Direction コピー ($src)")) {
        Copy-Item -Path $src -Destination $dst -Force
        Write-Host "[OK] $Direction`: $src -> $dst"
    }
}
