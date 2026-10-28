# ---------------------------------------------------------------------------
# §3b Git pull / fetch (大文字小文字衝突・NTFS 対策)
# ---------------------------------------------------------------------------

# fetch/pull guarded against a Windows/NTFS gotcha: two refs differing only by
# case (e.g. branch "d" vs "D") share one loose-ref filename, so a plain fetch
# can silently clobber one with the other. Packing refs before/after moves
# them into packed-refs (a single text file, immune to filesystem case-folding).
#
# ただしリモートに feature/Foo と feature/foo のような大文字小文字だけ違うブランチが両方あると、files 形式の
# ref では片方を保存できない。Git 2.5x はこれを検出し、ほかの ref を更新したうえで fetch を失敗 (exit 1) にする。
# この失敗だけなら警告にとどめて成功扱いにする。git が出す長い移行案内は 1 行の警告に置き換える。
function Invoke-GitFetch {
    $out = @(git fetch @args 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $collision = $code -ne 0 -and ($out -match 'only differ in casing')
    $inAdvice = $false
    foreach ($line in $out) {
        if ($collision -and $line -match "^error: You're on a case-insensitive filesystem") { $inAdvice = $true }
        if (-not $inAdvice -and $line.Trim()) { Write-Host $line }
        elseif ($line -match 'migrate to reftables\.$') { $inAdvice = $false }
    }
    if ($collision) {
        Write-Warning 'fetch: 大文字小文字だけ違うリモートブランチがあり、片方は取得できない。ほかは取得済みなので続行する (根本対策: git refs migrate --ref-format=reftable)'
        $code = 0
    }
    $global:LASTEXITCODE = $code
}

function git-fetch {
    git pack-refs --all
    Invoke-GitFetch --all --prune @args
    git pack-refs --all
}

Set-Alias gf git-fetch
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
function git-pull {
    # pack-refs は最適化なので、他プロセス (IDE の自動 fetch 等) と packed-refs.lock が競合しても止めない
    git pack-refs --all 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Warning 'gpl: git pack-refs をスキップ (他の git プロセスがロック中の可能性)' }

    # 衝突判定には fetch 済みの upstream が要る。pull 前に取得しておく。
    Write-Host '[gpl] fetch' -ForegroundColor Cyan
    Invoke-GitFetch --prune --quiet
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

    # 引数無しの git pull は中でリモートの全ブランチを fetch し直し、上の大文字小文字衝突で失敗する。
    # リポジトリとブランチの指定が無ければ upstream を明示して、取得をそのブランチだけに絞る。
    $pullArgs = @($args)
    if ($hasUpstream -and -not ($args | Where-Object { $_ -notlike '-*' })) {
        $branch = git symbolic-ref --short -q HEAD
        $remote = git config --get "branch.$branch.remote"
        $merge = git config --get "branch.$branch.merge"
        if ($remote -and $merge) { $pullArgs += @($remote, $merge) }
    }
    Write-Host '[gpl] pull' -ForegroundColor Cyan
    git pull @pullArgs
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

Set-Alias gpl git-pull
