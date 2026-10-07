# ---------------------------------------------------------------------------
# §6 AI CLI launchers (Claude Code / Codex)
# ---------------------------------------------------------------------------

# 司令塔/実行を分離して claude 起動: 立案・俯瞰は上位モデル、実行はサブエージェント
function script:Invoke-ClaudeOrchest {
    param(
        [Parameter(Mandatory)][string]$MainModel,
        [Parameter(Mandatory)][string]$SubagentModel,
        [object[]]$Rest
    )
    $prev = $env:CLAUDE_CODE_SUBAGENT_MODEL
    $env:CLAUDE_CODE_SUBAGENT_MODEL = $SubagentModel
    try {
        claude --model $MainModel @Rest
    }
    finally {
        if ($null -ne $prev) { $env:CLAUDE_CODE_SUBAGENT_MODEL = $prev }
        else { Remove-Item Env:CLAUDE_CODE_SUBAGENT_MODEL -ErrorAction Ignore }
    }
}
function fable-orchest { Invoke-ClaudeOrchest 'claude-fable-5'  'claude-sonnet-5' $args }
function fable-orchest-opus { Invoke-ClaudeOrchest 'claude-fable-5'  'claude-opus-5-5' $args }
function opus-orchest { Invoke-ClaudeOrchest 'claude-opus-5-5'   'claude-sonnet-5' $args }
function fable-orchest-plan { Invoke-ClaudeOrchest 'claude-fable-5'  'claude-sonnet-5' (@('--permission-mode', 'plan') + $args) }
Set-Alias ccf  fable-orchest
Set-Alias ccfo fable-orchest-opus
Set-Alias cco  opus-orchest
Set-Alias ccfp fable-orchest-plan

# claude 起動の既定コマンド（Opus 5.5、司令塔プロンプトなし）。ccop は互換用エイリアス。
function cc { claude --model claude-opus-5-5 @args }
Set-Alias ccop cc
function ccp { claude --model claude-opus-5-5 --permission-mode plan @args }

# Sonnet 5 で claude 起動（軽作業向け）
function ccs { claude --model claude-sonnet-5 @args }

# 直近の会話を継続 / セッションを選んで再開
function ccc { claude --continue @args }
function ccr { claude --resume @args }

# --- codex ---
# 既定は ~/.codex/config.toml (on-request / workspace-write)。
# 以下は安全度と推論強度を起動時に切り替えるためのプリセット。
function codex {
    $nativeOnly = @('exec', 'review', 'cloud', 'mcp', 'completion', 'login', 'logout', 'features', 'app-server')
    $firstArg = if ($args.Count -gt 0) { [string]$args[0] } else { '' }
    $nativeCodex = (Get-Command codex.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $nativeCodex) { $nativeCodex = Join-Path $env:APPDATA 'npm\codex.cmd' }
    $wrapper = Join-Path $env:LOCALAPPDATA 'CodexStatusline\codex-wt.ps1'
    if ($firstArg -in $nativeOnly -or $firstArg -in @('--help', '-h', '--version', '-V') -or -not (Test-Path -LiteralPath $wrapper)) {
        & $nativeCodex @args
        return
    }
    if ($env:WT_SESSION) {
        & $wrapper -InternalCurrentWindow @args
        return
    }
    & $wrapper @args
}
function cxr{ codex -s read-only -a untrusted @args }
function cxa { codex -a never -s workspace-write @args }
function cxh { codex -c model_reasoning_effort="high" @args }
function cxrev { codex review @args }

# 直近セッションを継続 / セッションを選んで再開
function cxc { codex resume --last @args }
function cxs { codex resume @args }

# サンドボックスを外す。承認は残るので実行前に必ず目視が入る。
function cxfa { codex -s danger-full-access @args }

# 承認もサンドボックスも無効化する。取り消しの効かない操作がそのまま通る。
function cxyolo {
    codex --dangerously-bypass-approvals-and-sandbox @args
}

