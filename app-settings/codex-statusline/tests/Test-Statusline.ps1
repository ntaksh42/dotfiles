# codex statusline の回帰テスト。
# このセッションで実際に踏んだ不具合を固定する。修正前の状態で走らせると
# 該当ケースが FAIL として並ぶ。
#
#   pwsh -NoProfile -File tests/Test-Statusline.ps1
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$wrapper = Join-Path $root 'codex-wt.ps1'
$statusline = Join-Path $root 'codex_statusline.py'

$script:pass = 0
$script:fail = 0

function Test-Case {
    param([string]$Name, [scriptblock]$Check)
    try {
        $ok = & $Check
    } catch {
        Write-Host "FAIL  $Name  -- 例外: $_" -ForegroundColor Red
        $script:fail++
        return
    }
    if ($ok) {
        Write-Host "ok    $Name" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "FAIL  $Name" -ForegroundColor Red
        $script:fail++
    }
}

$python = (Get-Command python.exe -ErrorAction SilentlyContinue).Source
$pwshExe = (Get-Command pwsh.exe -ErrorAction Stop).Source

# ---------------------------------------------------------------------------
# codex-wt.ps1: 引数の束縛
# ---------------------------------------------------------------------------

# 実際にラッパーを起動せず、param ブロックの束縛結果だけを取り出す。
function Get-Binding {
    param([string[]]$Arguments)
    $probe = Join-Path ([System.IO.Path]::GetTempPath()) "bind-$([guid]::NewGuid().ToString('N')).ps1"
    $header = (Get-Content -LiteralPath $wrapper -Raw) -replace '(?s)^(param\s*\(.*?\n\)).*', '$1'
    # $CodexArgs 未指定時は $null になるため、@() へ潰してから比較する
    # （@($null) は要素数 1 の配列になり、空と区別できない）。
    @"
$header
[pscustomobject]@{
    CodexArgs = @(`$CodexArgs | Where-Object { `$null -ne `$_ })
    ArgsFile  = `$InternalArgsFile
    StopFile  = `$InternalStopFile
    CurrentWindow = `$InternalCurrentWindow
} | ConvertTo-Json -Compress
"@ | Set-Content -LiteralPath $probe -Encoding utf8
    try {
        $json = & $pwshExe -NoProfile -File $probe @Arguments
        return ($json | ConvertFrom-Json)
    } finally {
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    }
}

# 位置引数が内部用の $InternalArgsFile に吸われ、codex に渡らないまま
# 「引数ファイルが見つかりません: resume」と警告が出ていた。
Test-Case 'cx resume --last: 位置引数が CodexArgs に入る' {
    $b = Get-Binding @('resume', '--last')
    ($b.CodexArgs -join ' ') -eq 'resume --last' -and -not $b.ArgsFile
}

Test-Case 'cx -s read-only: フラグが内部パラメータに吸われない' {
    $b = Get-Binding @('-s', 'read-only')
    ($b.CodexArgs -join ' ') -eq '-s read-only' -and -not $b.ArgsFile
}

Test-Case '引数なし: CodexArgs は空・内部パラメータも空' {
    $b = Get-Binding @()
    $b.CodexArgs.Count -eq 0 -and -not $b.ArgsFile -and -not $b.StopFile
}

Test-Case '内部の受け渡しは名前付きで束縛できる' {
    $b = Get-Binding @('-InternalArgsFile', 'C:\tmp\a.json', '-InternalStopFile', 'codex-1')
    $b.ArgsFile -eq 'C:\tmp\a.json' -and $b.StopFile -eq 'codex-1' -and $b.CodexArgs.Count -eq 0
}

Test-Case '現在のタブを使う内部指定は名前付きで束縛できる' {
    $b = Get-Binding @('-InternalCurrentWindow', '-s', 'read-only')
    $b.CurrentWindow -and ($b.CodexArgs -join ' ') -eq '-s read-only'
}

# ---------------------------------------------------------------------------
# codex-wt.ps1: 引数の受け渡し（wt.exe のパーサを通さないこと）
# ---------------------------------------------------------------------------

# wt.exe は ';' をサブコマンド区切りとして黙って切り捨てるため、
# 引数はコマンドラインではなく JSON ファイル経由で渡している。
Test-Case "';' を含む引数が JSON 往復で壊れない" {
    $original = @('-c', 'tui.status_line=[]', '--model', 'gpt-5;high', '--note', 'a b', '--q', 'has"quote')
    $file = Join-Path ([System.IO.Path]::GetTempPath()) "args-$([guid]::NewGuid().ToString('N')).json"
    try {
        ConvertTo-Json -InputObject @($original) -Depth 3 | Set-Content -LiteralPath $file -Encoding utf8
        $back = @(ConvertFrom-Json (Get-Content -LiteralPath $file -Raw))
        $back.Count -eq $original.Count -and (-not (Compare-Object $back $original -SyncWindow 0))
    } finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

Test-Case '空配列も JSON 往復できる（引数なし起動）' {
    $file = Join-Path ([System.IO.Path]::GetTempPath()) "args-$([guid]::NewGuid().ToString('N')).json"
    try {
        ConvertTo-Json -InputObject @(@()) -Depth 3 | Set-Content -LiteralPath $file -Encoding utf8
        $raw = Get-Content -LiteralPath $file -Raw
        @(ConvertFrom-Json $raw).Count -eq 0
    } finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# codex-wt.ps1: 窓の指定と終了コード
# ---------------------------------------------------------------------------

# 窓を作る wt 呼び出しの中で split-pane まで済ませる。あとから別プロセスで
# -w を使って窓を指し直すと、-w 0 が「直近に使われた窓」を指すため、codex と
# 無関係な窓にペインが出てしまう（実機で再現）。
Test-Case '新規ウィンドウ時は new-tab と split-pane を 1 回の wt 呼び出しで繋ぐ' {
    $text = Get-Content -LiteralPath $wrapper -Raw
    ($text -match "'new-tab'") -and ($text -match "'split-pane'") -and
    ($text -match "(?m)^\s*';'\s*$")
}

# 第 2 段は split-pane を一切呼ばない（呼ぶと窓を取り違える）。
Test-Case '現在のタブ用の split-pane は明示指定時だけ使う' {
    $text = Get-Content -LiteralPath $wrapper -Raw
    ($text -match 'if \(\$InternalCurrentWindow\) \{') -and
    ($text -match '& \$wt -w 0 split-pane')
}

# $env:WT_SESSION は「Windows Terminal の中にいる」ことしか示さないため、
# これを分岐条件にすると、既に開いているタブで cx を叩いただけで
# そこにステータスラインのペインが割り込んでいた。
Test-Case '再起動の判定は WT_SESSION ではなく StopFile で行う' {
    $text = Get-Content -LiteralPath $wrapper -Raw
    ($text -match '(?m)^if \(-not \$InternalStopFile\) \{') -and ($text -notmatch 'if \(-not \$env:WT_SESSION\)')
}

# 窓指定の '0' フォールバックが残っていると、codex と無関係な窓に
# ペインが出る症状が再発する。
Test-Case "窓指定の '0' は現在のタブ用のみに限定する" {
    $text = Get-Content -LiteralPath $wrapper -Raw
    ([regex]::Matches($text, '-w 0 split-pane')).Count -eq 1
}

# codex 起動が throw すると $exitCode が未代入のまま finally を抜け、
# $null が代入されて失敗が成功として伝播していた。
Test-Case '$exitCode は try の前に既定値を持つ' {
    $text = Get-Content -LiteralPath $wrapper -Raw
    $text -match '(?m)^\s*\$exitCode\s*=\s*1\s*$'
}

Test-Case 'codex.cmd は見つからなくても即死せずフォールバックする' {
    $text = Get-Content -LiteralPath $wrapper -Raw
    ($text -match 'Get-Command codex\.cmd[^\r\n]*SilentlyContinue') -and ($text -match 'npm\\codex\.cmd')
}

Test-Case 'codex-wt.ps1 が構文エラーを持たない' {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($wrapper, [ref]$null, [ref]$errors)
    -not $errors
}

# wt の -d に渡せるのは実在するファイルシステムのディレクトリだけ。
# レジストリや Env: などのプロバイダパスを渡すとタブ自体が起動できず、
# 「'codex' の起動時にエラー 2147942402 (0x80070002)」で失敗していた。
Test-Case 'cwd はファイルシステム以外の場所でも実在ディレクトリになる' {
    # ラッパーから cwd 決定ロジックだけを抜き出し、Env: ドライブ上で評価する。
    $source = Get-Content -LiteralPath $wrapper -Raw
    $match = [regex]::Match($source, '(?s)\$location = Get-Location.*?\nelse \{.*?\n\}')
    if (-not $match.Success) { throw 'cwd 決定ロジックが見つかりません' }
    $probe = Join-Path ([System.IO.Path]::GetTempPath()) "cwd-$([guid]::NewGuid().ToString('N')).ps1"
    @"
Set-Location Env:
$($match.Value)
`$cwd
"@ | Set-Content -LiteralPath $probe -Encoding utf8
    try {
        $result = (& $pwshExe -NoProfile -File $probe 2>&1 | Select-Object -Last 1 | Out-String).Trim()
        $result -and (Test-Path -LiteralPath $result -PathType Container)
    } finally {
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    }
}

# 第 1 段が組み立てる argv と同じ形で wt を起動し、上下**両方**のペインが
# 実際にプロセスを起こすことを見る。ファイル内容の照合だけでは、
# split-pane が黙って何も作らなくても pass してしまう（実際に取り逃した）。
Test-Case '1 回の wt 呼び出しで上下 2 つのペインが起動する' {
    $wtExe = (Get-Command wt.exe -ErrorAction SilentlyContinue).Source
    if (-not $wtExe) { throw 'wt.exe が無い' }
    $tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $top = Join-Path ([System.IO.Path]::GetTempPath()) "pane-top-$tag.txt"
    $bottom = Join-Path ([System.IO.Path]::GetTempPath()) "pane-bottom-$tag.txt"
    $argv = @(
        '-w', 'new'
        'new-tab', '-d', $env:TEMP, '--title', 'CodexSelfTest'
        $pwshExe, '-NoProfile', '-NoExit', '-Command', "'top' | Set-Content -LiteralPath '$top'; Start-Sleep 20"
        ';'
        'split-pane', '-H', '-s', '0.18', '-d', $env:TEMP, '--title', 'CodexSelfTest Status'
        $pwshExe, '-NoProfile', '-NoExit', '-Command', "'bottom' | Set-Content -LiteralPath '$bottom'; Start-Sleep 20"
    )
    & $wtExe @argv
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path -LiteralPath $top) -and (Test-Path -LiteralPath $bottom)) { break }
        Start-Sleep -Milliseconds 300
    }
    $both = (Test-Path -LiteralPath $top) -and (Test-Path -LiteralPath $bottom)
    Remove-Item -LiteralPath $top, $bottom -Force -ErrorAction SilentlyContinue
    $both
}

# ---------------------------------------------------------------------------
# codex_statusline.py: 表示幅の切り詰め
# ---------------------------------------------------------------------------

if (-not $python) {
    Write-Host 'skip  python.exe が無いため Python 側のテストを省略' -ForegroundColor Yellow
} else {
    Test-Case 'codex_statusline.py が構文エラーを持たない' {
        & $python -c "import ast,sys; ast.parse(open(sys.argv[1],encoding='utf-8').read())" $statusline
        $LASTEXITCODE -eq 0
    }

    # render() が ANSI カラーコードを含んだまま切り詰めており、
    # エスケープが幅の予算を食って値が途中で欠けていた。
    $pyTest = @'
import re, sys
sys.path.insert(0, sys.argv[1])
import codex_statusline as m

ANSI = re.compile(r"\x1b\[[0-9;]*m")
state = {
    "model": "gpt-5.6-terra", "effort": "high", "cwd": r"E:\waypoint", "mode": "default",
    "git": {"branch": "fix/quick-launch", "staged": 0, "modified": 0},
    "limits": {"primary": {"usedPercent": 23.0, "windowDurationMins": 300, "resetsAt": 1789830000}},
}
failures = []

# 幅 120 のペインで値が欠けないこと（"Thinking: high" が切られていた）
out = m.render(state, True, 119)
plain = ANSI.sub("", out)
if "Thinking: high" not in plain:
    failures.append("wide pane lost 'Thinking: high': %r" % plain.split("\n")[0])
if "Mode: default" not in plain:
    failures.append("wide pane lost mode line")

# どの幅でも可視文字が予算を超えないこと
for cols in (200, 120, 80, 60, 40, 20, 5, 1):
    for line in m.render(state, True, cols).split("\n"):
        visible = len(ANSI.sub("", line))
        if visible > cols:
            failures.append("overflow at cols=%d: visible=%d" % (cols, visible))

# 色ありと色なしで可視文字列が一致すること（= ANSI が幅を食っていない）
for cols in (119, 40):
    a = ANSI.sub("", m.render(state, True, cols))
    b = m.render(state, False, cols)
    if a != b:
        failures.append("colored/plain mismatch at cols=%d" % cols)

# 切り詰めても色が開きっぱなしにならないこと
tail = m.render(state, True, 12)
for line in tail.split("\n"):
    if ANSI.search(line) and not line.endswith("\x1b[0m"):
        failures.append("unterminated color: %r" % line)

print("FAILURES:" + "; ".join(failures) if failures else "OK")
'@
    $pyFile = Join-Path ([System.IO.Path]::GetTempPath()) "sltest-$([guid]::NewGuid().ToString('N')).py"
    $pyTest | Set-Content -LiteralPath $pyFile -Encoding utf8
    try {
        $result = & $python $pyFile $root 2>&1 | Out-String
        Test-Case 'render(): ANSI を除いた表示幅で切り詰める' {
            $result.Trim() -eq 'OK'
        }
        if ($result.Trim() -ne 'OK') {
            Write-Host "      $($result.Trim())" -ForegroundColor DarkGray
        }
    } finally {
        Remove-Item -LiteralPath $pyFile -Force -ErrorAction SilentlyContinue
    }

    # セッション検出が 5 秒間隔固定で、起動直後は Ctx Used / Mode が出なかった。
    $latencyTest = @'
import json, os, shutil, subprocess, sys, tempfile, threading, time
from pathlib import Path

root = sys.argv[1]
script = os.path.join(root, "codex_statusline.py")
tmp = Path(tempfile.mkdtemp())
home = tmp / "codexhome"
sessions = home / "sessions" / "2026" / "09" / "19"
sessions.mkdir(parents=True)
work = tmp / "work"
work.mkdir()
work = work.resolve()

env = dict(os.environ, CODEX_HOME=str(home))
proc = subprocess.Popen(
    [sys.executable, "-u", script, "--cwd", str(work), "--since", str(int(time.time()) - 1), "--interval", "0.5"],
    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env, encoding="utf-8")

lines = []
threading.Thread(target=lambda: [lines.append(l) for l in proc.stdout], daemon=True).start()

time.sleep(1.5)   # codex がセッションを書き出すまでの遅れを再現
with (sessions / "rollout-test.jsonl").open("w", encoding="utf-8") as fh:
    fh.write(json.dumps({"type": "session_meta", "payload": {"cwd": str(work)}}) + "\n")
    fh.write(json.dumps({"type": "turn_context", "payload": {
        "model": "gpt-5.6-terra", "effort": "high",
        "collaboration_mode": {"mode": "default"}}}) + "\n")
    fh.write(json.dumps({"type": "event_msg", "payload": {"type": "token_count", "info": {
        "last_token_usage": {"total_tokens": 5000}, "model_context_window": 100000}}}) + "\n")

created = time.time()
found = None
while time.time() - created < 4:
    if any("Mode: default" in l for l in lines):
        found = time.time() - created
        break
    time.sleep(0.1)

proc.terminate()
try:
    proc.wait(timeout=3)
except subprocess.TimeoutExpired:
    proc.kill()
shutil.rmtree(tmp, ignore_errors=True)

if found is None:
    print("FAILURES:session never detected within 4s")
elif found > 2.5:
    print("FAILURES:detection too slow: %.1fs" % found)
else:
    print("OK")
'@
    $latFile = Join-Path ([System.IO.Path]::GetTempPath()) "sllat-$([guid]::NewGuid().ToString('N')).py"
    $latencyTest | Set-Content -LiteralPath $latFile -Encoding utf8
    try {
        $result = & $python $latFile $root 2>&1 | Out-String
        Test-Case '起動後に現れたセッションを 2.5 秒以内に検出する' {
            $result.Trim() -eq 'OK'
        }
        if ($result.Trim() -ne 'OK') {
            Write-Host "      $($result.Trim())" -ForegroundColor DarkGray
        }
    } finally {
        Remove-Item -LiteralPath $latFile -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host "pass=$script:pass fail=$script:fail"
exit ([int]($script:fail -gt 0))
