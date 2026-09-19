param(
    # Position = 0 を明示しないと、位置引数が先に宣言された内部用パラメータへ
    # 束縛されてしまう（例: cx resume の 'resume' が $ArgsFile に吸われ、
    # codex に渡らないまま「引数ファイルが見つかりません」と警告が出る）。
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$CodexArgs,

    # 内部用。再起動時に引数を受け渡す。利用者は指定しない。
    [Parameter(DontShow)]
    [string]$ArgsFile,

    # 内部用。ステータスラインを出す窓の ID。
    [Parameter(DontShow)]
    [string]$WindowId
)

$ErrorActionPreference = 'Stop'

$python = (Get-Command python.exe -ErrorAction Stop).Source

# wt の -d に渡せるのは実在するファイルシステム上のディレクトリだけ。
# (Get-Location).Path はレジストリや Env: などのプロバイダパスにもなり得て、
# その場合 wt はタブを起動できず「'codex' の起動時にエラー 2147942402
# (0x80070002) 指定されたファイルが見つかりません」で失敗する。
$location = Get-Location
if ($location.Provider.Name -eq 'FileSystem' -and (Test-Path -LiteralPath $location.ProviderPath -PathType Container)) {
    $cwd = $location.ProviderPath
}
else {
    $cwd = $env:USERPROFILE
}

# プロファイル側と同じフォールバックを持たせる。codex.cmd が PATH に無いだけで
# ラッパーごと落ちると、呼び出し元のフォールバックが働く前に失敗してしまう。
$codex = (Get-Command codex.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $codex) { $codex = Join-Path $env:APPDATA 'npm\codex.cmd' }
if (-not (Test-Path -LiteralPath $codex)) { throw "codex.cmd が見つかりません: $codex" }

$wt = (Get-Command wt.exe -ErrorAction Stop).Source

# $WindowId は自分自身の再起動でしか渡らない。$env:WT_SESSION は「Windows
# Terminal の中にいる」ことしか示さないため、これを条件にすると既に開いている
# タブで cx を叩いただけでそこにステータスラインが割り込んでしまう。
if (-not $WindowId) {
    # wt.exe は引数を自前のパーサで解釈し、';' をサブコマンド区切りとして
    # 食ってしまう（エラーにならず黙って切り捨てられる）。引数は wt の
    # コマンドラインに乗せず、一時ファイル経由で再起動後の自分に渡す。
    $handoff = Join-Path ([System.IO.Path]::GetTempPath()) "codex-args-$([guid]::NewGuid().ToString('N')).json"
    ConvertTo-Json -InputObject @($CodexArgs) -Depth 3 | Set-Content -LiteralPath $handoff -Encoding utf8

    # -w 0 は「直近に使われた窓」であって、ここで作る窓とは限らない。
    # 一意な窓名を割り当て、再起動後の split-pane が同じ窓を確実に指すようにする。
    $windowName = "codex-$([guid]::NewGuid().ToString('N').Substring(0, 8))"

    # wt.exe は呼び出し元の PATH を継承しないため、pwsh.exe は絶対パスで渡す。
    $pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
    & $wt -w $windowName new-tab -d $cwd --title Codex `
        $pwsh -NoExit -File $PSCommandPath -ArgsFile $handoff -WindowId $windowName
    return
}

# 再起動後は引数をファイルから復元する（wt のパーサを通っていない生の値）。
if ($ArgsFile) {
    if (Test-Path -LiteralPath $ArgsFile) {
        $raw = Get-Content -LiteralPath $ArgsFile -Raw
        if ($raw.Trim()) { $CodexArgs = @(ConvertFrom-Json $raw) }
        Remove-Item -LiteralPath $ArgsFile -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-Warning "引数ファイルが見つかりません: $ArgsFile"
    }
}
if (-not $CodexArgs) { $CodexArgs = @() }

# ここは第 1 段が作った窓の中で動いている。自分がいる窓を名前で指し直すと
# wt がその窓を別途呼び出しに行き、ペインが期待どおり出ないことがある。
# 現在の窓を指す -w 0 を使う（この時点では自分の窓が最前面にいる）。
$stopFile = Join-Path ([System.IO.Path]::GetTempPath()) "codex-statusline-$([guid]::NewGuid().ToString('N')).stop"
& $wt -w 0 split-pane -H -s 0.18 -d $cwd --title 'Codex Status' `
    $python (Join-Path $PSScriptRoot 'codex_statusline.py') --cwd $cwd --since ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 1) --stop-file $stopFile

Start-Sleep -Milliseconds 400

# codex の起動自体が失敗した場合に $exitCode が未代入のまま finally を抜け、
# 失敗が成功として伝播しないよう、既定値を入れておく。
$exitCode = 1
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
