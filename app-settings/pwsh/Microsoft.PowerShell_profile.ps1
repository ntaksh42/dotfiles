# ---------------------------------------------------------------------------
# §0 Encoding & internal helpers
# ---------------------------------------------------------------------------

# Ensure UTF-8 in/out (avoid mojibake; consistent across machines)
try {
    [Console]::OutputEncoding = [Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
}
catch {}

# Remember the file that was actually loaded. This remains correct when the
# profile is dot-sourced from a synced or non-default location.
$script:DotfilesProfilePath = if ($PSCommandPath) { $PSCommandPath } else { $PROFILE.CurrentUserCurrentHost }

# Cached command-existence check used by feature guards
$script:_cmdCache = @{}
function Test-Cmd {
    param([Parameter(Mandatory)][string]$Name)
    if (-not $script:_cmdCache.ContainsKey($Name)) {
        $script:_cmdCache[$Name] = [bool](Get-Command $Name -ErrorAction Ignore)
    }
    $script:_cmdCache[$Name]
}

# Native commands signal failures through $LASTEXITCODE rather than PowerShell
# exceptions. Convert those failures into terminating errors for callers.
function Assert-NativeCommandSucceeded {
    param([Parameter(Mandatory)][string]$Command)

    if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code $LASTEXITCODE."
    }
}

# Cache a tool's shell-init output to a file and dot-source that instead of
# spawning the tool on every startup. Regenerates when the exe is newer.
function Get-InitCache {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][scriptblock]$Generator
    )
    $dir = Join-Path $env:LOCALAPPDATA 'pwsh-init-cache'
    $path = Join-Path $dir "$Name.ps1"
    $src = (Get-Command $Exe -ErrorAction Ignore).Source
    $stale = (-not (Test-Path -LiteralPath $path)) -or
    ($src -and (Get-Item -LiteralPath $src).LastWriteTime -gt (Get-Item -LiteralPath $path).LastWriteTime)
    if ($stale) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        (& $Generator) | Out-String | Set-Content -LiteralPath $path -Encoding utf8
    }
    $path
}

# ---------------------------------------------------------------------------
# §1 Aliases
# ---------------------------------------------------------------------------
# Let the profile's Git and bat functions take precedence over built-in aliases.
Remove-Item Alias:gl, Alias:gp, Alias:gcm, Alias:cat -Force -ErrorAction Ignore
Set-Alias cop   copilot
Set-Alias g     git
Set-Alias cx     codex
Set-Alias which Get-Command
Set-Alias cl    Clear-Host

# ---------------------------------------------------------------------------
# §2 Navigation & file operations
# ---------------------------------------------------------------------------

# Create directory and move into it
function mkcd {
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path
    )
    New-Item -ItemType Directory -Force -Path $Path -ErrorAction Stop | Out-Null
    Set-Location $Path -ErrorAction Stop
}

# Display file/directory size
function size {
    param([string]$Path = ".")
    Get-ChildItem $Path |
    ForEach-Object {
        $bytes = if ($_.PSIsContainer) {
            (Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum ?? 0
        }
        else { $_.Length }
        [PSCustomObject]@{ Name = $_.Name; Size = [math]::Round($bytes / 1MB, 2) }
    } | Sort-Object Size -Descending | Format-Table -AutoSize
}

# Go up directories
function .. { Set-Location .. }
function ... { Set-Location ..\.. }
function .... { Set-Location ..\..\.. }

# Go up N directory levels (default 1)
function up {
    param([int]$Levels = 1)
    if ($Levels -lt 1) { $Levels = 1 }
    Set-Location (('..\' * $Levels).TrimEnd('\'))
}

# Jump to source\repos
function repos { Set-Location (Join-Path $env:USERPROFILE 'source\repos') }

# Listing: defer the eza lookup until the first listing command is used.
function ll {
    if (Test-Cmd eza) { eza -lh --git --icons --group-directories-first @args }
    else { Get-ChildItem @args }
}
function la {
    if (Test-Cmd eza) { eza -lah --git --icons --group-directories-first @args }
    else { Get-ChildItem -Force @args }
}
function lt {
    if (Test-Cmd eza) { eza --tree --level=2 --icons @args }
    else { Get-ChildItem -Recurse -Depth 1 @args }
}

# Fuzzy find a file and open it (fd + fzf)
function ff {
    if (-not (Test-Cmd fzf)) { Write-Warning 'ff needs fzf'; return }
    $sel = if (Test-Cmd fd) { & fd --type f | fzf }
    else { Get-ChildItem -Recurse -File | Select-Object -ExpandProperty FullName | fzf }
    if ($sel) { Invoke-Item $sel }
}

# Fuzzy find a directory and cd into it (fd + fzf)
function fcd {
    if (-not (Test-Cmd fzf)) { Write-Warning 'fcd needs fzf'; return }
    $sel = if (Test-Cmd fd) { & fd --type d | fzf }
    else { Get-ChildItem -Recurse -Directory | Select-Object -ExpandProperty FullName | fzf }
    if ($sel) { Set-Location $sel }
}

# touch: create file or update timestamp
function touch {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path $Path) { (Get-Item $Path).LastWriteTime = Get-Date }
    else { New-Item -ItemType File -Path $Path | Out-Null }
}

# Copy a file to <name>.bak-YYYYMMDD-HHmmss alongside it (snapshot before edits)
function backup-file {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Write-Warning "Not a file: $Path"; return }
    $item = Get-Item -LiteralPath $Path
    $dest = Join-Path $item.DirectoryName ('{0}.bak-{1}' -f $item.Name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item -LiteralPath $item.FullName -Destination $dest
    Write-Host "Backed up -> $dest" -ForegroundColor Green
}

# Reload this profile
function reload { . $script:DotfilesProfilePath }

# Measure this profile in clean child PowerShell processes. Tool init caches are
# intentionally preserved so the result represents normal, warm startup.
function Measure-ProfileStartup {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 20)][int]$Samples = 5,
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string]$Path = $script:DotfilesProfilePath
    )

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $pwsh = (Get-Process -Id $PID).Path
    $measureCommand = @'
