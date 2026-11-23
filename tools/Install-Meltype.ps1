$ErrorActionPreference = 'Stop'

# Meltype（日本語入力）の最新リリースの setup.exe（Inno Setup、ユーザー単位）を入れる。
# Install-DevTools の 'Meltype' から実行される。Meltype IME の登録で UAC の確認が出る。
# 以後の更新は Meltype 自身の自動更新に任せる。

$release = Invoke-RestMethod -Uri 'https://api.github.com/repos/yksr-melt/Meltype/releases/latest' `
    -Headers @{ 'User-Agent' = 'dotfiles-install-devtools' }
$asset = $release.assets | Where-Object { $_.name -like 'Meltype-*-setup.exe' } | Select-Object -First 1
if (-not $asset) { throw "Meltype $($release.tag_name) has no setup.exe." }

$dir = Join-Path $env:TEMP "meltype-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $dir -Force | Out-Null
try {
    $setup = Join-Path $dir $asset.name
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $setup -UseBasicParsing
    # 公式の Install-Meltype.ps1 と同じ引数。インストーラーが起動した Meltype は残り続けるため、
    # 子孫のプロセスまで待つ Start-Process -Wait は使わない。
    $process = Start-Process -FilePath $setup -ArgumentList '/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -PassThru
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "Meltype installer exited with code $($process.ExitCode). Log: $env:TEMP\Setup Log *.txt" }
}
finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "[OK] Meltype installed: $($release.tag_name)" -ForegroundColor Green
