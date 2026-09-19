param(
    # Position = 0 を明示しないと、位置引数が先に宣言された内部用パラメータへ
    # 束縛されてしまう（例: cx resume の 'resume' が $InternalArgsFile に吸われ、
    # codex に渡らないまま「引数ファイルが見つかりません」と警告が出る）。
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$CodexArgs,

    # 内部用。再起動時に引数を受け渡す。利用者は指定しない。
    [Parameter(DontShow)]
    [string]$InternalArgsFile,

    # 内部用。第 1 段が開いたステータスラインのペインを codex 終了後に畳む
    # ための合図ファイル。これが渡っていること自体が「第 2 段である」印。
    #
    # 名前を -StopFile にすると codex の -s (sandbox) が前方一致で
    # 吸われてしまう（cx -s read-only が壊れる）。codex 側に無い接頭辞を選ぶ。
    [Parameter(DontShow)]
    [string]$InternalStopFile,

    # 内部用。Windows Terminal 内からの起動時は、現在のタブへステータス
    # ペインを分割してから、呼び出し元のペインで codex を起動する。
    [Parameter(DontShow)]
    [switch]$InternalCurrentWindow
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

# $InternalStopFile は自分自身の再起動でしか渡らない。$env:WT_SESSION は「Windows
# Terminal の中にいる」ことしか示さないため、これを条件にすると既に開いている
# タブで cx を叩いただけでそこにステータスラインが割り込んでしまう。
if (-not $InternalStopFile) {
    $InternalStopFile = Join-Path ([System.IO.Path]::GetTempPath()) "codex-statusline-$([guid]::NewGuid().ToString('N')).stop"

    if ($InternalCurrentWindow) {
        # -w 0 は Windows Terminal 内から呼んだ直後だけ使う。profile 側が
        # WT_SESSION の存在を確認してから渡すため、Terminal 外の起動は新規窓のまま。
        & $wt -w 0 split-pane -H -s 0.18 -d $cwd --title 'Codex Status' `
            $python (Join-Path $PSScriptRoot 'codex_statusline.py') --cwd $cwd --since ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 1) --stop-file $InternalStopFile
        if ($LASTEXITCODE -ne 0) { throw "statusline ペインの起動に失敗しました: $LASTEXITCODE" }
        Start-Sleep -Milliseconds 400
    }
    else {
        # wt.exe は引数を自前のパーサで解釈し、';' をサブコマンド区切りとして
        # 食ってしまう（エラーにならず黙って切り捨てられる）。引数は wt の
        # コマンドラインに乗せず、一時ファイル経由で再起動後の自分に渡す。
        $handoff = Join-Path ([System.IO.Path]::GetTempPath()) "codex-args-$([guid]::NewGuid().ToString('N')).json"
        ConvertTo-Json -InputObject @($CodexArgs) -Depth 3 | Set-Content -LiteralPath $handoff -Encoding utf8

    # wt.exe は呼び出し元の PATH を継承しないため、pwsh.exe は絶対パスで渡す。
        $pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source

    # 窓を作る wt 呼び出しの中で split-pane まで済ませる。別プロセスから
    # あとで -w で窓を指し直す方式は、-w 0 が「直近に使われた窓」を指すため
    # 他の窓にペインを落としてしまう（codex とは無関係の窓に出る）。
    # 区切りの ';' は独立した 1 引数として渡す。
        $argv = @(
            '-w', 'new'
            'new-tab', '-d', $cwd, '--title', 'Codex'
            $pwsh, '-NoExit', '-File', $PSCommandPath, '-InternalArgsFile', $handoff, '-InternalStopFile', $InternalStopFile
            ';'
            'split-pane', '-H', '-s', '0.18', '-d', $cwd, '--title', 'Codex Status'
            $python, (Join-Path $PSScriptRoot 'codex_statusline.py')
            '--cwd', $cwd
            '--since', ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 1)
            '--stop-file', $InternalStopFile
        )
        & $wt @argv
        return
    }
}

# 再起動後は引数をファイルから復元する（wt のパーサを通っていない生の値）。
if ($InternalArgsFile) {
    if (Test-Path -LiteralPath $InternalArgsFile) {
        $raw = Get-Content -LiteralPath $InternalArgsFile -Raw
        if ($raw.Trim()) { $CodexArgs = @(ConvertFrom-Json $raw) }
        Remove-Item -LiteralPath $InternalArgsFile -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-Warning "引数ファイルが見つかりません: $InternalArgsFile"
    }
}
if (-not $CodexArgs) { $CodexArgs = @() }

# ステータスラインのペインは第 1 段が同じ wt 呼び出しで開いている。
# ここでやるのは codex の起動と、終了時にそのペインを畳むことだけ。

# codex の起動自体が失敗した場合に $exitCode が未代入のまま finally を抜け、
# 失敗が成功として伝播しないよう、既定値を入れておく。
$exitCode = 1
try {
    & $codex -c 'tui.status_line=[]' @CodexArgs
    $exitCode = $LASTEXITCODE
}
finally {
    [void](New-Item -ItemType File -Path $InternalStopFile -Force)
    Start-Sleep -Milliseconds 2500
    Remove-Item -LiteralPath $InternalStopFile -Force -ErrorAction SilentlyContinue
}

$global:LASTEXITCODE = $exitCode
