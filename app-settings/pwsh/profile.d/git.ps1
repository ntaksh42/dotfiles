# ---------------------------------------------------------------------------
# §3 Git / GitHub
# ---------------------------------------------------------------------------

# Show git status in short format
function gs { git status -sb @args }

# Show git log with graph
function gl { git log --oneline --graph --decorate -20 @args }

# Undo last git commit (return to staging)
function git-undo { git reset --soft HEAD~1 }

function ga { git add @args }
function gaa { git add -A @args }
function gb { git branch @args }
function gd { git diff @args }
function gds { git diff --staged @args }
function gp { git push @args }
function gpf { git push --force-with-lease @args }

# stash shortcuts
function gsta { git stash push @args }
function gstp { git stash pop @args }
function gstl { git stash list @args }

# fetch/pull guarded against a Windows/NTFS gotcha: two refs differing only by
# case (e.g. branch "d" vs "D") share one loose-ref filename, so a plain fetch
# can silently clobber one with the other. Packing refs before/after moves
# them into packed-refs (a single text file, immune to filesystem case-folding).
function gf {
    git pack-refs --all
    git fetch --all --prune @args
    git pack-refs --all
}
# pull を止める「作業ツリー上の衝突」を、pull 前に .git/pull-backup/ へ退避して解消する。
#  1) core.ignorecase=true な NTFS では、リモートの Foo.cs とローカルの foo.cs が
#     同一パスに解決されるため "would be overwritten by merge" で止まる (大文字小文字違い)。
#  2) 未追跡のローカルファイルが upstream の同名ファイルと衝突しても止まる (同一パス)。
# 削除ではなく退避なのは、ローカル側に未コミットの中身が残る場合があるため。
# (追跡ファイルの未コミット変更は gpl 側で stash して扱う)
function Resolve-GitPullCollision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Upstream,
        # rebase は index/作業ツリーの差分があると開始できないため、追跡ファイルは触らない
        [switch]$UntrackedOnly
    )

    # quotepath=false: 非 ASCII のパスが "\346\227..." とエスケープされるのを防ぐ
    $remote = @{}
    foreach ($path in (git -c core.quotepath=false ls-tree -r --name-only $Upstream)) {
        if ($path) { $remote[$path.ToLowerInvariant()] = $path }
    }
    # upstream 側のディレクトリ (全ての親パス)。未追跡ファイルとの「ファイル vs ディレクトリ」衝突判定用。
    $remoteDirs = @{}
    foreach ($key in $remote.Keys) {
        for ($i = $key.IndexOf('/'); $i -ge 0; $i = $key.IndexOf('/', $i + 1)) {
            $remoteDirs[$key.Substring(0, $i)] = $true
        }
    }
    Assert-NativeCommandSucceeded "git ls-tree $Upstream"
    if ($remote.Count -eq 0) { return }

    $tracked = if ($UntrackedOnly) { @() } else { @(git -c core.quotepath=false ls-files) | Where-Object { $_ } }
    $untracked = @(git -c core.quotepath=false ls-files --others --exclude-standard) | Where-Object { $_ }
    $candidates = @(
        $tracked | ForEach-Object { @{ Path = $_; Tracked = $true } }
        $untracked | ForEach-Object { @{ Path = $_; Tracked = $false } }
    )

    $backupDir = $null
    foreach ($c in $candidates) {
        $path = $c.Path
        $lower = $path.ToLowerInvariant()
        $match = $remote[$lower]
        if (-not $match -and -not $c.Tracked) {
            # 未追跡ファイル <-> upstream ディレクトリ (foo vs foo/x)、またはその逆 (foo/x vs foo)
            $isDir = $remoteDirs.ContainsKey($lower)
            $underFile = $false
            for ($i = $lower.IndexOf('/'); $i -ge 0; $i = $lower.IndexOf('/', $i + 1)) {
                if ($remote.ContainsKey($lower.Substring(0, $i))) { $underFile = $true; break }
            }
            if ($isDir -or $underFile) { $match = $path }
        }
        if (-not $match) { continue }
        # 追跡ファイルは大文字小文字違いのときだけ衝突。未追跡は同一パスでも衝突する。
        if ($c.Tracked -and $match -ceq $path) { continue }

        if (-not $backupDir) {
            $gitDir = (git rev-parse --absolute-git-dir).Trim()
            $backupDir = Join-Path $gitDir ('pull-backup\{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        }
        $src = Join-Path (git rev-parse --show-toplevel).Trim() ($path -replace '/', '\')
        # skip-worktree / sparse-checkout の追跡ファイルは作業ツリーに実体が無い
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }
        $dest = Join-Path $backupDir ($path -replace '/', '\')
        try {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) -ErrorAction Stop | Out-Null
            Move-Item -LiteralPath $src -Destination $dest -Force -ErrorAction Stop
        } catch {
            # エディタ等がファイルをロックしている。退避せず続行し、衝突すれば pull 側のエラーで分かる。
            Write-Warning "退避に失敗 ($path): $($_.Exception.Message)"
            continue
        }
        # 追跡ファイルなら、退避で消えた分をインデックスからも落として pull を通す。
        if ($c.Tracked) {
            git rm --cached --quiet -- $path 2>$null
            if ($LASTEXITCODE -ne 0) { Write-Warning "git rm --cached に失敗: $path" }
        }
        $why = if ($c.Tracked) { "大文字小文字違い ($match)" } else { '未追跡ファイルが upstream と衝突' }
        Write-Host "  [退避] $path : $why -> $dest" -ForegroundColor Yellow
    }
}

# git pull の安全版。未コミット変更を stash → 衝突ファイルを退避 → pull → stash 復元。
# 引数は git pull にそのまま渡る (例: gpl --rebase)。
# (--autostash を使わないのは、大文字小文字衝突の退避 (git rm --cached) が stash に
#  巻き込まれ、復元時に競合するため)
function gpl {
    # pack-refs は最適化なので、他プロセス (IDE の自動 fetch 等) と packed-refs.lock が競合しても止めない
    git pack-refs --all 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Warning 'gpl: git pack-refs をスキップ (他の git プロセスがロック中の可能性)' }

    # 衝突判定には fetch 済みの upstream が要る。pull 前に取得しておく。
    Write-Host '[gpl] fetch' -ForegroundColor Cyan
    git fetch --prune --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host '[gpl] fetch 失敗: 上のエラーを確認 (ネットワーク・認証・他の git プロセスのロック)' -ForegroundColor Red
        return
    }
    $upstream = (git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null)
    $hasUpstream = ($LASTEXITCODE -eq 0 -and $upstream)
    if (-not $hasUpstream -and $args.Count -eq 0) {
        Write-Warning 'gpl: upstream 未設定。git branch -u origin/<branch> で設定するか、gpl origin <branch> と指定する'
        return
    }

    $stashed = $false
    if (git status --porcelain --untracked-files=no) {
        Write-Host '[gpl] 未コミット変更を stash' -ForegroundColor Cyan
        # サブモジュール内の変更だけだと stash は何も作らず成功する。その場合に古い stash を pop しないよう、
        # stash の先頭が変わったかで判定する。
        $before = git rev-parse -q --verify refs/stash 2>$null
        git stash push --quiet -m 'gpl: auto stash before pull'
        if ($LASTEXITCODE -ne 0) {
            Write-Host '[gpl] stash 失敗: 上のエラーを確認' -ForegroundColor Red
            return
        }
        $stashed = (git rev-parse -q --verify refs/stash 2>$null) -ne $before
    }
    # rebase モードか (引数が pull.rebase 設定より優先)。大文字小文字だけの改名は git が rebase でも処理できる。
    $rebase = (git config --get pull.rebase) -notin @($null, '', 'false')
    foreach ($a in $args) {
        if ($a -in '--no-rebase', '--rebase=false') { $rebase = $false }
        elseif ($a -match '^(-r|--rebase(=.+)?)$') { $rebase = $true }
    }
    $stashHint = if ($stashed) { '。未コミット変更は stash に残っている (git stash pop で復元)' } else { '' }
    if ($hasUpstream) {
        try {
            Resolve-GitPullCollision -Upstream $upstream.Trim() -UntrackedOnly:$rebase
        } catch {
            Write-Host "[gpl] 衝突ファイルの退避に失敗: $($_.Exception.Message)$stashHint" -ForegroundColor Red
            return
        }
    }

    Write-Host '[gpl] pull' -ForegroundColor Cyan
    git pull @args
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[gpl] pull 失敗: 上のエラーを確認。マージ競合ならファイル修正後 git add / git commit、中止は git merge --abort$stashHint" -ForegroundColor Red
        return
    }
    if ($stashed) {
        Write-Host '[gpl] stash を復元' -ForegroundColor Cyan
        git stash pop --quiet
        if ($LASTEXITCODE -ne 0) {
            Write-Host '[gpl] stash の復元で競合。解消後 git stash drop' -ForegroundColor Red
            return
        }
    }
    git pack-refs --all 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Warning 'gpl: git pack-refs をスキップ (他の git プロセスがロック中の可能性)' }
}

