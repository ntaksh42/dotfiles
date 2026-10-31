# ---------------------------------------------------------------------------
# §3c gita (複数リポジトリ管理)
# ---------------------------------------------------------------------------

# gita reads git output with the locale codec (cp932), which fails on UTF-8 commit messages
# (gita ll -> UnicodeDecodeError). Python's UTF-8 mode fixes that.
$env:PYTHONUTF8 = '1'

# gita wrapper: clean each repo's stray "nul" file, then pull every repo.
# A repo whose current branch has no origin upstream (or a detached HEAD) is switched to -Fallback first.
# Failed repos are listed at the end so a broken one does not scroll by unnoticed.
function gita-pull-all {
    [CmdletBinding()]
    param([string]$Fallback = 'main')

    if (-not (Test-Cmd gita)) { Write-Warning 'gita-pull-all needs gita (gita add <path> to register repos)'; return }

    $names = @(((gita ls) -join ' ') -split '\s+' | Where-Object { $_ })
    if ($names.Count -eq 0) { Write-Warning 'No repos registered in gita (use: gita add <path>)'; return }

    $failed = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $names) {
        $repo = (gita ls $name).Trim()
        Write-Host "[$name] " -ForegroundColor Cyan -NoNewline
        if (-not $repo -or -not (Test-Path -LiteralPath $repo)) { Write-Warning "path not found: $repo"; $failed.Add("$name (path not found)"); continue }
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
        if ($LASTEXITCODE -ne 0) { Write-Warning '  fetch failed'; $failed.Add("$name (fetch)"); continue }
        $branch = "$(git -C $repo rev-parse --abbrev-ref HEAD)".Trim()
        if ($LASTEXITCODE -ne 0) { Write-Warning '  cannot read HEAD'; $failed.Add("$name (HEAD)"); continue }
        $hasOrigin = $false
        if ($branch -ne 'HEAD') {
            git -C $repo rev-parse --verify --quiet "origin/$branch" *> $null
            $hasOrigin = $LASTEXITCODE -eq 0
        }
        if (-not $hasOrigin) {
            $label = if ($branch -eq 'HEAD') { 'detached HEAD' } else { "no origin/$branch" }
            Write-Host "  $label -> switching to $Fallback" -ForegroundColor Yellow
            git -C $repo checkout $Fallback
            if ($LASTEXITCODE -ne 0) { Write-Warning "  checkout $Fallback failed"; $failed.Add("$name (checkout $Fallback)"); continue }
        }
        git -C $repo pull --ff-only
        if ($LASTEXITCODE -ne 0) { Write-Warning '  pull failed'; $failed.Add("$name (pull)") }
    }

    if ($failed.Count -gt 0) {
        Write-Warning "$($failed.Count) of $($names.Count) repo(s) failed: $($failed -join ', '). gita-doctor looks for broken repos."
    }
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

# gita の登録 (repos.csv) を点検する。2 種類の問題を探す:
#  - 登録の問題: フォルダがない / 名前が空 / git リポジトリでない。gita はこれらを黙って無視するか誤動作する。
#    一覧を出し、確認のうえ削除する (元のファイルは .bak に残す)。名前が空の行は gita rm で消せないため直接編集する。
#  - リポジトリの破損: git status が失敗する (index 破損、空のオブジェクト、壊れた ref、dubious ownership 等)、
#    不正な HEAD、.lock ファイルの残骸、途中で止まった merge / rebase。登録は消さず、直し方を表示する。
# -Deep を付けると git fsck で全オブジェクトも検査する (遅い)。
function gita-doctor {
    param(
        [string]$Path = (Join-Path $HOME '.config\gita\repos.csv'),
        [switch]$Deep
    )
    if (-not (Test-Path -LiteralPath $Path)) { Write-Warning "gita registry not found: $Path"; return }

    $lines = @(Get-Content -LiteralPath $Path | Where-Object { $_.Trim() })
    $bad = [System.Collections.Generic.List[object]]::new()
    $broken = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $lines) {
        # gita writes the file with Python's csv module, which quotes a path containing a comma.
        $entry = $line | ConvertFrom-Csv -Header path, name, type, flags
        $repo = "$($entry.path)"; $name = "$($entry.name)"
        $reason = if (-not $repo -or -not (Test-Path -LiteralPath $repo)) { 'folder not found' }
        elseif (-not $name) { 'empty name' }
        elseif (-not (Test-Path -LiteralPath (Join-Path $repo '.git')) -and
            "$(git -C $repo rev-parse --is-bare-repository 2>$null)".Trim() -ne 'true') { 'not a git repository' }
        if ($reason) { $bad.Add([pscustomobject]@{ Name = $name; Path = $repo; Reason = $reason; Line = $line }); continue }

        foreach ($issue in @(Get-GitaRepoIssue -Repo $repo -Deep:$Deep)) {
            $broken.Add([pscustomobject]@{ Name = $name; Path = $repo; Issue = $issue.Issue; Fix = $issue.Fix })
        }
    }

    if ($bad.Count -eq 0 -and $broken.Count -eq 0) { Write-Host "No problems in $($lines.Count) gita entries." -ForegroundColor Green; return }

    if ($broken.Count -gt 0) {
        Write-Host 'Broken repos (gita commands fail on these; fix by hand):' -ForegroundColor Red
        foreach ($b in $broken) {
            Write-Host ("  {0,-12} {1}" -f $b.Name, $b.Path) -ForegroundColor Yellow
            Write-Host "    $($b.Issue)"
            if ($b.Fix) { Write-Host "    fix: $($b.Fix)" -ForegroundColor DarkGray }
        }
    }
    if ($bad.Count -eq 0) { return }

    Write-Host 'Bad registry entries:' -ForegroundColor Red
    foreach ($b in $bad) { Write-Host ("  {0,-22} {1,-12} {2}" -f $b.Reason, $b.Name, $b.Path) -ForegroundColor Yellow }
    if ((Read-Host "Remove these $($bad.Count) entries? (y/N)") -notmatch '^(y|yes)$') { Write-Host 'Aborted.'; return }

    Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force
    Set-Content -LiteralPath $Path -Value @($lines | Where-Object { $_ -notin $bad.Line }) -Encoding utf8NoBOM
    Write-Host "Removed $($bad.Count) entries (backup: $Path.bak)." -ForegroundColor Green
}

