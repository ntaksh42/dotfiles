$ErrorActionPreference = 'Stop'

# claude/mods/ の各 mod に claude plugin validate と claude plugin test をかけ、1 つでも失敗したら終了コード 1 を返す
$modsDir = Join-Path $PSScriptRoot '..\claude\mods'
$failed = @()

foreach ($mod in Get-ChildItem -Path $modsDir -Directory) {
    if (-not (Test-Path (Join-Path $mod.FullName '.claude-plugin\plugin.json'))) { continue }

    $out = claude plugin validate $mod.FullName 2>&1
    if ($LASTEXITCODE -ne 0) {
        $failed += "$($mod.Name) (validate)"
        Write-Host "NG  $($mod.Name): validate" -ForegroundColor Red
        $out | Write-Host
        continue
    }

    if (Get-ChildItem -Path $mod.FullName -Recurse -Include '*.test.ts', '*.test.tsx' -File) {
        $out = claude plugin test $mod.FullName 2>&1
        if ($LASTEXITCODE -ne 0) {
            $failed += "$($mod.Name) (test)"
            Write-Host "NG  $($mod.Name): test" -ForegroundColor Red
            $out | Write-Host
            continue
        }
    }
    Write-Host "OK  $($mod.Name)" -ForegroundColor Green
}

if ($failed) {
    Write-Host "失敗: $($failed -join ', ')" -ForegroundColor Red
    exit 1
}
