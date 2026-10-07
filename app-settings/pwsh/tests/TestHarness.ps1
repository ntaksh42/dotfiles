# Shared by every Test-*.ps1 in this directory. Dot-source it, define cases with Test-Case,
# and finish the file with Complete-Tests (prints the totals and exits 1 on any failure).
$script:pass = 0
$script:fail = 0

function Test-Case {
    param([string]$Name, [scriptblock]$Check)
    try {
        if (-not (& $Check)) { throw 'Check returned false' }
        Write-Host "ok    $Name" -ForegroundColor Green
        $script:pass++
    }
    catch {
        Write-Host "FAIL  $Name -- $_" -ForegroundColor Red
        $script:fail++
    }
}

function Complete-Tests {
    Write-Host "$script:pass passed, $script:fail failed"
    if ($script:fail -gt 0) { exit 1 }
}