$sw = [Diagnostics.Stopwatch]::StartNew()
. $env:DOTFILES_PROFILE_MEASURE_PATH
$sw.Stop()
'__PROFILE_MS__={0}' -f $sw.Elapsed.TotalMilliseconds.ToString([Globalization.CultureInfo]::InvariantCulture)
'@

    $values = foreach ($sample in 1..$Samples) {
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $pwsh
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.Environment['DOTFILES_PROFILE_MEASURE_PATH'] = $resolved
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $measureCommand)) {
            [void]$psi.ArgumentList.Add($argument)
        }

        $process = [Diagnostics.Process]::Start($psi)
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0 -or $stdout -notmatch '__PROFILE_MS__=([0-9.]+)') {
            throw "Profile measurement failed (exit $($process.ExitCode)): $stderr"
        }
        [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
    }

    $stats = $values | Measure-Object -Minimum -Maximum -Average
    [PSCustomObject]@{
        Samples   = $Samples
        AverageMs = [math]::Round($stats.Average, 2)
        MinimumMs = [math]::Round($stats.Minimum, 2)
        MaximumMs = [math]::Round($stats.Maximum, 2)
    }
}

# Edit this profile (VS Code if present, else Notepad)
function Edit-Profile {
    if (Test-Cmd code) { code $script:DotfilesProfilePath } else { notepad $script:DotfilesProfilePath }
}
Set-Alias profile Edit-Profile

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
        $dest = Join-Path $backupDir ($path -replace '/', '\')
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        Move-Item -LiteralPath $src -Destination $dest -Force -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) {
            throw "Failed to back up conflicting file: $path"
        }
        # 追跡ファイルなら、退避で消えた分をインデックスからも落として pull を通す。
        if ($c.Tracked) {
            git rm --cached --quiet -- $path 2>$null
            Assert-NativeCommandSucceeded "git rm --cached -- $path"
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
    git pack-refs --all
    Assert-NativeCommandSucceeded 'git pack-refs --all'

    # 衝突判定には fetch 済みの upstream が要る。pull 前に取得しておく。
    Write-Host '[gpl] fetch' -ForegroundColor Cyan
    git fetch --prune --quiet
    Assert-NativeCommandSucceeded 'git fetch --prune'
    $upstream = (git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null)
    $hasUpstream = ($LASTEXITCODE -eq 0 -and $upstream)
    if (-not $hasUpstream -and $args.Count -eq 0) {
        Write-Warning 'gpl: upstream 未設定。git branch -u origin/<branch> で設定するか、gpl origin <branch> と指定する'
        return
    }

    $stashed = $false
    if (git status --porcelain --untracked-files=no) {
        Write-Host '[gpl] 未コミット変更を stash' -ForegroundColor Cyan
        git stash push --quiet -m 'gpl: auto stash before pull'
        Assert-NativeCommandSucceeded 'git stash push'
        $stashed = $true
    }
    # rebase モードか (引数が pull.rebase 設定より優先)。大文字小文字だけの改名は git が rebase でも処理できる。
    $rebase = (git config --get pull.rebase) -notin @($null, '', 'false')
    foreach ($a in $args) {
        if ($a -in '--no-rebase', '--rebase=false') { $rebase = $false }
        elseif ($a -match '^(-r|--rebase(=.+)?)$') { $rebase = $true }
    }
    if ($hasUpstream) { Resolve-GitPullCollision -Upstream $upstream.Trim() -UntrackedOnly:$rebase }

    Write-Host '[gpl] pull' -ForegroundColor Cyan
    git pull @args
    if ($LASTEXITCODE -ne 0) {
        $hint = '[gpl] pull 失敗: 上のエラーを確認。マージ競合ならファイル修正後 git add / git commit、中止は git merge --abort'
        if ($stashed) { $hint += '。未コミット変更は stash に残っている (git stash pop で復元)' }
        Write-Host $hint -ForegroundColor Red
        Assert-NativeCommandSucceeded 'git pull'
    }
    if ($stashed) {
        Write-Host '[gpl] stash を復元' -ForegroundColor Cyan
        git stash pop --quiet
        if ($LASTEXITCODE -ne 0) {
            Write-Host '[gpl] stash の復元で競合。解消後 git stash drop' -ForegroundColor Red
            Assert-NativeCommandSucceeded 'git stash pop'
        }
    }
    git pack-refs --all
    Assert-NativeCommandSucceeded 'git pack-refs --all'
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

# ---------------------------------------------------------------------------
# §4 Visual Studio / build (C#/C++)
# ---------------------------------------------------------------------------

# Locate latest VS install path via vswhere
function Get-VsInstallPath {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { return $null }
    (& $vswhere -latest -property installationPath 2>$null)
}

# Resolve devenv.exe of the latest VS
function Get-DevEnvPath {
    $vsPath = Get-VsInstallPath
    if (-not $vsPath) { return $null }
    $devenv = Join-Path $vsPath 'Common7\IDE\devenv.exe'
    if (Test-Path $devenv) { $devenv } else { $null }
}

# Enter VS Developer environment in the CURRENT session (on demand; slow)
function vsdev {
    $vsPath = Get-VsInstallPath
    if (-not $vsPath) { Write-Warning 'Visual Studio not found (vswhere)'; return }
    $dll = Join-Path $vsPath 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll'
    if (-not (Test-Path $dll)) { Write-Warning "DevShell module not found: $dll"; return }
    try {
        Import-Module $dll
        Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'
    }
    catch {
        Write-Warning "vsdev failed: $($_.Exception.Message)"
    }
}

# Find nearest *.sln walking up from current directory
function Find-Sln {
    $dir = (Get-Location).Path
    while ($dir) {
        $slns = Get-ChildItem -Path $dir -Filter *.sln -File -ErrorAction SilentlyContinue
        if ($slns) { return $slns }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return @()
}

# Open nearest solution in Visual Studio
function sln {
    $devenv = Get-DevEnvPath
    if (-not $devenv) { Write-Warning 'Visual Studio (devenv) not found'; return }
    $slns = Find-Sln
    if (-not $slns) { Write-Warning 'No .sln found upward from current directory'; return }
    $target = if ($slns.Count -eq 1) { $slns[0].FullName }
    elseif (Test-Cmd fzf) { $slns.FullName | fzf }
    else { $slns[0].FullName }
    if ($target) { Start-Process $devenv $target }
}

# Open a path (default: current dir) in Visual Studio
function vs {
    param([string]$Path = ".")
    $devenv = Get-DevEnvPath
    if (-not $devenv) { Write-Warning 'Visual Studio (devenv) not found'; return }
    Start-Process $devenv (Resolve-Path $Path).Path
}

# dotnet / msbuild shortcuts
function db { dotnet build @args }
function dr { dotnet run @args }
function dt { dotnet test @args }
function msb { msbuild @args }

# ---------------------------------------------------------------------------
# §5 Tool integrations (all guarded)
# ---------------------------------------------------------------------------

# Starship: cross-shell prompt (best with a Nerd Font for glyphs)
# --print-full-init avoids `starship init powershell` alone returning a lazy
# `Invoke-Expression (& starship ... | Out-String)` wrapper that re-invokes
# starship.exe in full on every dot-source, defeating Get-InitCache entirely.
# Kept synchronous here (unlike zoxide below, deferred to OnIdle): deferring
# it swaps $function:prompt only after the first prompt line is already on
# screen, which is visible as a one-time flash from the default prompt to
# starship's -- not worth the ~400-500ms saved (see zoxide's comment below).
if (Test-Cmd starship) {
    # 親プロセス経由で TERM=dumb が渡されると、starship が毎プロンプトでエラーを出す。
    if ($env:TERM -eq 'dumb') { Remove-Item Env:TERM }
    . (Get-InitCache 'starship' 'starship' { starship init powershell --print-full-init })
}

# bat: syntax-highlighted cat (bat outputs plain text when piped)
function cat {
    if (Test-Cmd bat) { bat @args } else { Get-Content @args }
}

# gsudo: sudo for Windows
function sudo {
    if (Test-Cmd gsudo) { gsudo @args }
    else { Write-Warning 'sudo needs gsudo' }
}

# Defer heavy modules (PSFzf + Terminal-Icons + zoxide, ~2s combined) to the
# first idle tick so the prompt appears immediately; they load once shortly
# after startup.
#
# zoxide: --hook pwd hooks Set-Location instead of prompt, so unlike
# starship above it has no visible effect when deferred -- pure startup-time
# win, and .NET's first-ever Process.Start/Task JIT cost in a fresh pwsh
# process (~100ms+ here) is worth moving off the interactive startup path.
$global:_dotfilesProfileDeferredDone = $false
if ($global:_dotfilesProfileIdleSubscriptionId) {
    Unregister-Event -SubscriptionId $global:_dotfilesProfileIdleSubscriptionId -ErrorAction Ignore
}
$null = Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -Action {
    if ($global:_dotfilesProfileDeferredDone) { return }
    $global:_dotfilesProfileDeferredDone = $true
    if (Get-Command zoxide -ErrorAction Ignore) {
        try { . (Get-InitCache 'zoxide' 'zoxide' { zoxide init --hook pwd powershell }) } catch {}
    }
    if (Get-Command gh -ErrorAction Ignore) {
        try { . (Get-InitCache 'gh' 'gh' { gh completion -s powershell }) } catch {}
    }
    if (Get-Module -ListAvailable -Name PSFzf) {
        try {
            Import-Module PSFzf
            Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordSetLocation 'Alt+c'
            # PSFzf grabs Ctrl+r on import; re-assert the custom fzf history handler.
            if (Get-Command fzf -ErrorAction Ignore) {
                Set-PSReadLineKeyHandler -Key Ctrl+r -ScriptBlock { Invoke-FzfHistory }
            }
        }
        catch {}
    }
    if (Get-Module -ListAvailable -Name Terminal-Icons) {
        Import-Module Terminal-Icons
    }
    # 遅延ロード中に初回プロンプトが消えることがあるため、完了後に再描画する。
    try { [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt() } catch {}
}

# Native tab completion (verified snippets), each guarded on command presence
Register-ArgumentCompleter -Native -CommandName dotnet -ScriptBlock {
    param($commandName, $wordToComplete, $cursorPosition)
    dotnet complete --position $cursorPosition "$wordToComplete" | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    }
}
$global:_dotfilesProfileIdleSubscriptionId = (Get-EventSubscriber -SourceIdentifier PowerShell.OnIdle |
    Sort-Object SubscriptionId -Descending |
    Select-Object -First 1).SubscriptionId

Register-ArgumentCompleter -Native -CommandName winget -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    [Console]::InputEncoding = [Console]::OutputEncoding = $OutputEncoding = [System.Text.Utf8Encoding]::new()
    $word = $wordToComplete.Replace('"', '""')
    $ast = $commandAst.ToString().Replace('"', '""')
    winget complete --word="$word" --commandline "$ast" --position $cursorPosition | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    }
}

