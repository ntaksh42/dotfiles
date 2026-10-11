$ErrorActionPreference = 'Stop'

# Dockyard の最新リリース（MSIX）を入れる。Install-DevTools の 'Dockyard' から実行される。
# 署名は自己署名証明書のため、未信頼なら Dockyard.cer を LocalMachine\TrustedPeople に入れる（UAC が出る）。

$runtime = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
    'X64' { 'x64' }
    'Arm64' { 'arm64' }
    default { throw "Dockyard does not provide a package for $_." }
}

$release = Invoke-RestMethod -Uri 'https://api.github.com/repos/ntaksh42/dockyard/releases/latest' `
    -Headers @{ 'User-Agent' = 'dotfiles-install-devtools' }
$msixAsset = $release.assets | Where-Object { $_.name -like "Dockyard-*-$runtime.msix" } | Select-Object -First 1
$cerAsset = $release.assets | Where-Object { $_.name -eq 'Dockyard.cer' } | Select-Object -First 1
if (-not $msixAsset -or -not $cerAsset) { throw "Dockyard $($release.tag_name) has no $runtime package or certificate." }

# 実行に必要な .NET 10 Desktop Runtime。
if (-not (Get-ChildItem -Path "$env:ProgramFiles\dotnet\shared\Microsoft.WindowsDesktop.App\10.*" -Directory -ErrorAction Ignore)) {
    winget install --id Microsoft.DotNet.DesktopRuntime.10 --exact --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "winget install Microsoft.DotNet.DesktopRuntime.10 failed with exit code $LASTEXITCODE" }
}

$dir = Join-Path $env:TEMP "dockyard-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $dir -Force | Out-Null
try {
    $msixPath = Join-Path $dir $msixAsset.name
    $cerPath = Join-Path $dir $cerAsset.name
    Invoke-WebRequest -Uri $msixAsset.browser_download_url -OutFile $msixPath -UseBasicParsing
    Invoke-WebRequest -Uri $cerAsset.browser_download_url -OutFile $cerPath -UseBasicParsing

    $thumbprint = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($cerPath).Thumbprint
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
