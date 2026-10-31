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

# fzf で現在のリポジトリの worktree を選んで移動する。
function git-worktree-switch {
    if (-not (Test-Cmd fzf)) { Write-Warning 'git-worktree-switch needs fzf'; return }
    $raw = @(git worktree list --porcelain -z 2>$null)
    if ($LASTEXITCODE -ne 0) { Write-Warning 'git worktree list failed (run inside a git repository)'; return }

    $rows = @(foreach ($record in (($raw -join "`n") -split "`0`0")) {
        if (-not $record) { continue }
        $fields = $record -split "`0"
        $path = $fields[0] -replace '^worktree ', ''
        if ($fields -contains 'bare' -or $fields -match '^prunable(?: |$)' -or
            -not (Test-Path -LiteralPath $path -PathType Container)) { continue }
        $branch = ($fields | Where-Object { $_.StartsWith('branch ') }) -replace '^branch refs/heads/', ''
        if ($fields -contains 'detached') { $branch = '(detached)' }
        "$path`t$branch"
    })
    if ($rows.Count -eq 0) { Write-Warning 'No accessible worktrees'; return }
    $sel = $rows | fzf --delimiter "`t" --with-nth '2,1' --no-sort --prompt 'worktree> '
    if ($sel) { Set-Location -LiteralPath (($sel -split "`t", 2)[0]) }
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
# 未追跡・.gitignore 対象のファイル/ディレクトリも削除する (clean -ffdx)。確認はしない。
# git clean はカレントディレクトリ以下しか消さないので、サブディレクトリから実行してもリポジトリのルートで動かす。
# git clean が消せないもの (Windows の予約名 nul 等、長すぎるパス) は \\?\ パスで消し直す。
function git-reset-clean {
    [CmdletBinding()]
    param([string]$Ref = 'HEAD')

    $top = "$(git rev-parse --show-toplevel)".Trim()
    Assert-NativeCommandSucceeded 'git rev-parse --show-toplevel'
    $dirty = git -C $top status --porcelain
    $toClean = @(Get-GitCleanPreview $top)
    if (-not $dirty -and $toClean.Count -eq 0) {
        Write-Host 'Already clean.' -ForegroundColor Green
        return
    }

    Write-Host "git reset --hard $Ref, then removing $($toClean.Count) untracked/ignored item(s):" -ForegroundColor Cyan
    $toClean | ForEach-Object { Write-Host "  $_" }

    git -C $top reset --hard $Ref
    Assert-NativeCommandSucceeded "git reset --hard $Ref"
    git -C $top clean -ffdx
    Assert-NativeCommandSucceeded 'git clean -ffdx'

    foreach ($rel in @(Get-GitCleanPreview $top)) {
        $full = (Join-Path $top $rel.TrimEnd('/')) -replace '/', '\'
        Remove-Item -LiteralPath "\\?\$full" -Recurse -Force -ErrorAction SilentlyContinue
    }
    $left = @(Get-GitCleanPreview $top)
    if ($left.Count -gt 0) { Write-Warning "Could not remove (in use by another process?): $($left -join ', ')" }
}

# git clean -ffdx が消す予定のパス (リポジトリのルートからの相対) を返す。
# "Would refuse to remove current working directory" (シェルがいる未追跡ディレクトリ) は消せないので含めない。
function Get-GitCleanPreview([string]$Top) {
    git -C $Top -c core.quotepath=false clean -ffdxn | Where-Object { "$_".StartsWith('Would remove ') } |
        ForEach-Object { "$_".Substring('Would remove '.Length) }
}