# Commit with a message (message required)
function gcm {
    if ($args.Count -eq 0) { Write-Warning 'usage: gcm <message>'; return }
    git commit -m "$args"
}

# Checkout; no arg -> fzf branch picker
function gco {
    if ($args.Count -gt 0) { git checkout @args; return }
    git-switch
}

# These wrappers do not need an eager command lookup. If a tool is missing,
# PowerShell's normal command-not-found message is sufficient on first use.
function lg { lazygit @args }
function prc { gh pr create @args }
function prv { gh pr view --web @args }
function prl { gh pr list @args }
function prs { gh pr status @args }

# cd to the git repository root
function groot {
    $root = git rev-parse --show-toplevel 2>$null
    if ($root) { Set-Location $root } else { Write-Warning 'Not a git repository' }
}

# Clone a repo and cd into it
function gclone {
    param([Parameter(Mandatory)][string]$Url)
    git clone $Url
    if ($LASTEXITCODE -eq 0) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension(($Url.TrimEnd('/')))
        if ($name -and (Test-Path $name)) { Set-Location $name }
    }
}

# Interactively browse commits (fzf list + diff preview via delta when available)
function glog {
    if (-not (Test-Cmd fzf)) { Write-Warning 'glog needs fzf'; return }
    $preview = if (Test-Cmd delta) { 'git show --color=always {1} | delta' }
    else { 'git show --color=always {1}' }
    git log --color=always --format='%C(auto)%h %s %C(dim)%an, %ar' @args |
    fzf --ansi --no-sort --reverse --preview $preview
}