# Reload PATH from Machine + User scope (use after installs; no shell restart)
function refreshenv {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = ($machine, $user | Where-Object { $_ }) -join ';'
    Write-Host 'PATH refreshed.' -ForegroundColor Green
}
Set-Alias Update-SessionPath refreshenv

# Clipboard shortcuts
function clip { $input | Set-Clipboard }
function paste { Get-Clipboard }

# Show public IP address
function myip { (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 5).ip }

# Show what's listening on a TCP port
function port {
    param([Parameter(Mandatory)][int]$Port)
    Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue |
    Select-Object LocalAddress, LocalPort, State, OwningProcess,
    @{ n = 'Process'; e = { (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName } }
}

# Kill the process(es) listening on a TCP port
function killport {
    param([Parameter(Mandatory)][int]$Port)
    $conns = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
    if (-not $conns) { Write-Warning "Nothing listening on port $Port"; return }
    $conns.OwningProcess | Sort-Object -Unique | ForEach-Object {
        Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
        Write-Host "Killed PID $_ on port $Port" -ForegroundColor Yellow
    }
}

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

# ---------------------------------------------------------------------------
# §7 Environment setup helpers
# ---------------------------------------------------------------------------
# dotfiles リポジトリ（public）の raw コンテンツ取得元。app-settings 配下の設定ファイルを
# クローンなしで取得するために使う。
$script:DotfilesRawBase = 'https://raw.githubusercontent.com/ntaksh42/dotfiles/main'

# remote-config バックエンド用: リポジトリ内のファイルを raw 経由で取得する（先頭の
# 管理用コメント行は StripCommentLines で除去できる）。
function Get-DotfilesRemoteConfig {
    param([Parameter(Mandatory)]$Tool)
    $uri = "$script:DotfilesRawBase/$($Tool.RepoPath)"
    try {
        $content = (Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop).Content
    }
    catch {
        throw "Failed to retrieve ${uri}: $($_.Exception.Message)"
    }
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "Retrieved empty content from $uri."
    }
    if ($Tool.StripCommentLines) {
        $lines = $content -split "`r?`n"
        $content = ($lines | Select-Object -Skip $Tool.StripCommentLines) -join "`n"
    }
    return $content
}

