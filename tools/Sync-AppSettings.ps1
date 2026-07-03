<#
.SYNOPSIS
    app-settings/ 配下の設定ファイルを実環境の配置先へコピーする。

.DESCRIPTION
    リポジトリで管理している設定ファイル（starship・PowerShell プロファイル等）を
    実際に読み込まれる場所へ反映する。編集後の手動 Copy-Item の入れ忘れを防ぐ。
    -WhatIf で実際にコピーせず対象だけ確認できる。

.EXAMPLE
    pwsh -File tools/Sync-AppSettings.ps1
    pwsh -File tools/Sync-AppSettings.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = "Stop"

# リポジトリルート（このスクリプトの 1 つ上）を基準にする
$repoRoot = Split-Path -Parent $PSScriptRoot

# PowerShell 7 のプロファイルパス（OneDrive の Documents リダイレクトに追従）。
# $PROFILE は実行ホスト依存で、powershell.exe (5.1) で実行すると WindowsPowerShell 側に
# コピーされてしまう（プロファイルは PS7 専用構文を含む）ため使わない。
$pwsh7Profile = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Microsoft.PowerShell_profile.ps1'

# 同期マッピング: 管理元（repo 相対） → 反映先（実環境）
$mappings = @(
    @{ Source = "app-settings\starship\starship.toml";              Dest = "$HOME\.config\starship.toml" }
    @{ Source = "app-settings\pwsh\Microsoft.PowerShell_profile.ps1"; Dest = $pwsh7Profile }
    # Everything は終了時に Filters.csv を上書き保存するため、反映前に終了させておくこと
    @{ Source = "app-settings\everything\Filters.csv";               Dest = "$env:APPDATA\Everything\Filters.csv" }
)

foreach ($m in $mappings) {
    $src = Join-Path $repoRoot $m.Source
    $dst = $m.Dest

    if (-not (Test-Path $src)) {
        Write-Warning "管理元が見つかりません: $src （スキップ）"
        continue
    }

    $dstDir = Split-Path -Parent $dst
    if (-not (Test-Path $dstDir)) {
        if ($PSCmdlet.ShouldProcess($dstDir, "ディレクトリ作成")) {
            New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
        }
    }

    if ($PSCmdlet.ShouldProcess($dst, "コピー ($($m.Source))")) {
        Copy-Item -Path $src -Destination $dst -Force
        Write-Host "[OK] $($m.Source) -> $dst"
    }
}