# gita wrapper: clean each repo's stray "nul" file, then pull every repo.
# A repo whose current branch has no origin upstream is switched to -Fallback first.
function clean-pull-all {
    [CmdletBinding()]
    param([string]$Fallback = 'main')

    if (-not (Test-Cmd gita)) { Write-Warning 'clean-pull-all needs gita (gita add <path> to register repos)'; return }

    $names = @(((gita ls) -join ' ') -split '\s+' | Where-Object { $_ })
    if ($names.Count -eq 0) { Write-Warning 'No repos registered in gita (use: gita add <path>)'; return }

    foreach ($name in $names) {
        $repo = (gita ls $name).Trim()
        Write-Host "[$name] " -ForegroundColor Cyan -NoNewline
        if (-not $repo -or -not (Test-Path -LiteralPath $repo)) { Write-Warning "path not found: $repo"; continue }
        Write-Host $repo -ForegroundColor DarkGray

        # 1) Remove Windows-reserved "nul" files (block git checkout/pull on Windows).
        $stray = @(
            git -C $repo ls-files
            git -C $repo ls-files --others --exclude-standard
        ) | Where-Object { $_ -match '(^|/)nul$' } | Sort-Object -Unique
        foreach ($rel in $stray) {
            $full = Join-Path $repo ($rel -replace '/', '\')
            Remove-Item -LiteralPath "\\?\$full" -Force -ErrorAction SilentlyContinue
            Write-Host "  removed stray file: $rel" -ForegroundColor Yellow
        }

        # 2) Fetch, then pull the current branch; fall back if it has no origin upstream.
        git -C $repo fetch --prune --quiet
        $branch = (git -C $repo rev-parse --abbrev-ref HEAD).Trim()
        git -C $repo rev-parse --verify --quiet "origin/$branch" *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  no origin/$branch -> switching to $Fallback" -ForegroundColor Yellow
            git -C $repo checkout $Fallback
            if ($LASTEXITCODE -ne 0) { Write-Warning "  checkout $Fallback failed"; continue }
        }
        git -C $repo pull --ff-only
    }
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
function git-nuke {
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

# このディレクトリと直下のサブディレクトリにある git リポジトリを gita に登録。
function gita-scan {
    param([string]$Path = '.')
    if (-not (Test-Cmd gita)) { Write-Warning 'gita-scan needs gita'; return }
    $root = (Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue).Path
    if (-not $root) { Write-Warning "Path not found: $Path"; return }

    $targets = @()
    if (Test-Path -LiteralPath (Join-Path $root '.git')) { $targets += $root }
    $targets += @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.git') } |
        Select-Object -ExpandProperty FullName)

    if ($targets.Count -eq 0) { Write-Host 'No git repos found (this dir and its direct subdirs).' -ForegroundColor Yellow; return }
    foreach ($t in $targets) { gita add $t }
    Write-Host "Registered $($targets.Count) repo(s) with gita." -ForegroundColor Green
}