# remote-config バックエンド用: 既存ファイルとリモート内容の差分を表示する（git があれば
# `git diff --no-index` で色付き表示、なければ Compare-Object で簡易表示）。
function Show-DotfilesRemoteConfigDiff {
    param([Parameter(Mandatory)]$Tool, [Parameter(Mandatory)][string]$RemoteContent)
    if (Test-Cmd git) {
        $tmp = Join-Path $env:TEMP "dotfiles-remote-$([guid]::NewGuid().ToString('N')).tmp"
        try {
            Set-Content -LiteralPath $tmp -Value $RemoteContent -NoNewline -Encoding UTF8
            git --no-pager diff --no-index --color=always -- $Tool.Dest $tmp 2>$null
        }
        finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    else {
        Compare-Object (Get-Content -LiteralPath $Tool.Dest) ($RemoteContent -split "`r?`n") | ForEach-Object {
            $prefix = if ($_.SideIndicator -eq '<=') { '- (ローカル) ' } else { '+ (リポジトリ)' }
            "$prefix $($_.InputObject)"
        }
    }
}

# リポジトリ版のプロファイルと環境構築ファイルをまとめて更新する。
# 全ファイルの取得・構文検証後に差分表示 -> 確認 -> バックアップ -> 上書き -> 再読込。
# 上書き先は $PROFILE（クローンから dot-source している場合に管理元ファイルを潰さないため）。
function Update-Profile {
    [CmdletBinding()]
    param([switch]$Force)

    $profilePath = $PROFILE.CurrentUserCurrentHost
    $profileDir = Split-Path -Parent $profilePath
    $updates = @(foreach ($name in @('DevTools.ps1', 'Microsoft.PowerShell_profile.ps1')) {
        $tool = @{
            RepoPath = "app-settings/pwsh/$name"
            Dest     = Join-Path $profileDir $name
        }
        $content = Get-DotfilesRemoteConfig $tool
        $tokens = $null; $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) { throw "取得した $name が不正な PowerShell のため更新を中断しました。" }
        if ((Test-Path -LiteralPath $tool.Dest -PathType Leaf) -and
            ((Get-Content -LiteralPath $tool.Dest -Raw) -ceq $content)) { continue }
        @{ Tool = $tool; Content = $content }
    })
    if ($updates.Count -eq 0) {
        Write-Host 'Profile is up to date.' -ForegroundColor Green
        return
    }
    if (-not $Force) {
        foreach ($update in $updates) {
            Write-Host $update.Tool.Dest -ForegroundColor Cyan
            if (Test-Path -LiteralPath $update.Tool.Dest -PathType Leaf) {
                Show-DotfilesRemoteConfigDiff -Tool $update.Tool -RemoteContent $update.Content | Write-Host
            }
        }
        if ((Read-Host 'プロファイル一式を更新しますか? (y/N)') -notmatch '^(y|yes)$') { Write-Host 'Aborted.'; return }
    }
    New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    foreach ($update in $updates) {
        $dest = $update.Tool.Dest
        if (Test-Path -LiteralPath $dest -PathType Leaf) {
            $backup = "$dest.backup.$timestamp"
            Copy-Item -LiteralPath $dest -Destination $backup -Force
            Write-Host "バックアップ: $backup" -ForegroundColor Gray
        }
        Set-Content -LiteralPath $dest -Value $update.Content -NoNewline -Encoding UTF8
    }
    Write-Host 'Profile updated. Reloading...' -ForegroundColor Green
    . $profilePath
}