# gita-doctor の下請け: 1 つのリポジトリの破損を調べ、@{ Issue; Fix } を問題ごとに返す。
function Get-GitaRepoIssue {
    param([string]$Repo, [switch]$Deep)

    # git status reads HEAD, the index and the objects of the checked-out tree, so it fails on most corruption.
    $out = @(git -C $Repo status --porcelain 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
        $msg = Get-GitErrorLine $out $LASTEXITCODE
        $fix = if ($msg -match 'dubious ownership') { "git config --global --add safe.directory '$($Repo -replace '\\', '/')'" }
        elseif ($msg -match 'index') { 'remove .git\index, then git reset (rebuilds the index from HEAD)' }
        else { 'repair the repo, or re-clone it and re-register with gita add' }
        [pscustomobject]@{ Issue = "git status failed: $msg"; Fix = $fix }
        return  # the checks below need a working repo
    }

    # status may succeed even when HEAD points to an invalid ref (e.g. refs/heads/.invalid).
    # symbolic-ref returns 1 for a valid detached HEAD; an unborn branch also remains valid.
    $out = @(git -C $Repo symbolic-ref --quiet HEAD 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -gt 1) {
        $msg = Get-GitErrorLine $out $LASTEXITCODE
        [pscustomobject]@{ Issue = "invalid HEAD: $msg"; Fix = 'repair HEAD to point to the intended branch, or re-register the correct repo path with gita add' }
        return
    }

    $gitDir = "$(git -C $Repo rev-parse --absolute-git-dir 2>$null)".Trim()
    if ($gitDir -and (Test-Path -LiteralPath $gitDir)) {
        # A lock left by a crashed git makes every later fetch / pull / checkout fail with "File exists".
        $locks = @(
            Get-ChildItem -LiteralPath $gitDir -Filter '*.lock' -File -Force -ErrorAction SilentlyContinue
            $refs = Join-Path $gitDir 'refs'
            if (Test-Path -LiteralPath $refs) { Get-ChildItem -LiteralPath $refs -Filter '*.lock' -File -Recurse -Force -ErrorAction SilentlyContinue }
        )
        foreach ($l in $locks) {
            [pscustomobject]@{ Issue = "stale lock file: $([IO.Path]::GetRelativePath($gitDir, $l.FullName))"; Fix = 'delete it if no git process is running in this repo' }
        }

        $ops = [ordered]@{ 'rebase-merge' = 'rebase'; 'rebase-apply' = 'rebase'; 'MERGE_HEAD' = 'merge'; 'CHERRY_PICK_HEAD' = 'cherry-pick'; 'REVERT_HEAD' = 'revert' }
        foreach ($marker in $ops.Keys) {
            if (Test-Path -LiteralPath (Join-Path $gitDir $marker)) {
                $op = $ops[$marker]
                [pscustomobject]@{ Issue = "$op in progress"; Fix = "finish it, or git $op --abort" }
                break
            }
        }
    }

    if ($Deep) {
        $out = @(git -C $Repo fsck --no-dangling --no-progress 2>&1 | ForEach-Object { "$_" })
        if ($LASTEXITCODE -ne 0) {
            $msg = Get-GitErrorLine $out $LASTEXITCODE
            [pscustomobject]@{ Issue = "git fsck failed: $msg"; Fix = 're-clone the repo (copy over local-only branches and changes first)' }
        }
    }
}

# git の出力から原因が分かる 1 行を選ぶ: fatal: / error: の行、なければ最初の空でない行。
function Get-GitErrorLine([string[]]$Lines, [int]$ExitCode) {
    $pick = @(@($Lines | Where-Object { $_ -match '^(fatal|error):' }) + @($Lines | Where-Object { "$_".Trim() }))
    if ($pick.Count -gt 0) { $pick[0].Trim() } else { "exit code $ExitCode" }
}
