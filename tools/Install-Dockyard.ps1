$ErrorActionPreference = 'Stop'

# Dockyard の最新リリース（MSIX）を入れる。Install-DevTools の 'Dockyard' から実行される。
# 署名は自己署名証明書のため、未信頼なら Dockyard.cer を LocalMachine\TrustedPeople に入れる（UAC が出る）。

# ARM64 の PC でも x64 版を入れる（エミュレーションで動く）。
$runtime = 'x64'
# Dockyard の署名証明書（CN=Dockyard Dev）の拇印。
$expectedThumbprint = 'DA3BDF984785F9827AC97F771288E4F7429CC88E'

$release = Invoke-RestMethod -Uri 'https://api.github.com/repos/ntaksh42/dockyard/releases/latest' `
    -Headers @{ 'User-Agent' = 'dotfiles-install-devtools' }
$msixAsset = $release.assets | Where-Object { $_.name -like "Dockyard-*-$runtime.msix" } | Select-Object -First 1
$cerAsset = $release.assets | Where-Object { $_.name -eq 'Dockyard.cer' } | Select-Object -First 1
if (-not $msixAsset -or -not $cerAsset) { throw "Dockyard $($release.tag_name) has no $runtime package or certificate." }

# 実行に必要な x64 版の .NET 10 Desktop Runtime。ARM64 の PC では x64 版は dotnet\x64 に入り、
# ARM64 版の .NET 10 があっても x64 の Dockyard は起動できない。
$dotnetRoot = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64' ?
    "$env:ProgramFiles\dotnet\x64" : "$env:ProgramFiles\dotnet"
if (-not (Get-ChildItem -Path "$dotnetRoot\shared\Microsoft.WindowsDesktop.App\10.*" -Directory -ErrorAction Ignore)) {
    # 同じ ID の ARM64 版が入っていると winget は導入済みとみなし、更新を探すだけで終わる (0x8A15002B)。
    # --force で x64 版を並べて入れさせる。
    winget install --id Microsoft.DotNet.DesktopRuntime.10 --exact --architecture x64 --force --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "winget install Microsoft.DotNet.DesktopRuntime.10 failed with exit code $LASTEXITCODE" }
}

$dir = Join-Path $env:TEMP "dockyard-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $dir -Force | Out-Null
try {
    $msixPath = Join-Path $dir $msixAsset.name
    $cerPath = Join-Path $dir $cerAsset.name
    Invoke-WebRequest -Uri $msixAsset.browser_download_url -OutFile $msixPath -UseBasicParsing
    Invoke-WebRequest -Uri $cerAsset.browser_download_url -OutFile $cerPath -UseBasicParsing

    # リリースに置かれた証明書をそのまま信頼しないよう、既知の拇印と一致するものだけを入れる。
    # 証明書を作り直したら（期限 2027-10-23）、ここを新しい拇印に書き換える。
    $thumbprint = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($cerPath).Thumbprint
    if ($thumbprint -ne $expectedThumbprint) { throw "Dockyard.cer thumbprint $thumbprint does not match the expected $expectedThumbprint." }
    if (-not (Test-Path -LiteralPath "Cert:\LocalMachine\TrustedPeople\$thumbprint")) {
        $command = "Import-Certificate -FilePath '$cerPath' -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null"
        $proc = Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -Wait -PassThru `
            -ArgumentList '-NoProfile', '-Command', $command
        if ($proc.ExitCode -ne 0) { throw "Importing Dockyard.cer failed with exit code $($proc.ExitCode)" }
    }

    # 起動中なら終了させて差し替える（前回のグループは次回起動時に session.json から組み直される）。
    Add-AppxPackage -Path $msixPath -ForceApplicationShutdown
}
finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "[OK] Dockyard installed: $($release.tag_name) ($runtime)" -ForegroundColor Green
