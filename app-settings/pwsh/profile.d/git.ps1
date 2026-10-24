# ---------------------------------------------------------------------------
# §3 Git / GitHub
# ---------------------------------------------------------------------------
# git をそのまま呼ぶだけの短縮名はここには置かない。app-settings\git\.gitconfig の
# [alias] 側に寄せてあるので `g s` / `g co` / `g cm <msg>` のように打つ (一覧は git-help)。
# ここに残すのは cd する・fzf で選ぶ・実行前に確認を取る・複数リポジトリをまとめる、
# といった git alias では書けないものだけ。

# Show git log with graph
function gl { git log --oneline --graph --decorate -20 @args }

# These wrappers do not need an eager command lookup. If a tool is missing,
# PowerShell's normal command-not-found message is sufficient on first use.
function lg { lazygit @args }
function prc { gh pr create @args }
function prv { gh pr view --web @args }
function prl { gh pr list @args }
function prs { gh pr status @args }

# cd to the git repository root
function git-root {
    $root = git rev-parse --show-toplevel 2>$null
    if ($root) { Set-Location $root } else { Write-Warning 'Not a git repository' }
}

# Clone a repo and cd into it
function git-clone {
    param([Parameter(Mandatory)][string]$Url)
    git clone $Url
    if ($LASTEXITCODE -eq 0) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension(($Url.TrimEnd('/')))
        if ($name -and (Test-Path $name)) { Set-Location $name }
    }
}

# Interactively browse commits (fzf list + diff preview via delta when available)
function git-log-browse {
    if (-not (Test-Cmd fzf)) { Write-Warning 'git-log-browse needs fzf'; return }
    $preview = if (Test-Cmd delta) { 'git show --color=always {1} | delta' }
    else { 'git show --color=always {1}' }
    git log --color=always --format='%C(auto)%h %s %C(dim)%an, %ar' @args |
    fzf --ansi --no-sort --reverse --preview $preview
}

# fzf でブランチを選んで切替。ローカルに無ければ origin から作成して追跡。
function git-switch {
    if (-not (Test-Cmd fzf)) { Write-Warning 'git-switch needs fzf'; return }
    $sel = git branch --all --format='%(refname:short)' |
    Where-Object { $_ -and $_ -notmatch '/HEAD$' } |
    Sort-Object -Unique | fzf
    if (-not $sel) { return }
    $local = $sel.Trim() -replace '^origin/', ''
    git rev-parse --verify --quiet "refs/heads/$local" *> $null
    if ($LASTEXITCODE -eq 0) { git checkout $local }
    else { git checkout -b $local --track "origin/$local" }
}

# 現在ブランチへマージ済みのローカルブランチを一括削除 (保護ブランチは残す)。
function git-clean-branches {
    param([string[]]$Protected = @('main', 'master', 'develop'))
    $cur = (git rev-parse --abbrev-ref HEAD).Trim()
    $merged = @(git branch --merged |
        ForEach-Object { ($_ -replace '^[*+ ]+', '').Trim() } |
        Where-Object { $_ -and $_ -ne $cur -and $_ -notin $Protected })
    if ($merged.Count -eq 0) { Write-Host 'No merged branches to delete.' -ForegroundColor Green; return }
    Write-Host 'Merged branches to delete:' -ForegroundColor Cyan
    $merged | ForEach-Object { Write-Host "  $_" }
    if ((Read-Host 'Proceed? (y/N)') -notmatch '^(y|yes)$') { Write-Host 'Aborted.'; return }
    $merged | ForEach-Object { git branch -d $_ }
}

# ローカルを完全にきれいな状態へ戻す: 追跡ファイルの変更を破棄し (reset --hard)、
# 未追跡・.gitignore 対象のファイル/ディレクトリも削除する (clean -ffdx)。
# 削除対象をプレビューして確認を取ってから実行 (-Force で確認省略)。
function git-reset-clean {
    [CmdletBinding()]
    param(
        [string]$Ref = 'HEAD',
        [switch]$Force
    )
    $dirty = git status --porcelain
    $toClean = @(git clean -ffdxn)
    if (-not $dirty -and $toClean.Count -eq 0) {
        Write-Host 'Already clean.' -ForegroundColor Green
        return
    }

    Write-Host "This will 'git reset --hard $Ref' and remove:" -ForegroundColor Cyan
    $toClean | ForEach-Object { Write-Host "  $_" }
    if (-not $Force) {
        if ((Read-Host 'Proceed? (y/N)') -notmatch '^(y|yes)$') { Write-Host 'Aborted.'; return }
    }

    git reset --hard $Ref
    Assert-NativeCommandSucceeded "git reset --hard $Ref"
    git clean -ffdx
    Assert-NativeCommandSucceeded 'git clean -ffdx'
}