$devToolsPath = Join-Path (Split-Path -Parent $script:DotfilesProfilePath) 'DevTools.ps1'
if (Test-Path -LiteralPath $devToolsPath -PathType Leaf) {
    . $devToolsPath
}
else {
    Write-Warning 'DevTools.ps1 が見つかりません。Update-Profile または tools/Sync-AppSettings.ps1 でプロファイル一式を配置してください。'
}

# ---------------------------------------------------------------------------
# §8 PSReadLine - prediction and key bindings
# ---------------------------------------------------------------------------

# Interactive history search with delete support (Ctrl+r replacement)
# Usage: Ctrl+r to search, Del to delete selected entry and re-open
function Invoke-FzfHistory {
    if (-not (Test-Cmd fzf)) { Write-Warning 'History search needs fzf'; return }
    $histFile = Join-Path $env:APPDATA 'Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt'
    if (-not (Test-Path $histFile)) { return }

    while ($true) {
        $selected = Get-Content $histFile |
        Where-Object { $_ -ne '' } |
        Select-Object -Unique |
        & fzf --scheme=history --no-sort --tac `
            --prompt 'history> ' `
            --expect 'del'

        # $selected[0] = 押されたキー、$selected[1] = 選択した行
        if (-not $selected) { return }

        $key = $selected[0]
        $line = $selected[1]

        if ($key -eq 'del' -and $line) {
            $content = Get-Content $histFile
            $content | Where-Object { $_ -ne $line } | Set-Content $histFile
            # ループして再表示
        }
        elseif ($line) {
            [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt()
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert($line)
            return
        }
        else {
            return
        }
    }
}

# Search this profile's command catalog (fzf) and insert the chosen command
# name into the prompt without executing it, so arguments can follow.
# Combined entries like 'gp / gpf' or 'gsta/gstp/gstl' are split into
# separate candidates; argument placeholders like '<msg>' are stripped.
function Invoke-CommandPalette {
    if (-not (Test-Cmd fzf)) { Write-Warning 'Invoke-CommandPalette needs fzf'; return }

    $rows = foreach ($section in $script:ProfileHelp.Keys) {
        foreach ($item in $script:ProfileHelp[$section]) {
            $names = ($item.Cmd -split '[,/]') | ForEach-Object {
                ($_ -replace '[\[<].*', '').Trim()
            } | Where-Object { $_ }
            foreach ($name in $names) {
                "$name`t$($item.Desc)`t[$section]"
            }
        }
    }

    $sel = $rows | fzf --delimiter "`t" --with-nth 1, 2, 3 --prompt 'cmd> '
    if (-not $sel) { return }

    $cmdName = ($sel -split "`t")[0]
    [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt()
    [Microsoft.PowerShell.PSConsoleReadLine]::Insert("$cmdName ")
}

if ($host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) {
    Import-Module PSReadLine

    Set-PSReadLineOption -PredictionSource History
    Set-PSReadLineOption -PredictionViewStyle ListView
    Set-PSReadLineOption -EditMode Windows
    Set-PSReadLineOption -HistorySearchCursorMovesToEnd
    Set-PSReadLineOption -HistoryNoDuplicates
    Set-PSReadLineOption -MaximumHistoryCount 10000

    Set-PSReadLineKeyHandler -Key UpArrow   -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
    Set-PSReadLineKeyHandler -Key Ctrl+d    -Function DeleteCharOrExit
    Set-PSReadLineKeyHandler -Key Tab       -Function MenuComplete
    Set-PSReadLineKeyHandler -Key Alt+a     -Function SelectCommandArgument

    # Smart auto-closing brackets / quotes (adapted from the PSReadLine sample profile)
    Set-PSReadLineKeyHandler -Key '(', '{', '[' -BriefDescription InsertPairedBraces -ScriptBlock {
        param($key, $arg)
        $close = @{ '(' = ')'; '{' = '}'; '[' = ']' }[[string]$key.KeyChar]
        $line = $null; $cursor = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        $selStart = $null; $selLen = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::GetSelectionState([ref]$selStart, [ref]$selLen)
        if ($selLen -ne -1) {
            [Microsoft.PowerShell.PSConsoleReadLine]::Replace($selStart, $selLen, "$($key.KeyChar)" + $line.Substring($selStart, $selLen) + $close)
            [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($selStart + $selLen + 2)
        }
        else {
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert("$($key.KeyChar)$close")
            [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($cursor + 1)
        }
    }

    Set-PSReadLineKeyHandler -Key ')', ']', '}' -BriefDescription SmartCloseBraces -ScriptBlock {
        param($key, $arg)
        $line = $null; $cursor = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        if ($cursor -lt $line.Length -and $line[$cursor] -eq $key.KeyChar) {
            [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($cursor + 1)
        }
        else {
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert("$($key.KeyChar)")
        }
    }

    Set-PSReadLineKeyHandler -Key '"', "'" -BriefDescription SmartInsertQuote -ScriptBlock {
        param($key, $arg)
        $quote = $key.KeyChar
        $line = $null; $cursor = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        if ($cursor -lt $line.Length -and $line[$cursor] -eq $quote) {
            [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($cursor + 1)
        }
        else {
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert("$quote$quote")
            [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($cursor + 1)
        }
    }

    # fzf history search (registered last so PSFzf doesn't override Ctrl+r)
    Set-PSReadLineKeyHandler -Key Ctrl+r -ScriptBlock { Invoke-FzfHistory }
    # fzf command palette: search this profile's command catalog, insert the pick
    Set-PSReadLineKeyHandler -Key Ctrl+g -ScriptBlock { Invoke-CommandPalette }
}

# ---------------------------------------------------------------------------
# §9 Help - list the commands this profile provides
# ---------------------------------------------------------------------------

# Catalog of commands defined above (data-driven; keep in sync when adding commands)
$script:ProfileHelp = [ordered]@{
    'Navigation & files'    = @(
        @{ Cmd = 'mkcd <path>'; Desc = 'ディレクトリを作成して移動' }
        @{ Cmd = 'size [path]'; Desc = 'ファイル/フォルダのサイズ一覧 (MB, 降順)' }
        @{ Cmd = '.. / ... / ....'; Desc = '1/2/3 階層上へ移動' }
        @{ Cmd = 'up [n]'; Desc = 'n 階層上へ移動 (既定 1)' }
        @{ Cmd = 'repos'; Desc = '~/source/repos へジャンプ' }
        @{ Cmd = 'll / la / lt'; Desc = '一覧表示 (eza があればアイコン/git 付き)' }
        @{ Cmd = 'ff'; Desc = 'fzf でファイルを絞り込んで開く' }
        @{ Cmd = 'fcd'; Desc = 'fzf でディレクトリを絞り込んで cd' }
        @{ Cmd = 'touch <path>'; Desc = 'ファイル作成 / タイムスタンプ更新' }
        @{ Cmd = 'backup-file <f>'; Desc = '<名前>.bak-日時 でバックアップ作成' }
        @{ Cmd = 'reload'; Desc = 'プロファイルを再読込' }
        @{ Cmd = 'Measure-ProfileStartup'; Desc = 'プロファイル起動時間を別プロセスで計測' }
        @{ Cmd = 'profile'; Desc = 'プロファイルを編集 (code/notepad)' }
        @{ Cmd = 'Update-Profile [-Force]'; Desc = 'GitHub 上のリポジトリ版でプロファイルを更新 (差分確認・バックアップ・再読込)' }
    )
    'Git / GitHub'          = @(
        @{ Cmd = 'gs'; Desc = 'git status -sb' }
        @{ Cmd = 'gl'; Desc = 'git log をグラフ表示 (直近 20)' }
        @{ Cmd = 'git-undo'; Desc = '直前コミットを取り消し (staging へ戻す)' }
        @{ Cmd = 'ga / gaa'; Desc = 'git add / git add -A' }
        @{ Cmd = 'gb'; Desc = 'git branch' }
        @{ Cmd = 'gd / gds'; Desc = 'git diff / git diff --staged' }
        @{ Cmd = 'gp / gpf'; Desc = 'git push / push --force-with-lease' }
        @{ Cmd = 'gpl'; Desc = '安全な git pull: 衝突ファイルを .git/pull-backup へ退避 + 未コミット変更を自動 stash/復元 (引数は git pull へ)' }
        @{ Cmd = 'gf'; Desc = 'git fetch --all --prune (大文字小文字違いの ref 衝突を回避)' }
        @{ Cmd = 'gsta/gstp/gstl'; Desc = 'git stash push/pop/list' }
        @{ Cmd = 'gcm <msg>'; Desc = 'git commit -m' }
        @{ Cmd = 'gco [branch]'; Desc = 'checkout (引数なしは fzf で選択)' }
        @{ Cmd = 'lg'; Desc = 'lazygit (あれば)' }
        @{ Cmd = 'prc/prv/prl/prs'; Desc = 'gh pr create/view/list/status (あれば)' }
        @{ Cmd = 'groot'; Desc = 'リポジトリのルートへ cd' }
        @{ Cmd = 'gclone <url>'; Desc = 'clone して cd' }
        @{ Cmd = 'glog'; Desc = 'fzf でコミット閲覧 (delta プレビュー)' }
        @{ Cmd = 'clean-pull-all'; Desc = 'gita 全リポジトリを掃除して pull (-Fallback で切替先指定)' }
        @{ Cmd = 'git-switch'; Desc = 'fzf でブランチ切替 (無ければ origin から作成)' }
        @{ Cmd = 'git-clean-branches'; Desc = 'マージ済みローカルブランチを一括削除' }
        @{ Cmd = 'git-nuke'; Desc = 'reset --hard + clean -ffdx で完全クリーン (-Ref/-Force)' }
        @{ Cmd = 'gita-scan [path]'; Desc = '直下の git リポジトリを gita に一括登録' }
    )
    'Visual Studio / build' = @(
        @{ Cmd = 'vsdev'; Desc = '現セッションを VS Developer 環境化' }
        @{ Cmd = 'sln'; Desc = '最寄りの .sln を VS で開く' }
        @{ Cmd = 'vs [path]'; Desc = '指定パスを VS で開く' }
        @{ Cmd = 'db / dr / dt'; Desc = 'dotnet build / run / test' }
        @{ Cmd = 'msb'; Desc = 'msbuild' }
    )
    'Tools & system'        = @(
        @{ Cmd = 'cat <file>'; Desc = 'bat 連携 (あれば)' }
        @{ Cmd = 'sudo <cmd>'; Desc = 'gsudo 連携 (あれば)' }
        @{ Cmd = 'z / zi'; Desc = 'zoxide スマート cd (あれば)' }
        @{ Cmd = 'refreshenv / Update-SessionPath'; Desc = 'PATH を再読込 (インストール後に)' }
        @{ Cmd = 'phelp [keyword]'; Desc = 'このコマンド一覧を表示 (キーワードで絞り込み)' }
        @{ Cmd = 'clip / paste'; Desc = 'クリップボードへ書込 / 読出' }
        @{ Cmd = 'myip'; Desc = '公開 IP アドレスを表示' }
        @{ Cmd = 'port <n>'; Desc = 'ポートを使用中のプロセスを表示' }
        @{ Cmd = 'killport <n>'; Desc = 'ポートを使用中のプロセスを強制終了' }
    )
    'Claude Code'           = @(
        @{ Cmd = 'fable-orchest / ccf'; Desc = 'Fable が立案・Sonnet 5 が実行の構成で claude 起動' }
        @{ Cmd = 'fable-orchest-opus / ccfo'; Desc = 'Fable が立案・Opus 5.5 が実行の構成で claude 起動' }
        @{ Cmd = 'opus-orchest / cco'; Desc = 'Opus 5.5 が立案・Sonnet 5 が実行の構成で claude 起動' }
        @{ Cmd = 'fable-orchest-plan / ccfp'; Desc = 'ccf を plan モードで起動（立案を承認してから実行）' }
        @{ Cmd = 'cc / ccop'; Desc = 'Opus 5.5 で claude 起動（司令塔プロンプトなし、既定コマンド）' }
        @{ Cmd = 'ccp'; Desc = 'cc を plan モードで起動' }
        @{ Cmd = 'ccs'; Desc = 'Sonnet 5 で claude 起動（軽作業向け）' }
        @{ Cmd = 'ccc'; Desc = '直近の会話を継続 (claude --continue)' }
        @{ Cmd = 'ccr'; Desc = 'セッションを選んで再開 (claude --resume)' }
    )
    'Codex'                 = @(
        @{ Cmd = 'cx'; Desc = 'codex 素の起動（config.toml の既定に従う）' }
        @{ Cmd = 'cxr'; Desc = '読み取り専用で起動（調査・コードリーディング向け）' }
        @{ Cmd = 'cxa'; Desc = '承認なしで自動実行（サンドボックス内に限定）' }
        @{ Cmd = 'cxh'; Desc = '推論強度 high で起動（設計判断・難しいデバッグ）' }
        @{ Cmd = 'cxrev'; Desc = 'コードレビューを実行 (codex review)' }
        @{ Cmd = 'cxc'; Desc = '直近セッションを継続 (codex resume --last)' }
        @{ Cmd = 'cxs'; Desc = 'セッションを選んで再開 (codex resume)' }
        @{ Cmd = 'cxfa'; Desc = 'サンドボックスを外して起動（承認は残る）' }
        @{ Cmd = 'cxyolo'; Desc = '承認・サンドボックスとも無効化' }
    )
    'Dev environment'       = @(
        @{ Cmd = 'Show-DevEnv'; Desc = '開発ツールの導入状況を一覧' }
        @{ Cmd = 'Install-DevTools [-Yes]'; Desc = '未導入ツールを一括インストール (-Yes で全確認に y)' }
        @{ Cmd = 'Update-DevTools'; Desc = 'winget/PS モジュールを更新' }
    )
    'Aliases'               = @(
        @{ Cmd = 'cop'; Desc = 'copilot' }
        @{ Cmd = 'g'; Desc = 'git' }
        @{ Cmd = 'which'; Desc = 'Get-Command' }
    )
}

# Show the commands this profile provides. Optional keyword filters cmd/desc/section.
function Show-ProfileHelp {
    param([string]$Filter)

    foreach ($section in $script:ProfileHelp.Keys) {
        $items = $script:ProfileHelp[$section]
        if ($Filter) {
            $items = @($items | Where-Object {
                    $_.Cmd -like "*$Filter*" -or $_.Desc -like "*$Filter*" -or $section -like "*$Filter*"
                })
        }
        if (-not $items) { continue }

        Write-Host ''
        Write-Host "[$section]" -ForegroundColor Cyan
        foreach ($i in $items) {
            Write-Host ('  {0,-22}' -f $i.Cmd) -ForegroundColor Yellow -NoNewline
            Write-Host $i.Desc -ForegroundColor Gray
        }
    }
    Write-Host ''
    Write-Host "tip: 'phelp <keyword>' で絞り込み (例: phelp git) / Ctrl+g でコマンドパレット検索 / Ctrl+r で履歴検索" -ForegroundColor DarkGray
}
Set-Alias phelp Show-ProfileHelp
