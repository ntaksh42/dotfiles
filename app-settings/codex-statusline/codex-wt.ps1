param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CodexArgs
)

$ErrorActionPreference = 'Stop'

$python = (Get-Command python.exe -ErrorAction Stop).Source
$codex = (Get-Command codex.cmd -ErrorAction Stop).Source
$cwd = (Get-Location).Path

if (-not $env:WT_SESSION) {
    # wt.exe は呼び出し元の PATH を継承しないため、pwsh.exe は絶対パスで渡す。
    $pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
    & (Get-Command wt.exe -ErrorAction Stop).Source -w new new-tab -d $cwd --title Codex `
        $pwsh -NoExit -File $PSCommandPath @CodexArgs
    return
}

$stopFile = Join-Path ([System.IO.Path]::GetTempPath()) "codex-statusline-$([guid]::NewGuid().ToString('N')).stop"
& (Get-Command wt.exe -ErrorAction Stop).Source -w 0 split-pane -H -s 0.18 -d $cwd --title 'Codex Status' `
    $python (Join-Path $PSScriptRoot 'codex_statusline.py') --cwd $cwd --since ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 1) --stop-file $stopFile

Start-Sleep -Milliseconds 400
try {
    & $codex -c 'tui.status_line=[]' @CodexArgs
    $exitCode = $LASTEXITCODE
}
finally {
    [void](New-Item -ItemType File -Path $stopFile -Force)
    Start-Sleep -Milliseconds 2500
    Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue
}

$global:LASTEXITCODE = $exitCode
