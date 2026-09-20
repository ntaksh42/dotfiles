$ErrorActionPreference = 'Stop'

$architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
$assetArchitecture = switch ($architecture) {
    'X64' { 'amd64' }
    'Arm64' { 'arm64' }
    default { throw "Crit does not provide a Windows binary for $architecture." }
}

$installDir = Join-Path $env:USERPROFILE '.local\bin'
$critPath = Join-Path $installDir 'crit.exe'
$downloadPath = Join-Path $env:TEMP "crit-$([guid]::NewGuid().ToString('N')).exe"
$downloadUrl = "https://github.com/tomasz-tomczyk/crit/releases/latest/download/crit-windows-$assetArchitecture.exe"

New-Item -ItemType Directory -Path $installDir -Force | Out-Null
try {
    Invoke-WebRequest -Uri $downloadUrl -OutFile $downloadPath
    Move-Item -LiteralPath $downloadPath -Destination $critPath -Force
}
finally {
    Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
}

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$pathEntries = @($userPath -split ';' | Where-Object { $_ })
if ($pathEntries.TrimEnd('\') -notcontains $installDir.TrimEnd('\')) {
    $updatedPath = (@($pathEntries) + $installDir) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $updatedPath, 'User')
}
if (($env:Path -split ';').TrimEnd('\') -notcontains $installDir.TrimEnd('\')) {
    $env:Path = "$env:Path;$installDir"
}

$configPath = Join-Path $env:USERPROFILE '.crit.config.json'
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    try {
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "$configPath is not valid JSON. Fix it before installing Crit."
    }
}
else {
    $config = [pscustomobject]@{}
}

$config | Add-Member -NotePropertyName host -NotePropertyValue '127.0.0.1' -Force
$config | Add-Member -NotePropertyName no_update_check -NotePropertyValue $true -Force
$config | Add-Member -NotePropertyName share_url -NotePropertyValue '' -Force
$config | Add-Member -NotePropertyName share_targets -NotePropertyValue @() -Force
$config | Add-Member -NotePropertyName agent_cmd -NotePropertyValue '' -Force

$renderedConfig = $config | ConvertTo-Json -Depth 100
$currentConfig = if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    (Get-Content -LiteralPath $configPath -Raw).TrimEnd()
}
else {
    $null
}
if ($currentConfig -ne $renderedConfig) {
    Set-Content -LiteralPath $configPath -Value $renderedConfig -Encoding UTF8
}

Push-Location $env:USERPROFILE
try {
    & $critPath install --force codex
    if ($LASTEXITCODE -ne 0) { throw "crit install codex failed with exit code $LASTEXITCODE" }
}
finally {
    Pop-Location
}

& $critPath --version
if ($LASTEXITCODE -ne 0) { throw "crit --version failed with exit code $LASTEXITCODE" }
Write-Host "[OK] Crit installed: $critPath" -ForegroundColor Green
Write-Host "[OK] Safe defaults written: $configPath" -ForegroundColor Green
