# Run with: pwsh -NoProfile -File app-settings/pwsh/tests/Invoke-AllTests.ps1
# Runs every Test-*.ps1 in this directory in its own pwsh process and exits 1 if any fails.
$ErrorActionPreference = 'Stop'
$pwsh = (Get-Process -Id $PID).Path
$results = foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'Test-*.ps1' | Sort-Object Name) {
    $output = & $pwsh -NoLogo -NoProfile -NonInteractive -File $file.FullName 2>&1 | Out-String -Stream
    $summary = $output | Where-Object { $_ -match '^\d+ passed, \d+ failed' } | Select-Object -Last 1
    $output | Where-Object { $_ -match '^FAIL' } | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    [pscustomobject]@{ File = $file.Name; ExitCode = $LASTEXITCODE; Summary = if ($summary) { $summary } else { 'no summary (crashed?)' } }
}
$results | Format-Table -AutoSize
if ($results | Where-Object { $_.ExitCode -ne 0 -or $_.Summary -notmatch ' 0 failed' }) { exit 1 }
