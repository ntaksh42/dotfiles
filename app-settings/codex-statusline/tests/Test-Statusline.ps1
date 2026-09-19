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
    ArgsFile  = `$ArgsFile
    WindowId  = `$WindowId
} | ConvertTo-Json -Compress
"@ | Set-Content -LiteralPath $probe -Encoding utf8
    try {
        $json = & $pwshExe -NoProfile -File $probe @Arguments
        return ($json | ConvertFrom-Json)
    } finally {
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    }
}

# 位置引数が内部用の $ArgsFile に吸われ、codex に渡らないまま
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
    $b.CodexArgs.Count -eq 0 -and -not $b.ArgsFile -and -not $b.WindowId
}

Test-Case '内部の受け渡しは名前付きで束縛できる' {
    $b = Get-Binding @('-ArgsFile', 'C:\tmp\a.json', '-WindowId', 'codex-1')
    $b.ArgsFile -eq 'C:\tmp\a.json' -and $b.WindowId -eq 'codex-1' -and $b.CodexArgs.Count -eq 0
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

# -w 0 は「直近に使われた窓」であり -w new で作った窓とは限らないため、
# ステータスラインが別の Terminal 窓に割り込むことがあった。
Test-Case '窓は -w 0 ではなく採番した名前で指定する' {
    $text = Get-Content -LiteralPath $wrapper -Raw
    ($text -notmatch '-w\s+0\s+split-pane') -and ($text -match '\$windowName\s*=') -and ($text -match '-w\s+\$WindowId\s+split-pane')
}

# $env:WT_SESSION は「Windows Terminal の中にいる」ことしか示さないため、
# これを分岐条件にすると、既に開いているタブで cx を叩いただけで
# そこにステータスラインのペインが割り込んでいた。
Test-Case '再起動の判定は WT_SESSION ではなく WindowId で行う' {
    $text = Get-Content -LiteralPath $wrapper -Raw
    ($text -match '(?m)^if \(-not \$WindowId\) \{') -and ($text -notmatch 'if \(-not \$env:WT_SESSION\)')
}

# WindowId が無い経路で split-pane に到達すると症状が再発するため、
# '0' へのフォールバックが残っていないことを固定する。
Test-Case "窓指定に '0' フォールバックが残っていない" {
    (Get-Content -LiteralPath $wrapper -Raw) -notmatch "else\s*\{\s*'0'\s*\}"
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
