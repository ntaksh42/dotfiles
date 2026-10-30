# Run with: pwsh -NoProfile -File app-settings/pwsh/tests/Test-Git.ps1
# Covers profile.d\git.ps1 with git / gh / lazygit / gita / fzf faked, so no real tool, network or
# registry is touched. Filesystem work happens only under a throwaway temp directory.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$originalPath = $env:PATH
$startLocation = Get-Location
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('dotfiles-git-test-' + [guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'TestHarness.ps1')

try {
    New-Item -ItemType Directory -Path $scratch | Out-Null
    $env:PATH = ''
    . (Join-Path $root 'Microsoft.PowerShell_profile.ps1')

    # --- Fakes ---------------------------------------------------------------------------
    # Every fake `git` call is recorded in $script:calls (raw arguments). Output and exit codes come from
    # $script:g, keyed on the call with leading "-C <dir>" / "-c <k=v>" options stripped. Any call matching
    # a -like pattern in $script:g.Fail exits 1 with no output.
    # Note: PowerShell swallows a literal "--" when calling a function, so the fake never sees the "--" in
    # "git rm --cached --quiet -- <path>"; a real (native) git does.
    $script:calls = [System.Collections.Generic.List[string[]]]::new()
    $script:gitaCalls = [System.Collections.Generic.List[string[]]]::new()
    $script:toolCalls = [System.Collections.Generic.List[string[]]]::new()

    function Reset-Fake {
        $script:calls.Clear(); $script:gitaCalls.Clear(); $script:toolCalls.Clear()
        $script:g = @{
            Upstream = 'origin/main'; Branch = 'main'; HasOrigin = $true
            Dirty = $null; Rebase = $null; StashRef = $null; StashCreates = $true
            RemoteFiles = @('README.md'); Tracked = @(); Untracked = @()
            Top = $null; GitDir = $null; CloneDir = $null
            Branches = @(); LocalBranches = @(); Merged = @(); CleanPreview = @(); CleanLeft = @(); Cleaned = $false; LogLines = @()
            Fail = @(); Repos = @{}; GitaNames = @(); GitaPaths = @{}
            # One-shot failures: the first call matching Pattern prints Output, exits 1 and is consumed.
            FailOnce = [System.Collections.Generic.List[object]]::new()
        }
        $script:fzfArgs = $null; $script:fzfInput = $null; $script:fzfPick = $null
        $script:prompts = @(); $script:answer = 'y'
        $script:_cmdCache['fzf'] = $true
        $script:_cmdCache['delta'] = $false
        $script:_cmdCache['gita'] = $true
        $global:LASTEXITCODE = 0
    }

    function git {
        $raw = [string[]]$args
        $script:calls.Add($raw)
        $global:LASTEXITCODE = 0
        $cdir = $null
        $norm = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $raw.Count; $i++) {
            if ($raw[$i] -ceq '-C') { $cdir = $raw[$i + 1]; $i++ }
            elseif ($raw[$i] -ceq '-c') { $i++ }
            else { $norm.Add($raw[$i]) }
        }
        $sub = $norm -join ' '
        for ($k = 0; $k -lt $script:g.FailOnce.Count; $k++) {
            $f = $script:g.FailOnce[$k]
            if ($sub -like $f.Pattern) { $script:g.FailOnce.RemoveAt($k); $global:LASTEXITCODE = 1; $f.Output; return }
        }
        foreach ($pattern in $script:g.Fail) {
            if ($sub -like $pattern) { $global:LASTEXITCODE = 1; return }
        }
        $repo = if ($cdir -and $script:g.Repos.ContainsKey($cdir)) { $script:g.Repos[$cdir] } else { $script:g }
        switch -Wildcard ($sub) {
            'rev-parse --abbrev-ref --symbolic-full-name @{u}' {
                if ($script:g.Upstream) { $script:g.Upstream } else { $global:LASTEXITCODE = 128 }
                return
            }
            'rev-parse --abbrev-ref HEAD' { $repo.Branch; return }
            'rev-parse -q --verify refs/stash' {
                if ($script:g.StashRef) { $script:g.StashRef } else { $global:LASTEXITCODE = 1 }
                return
            }
            'rev-parse --verify --quiet refs/heads/*' {
                $name = $sub.Substring('rev-parse --verify --quiet refs/heads/'.Length)
                if ($script:g.LocalBranches -notcontains $name) { $global:LASTEXITCODE = 1 }
                return
            }
            'rev-parse --verify --quiet origin/*' { if (-not $repo.HasOrigin) { $global:LASTEXITCODE = 1 }; return }
            'rev-parse --absolute-git-dir' { $repo.GitDir; return }
            'rev-parse --is-bare-repository' { if ($repo.Bare) { 'true' } else { 'false' }; return }
            'rev-parse --git-dir' { if ($repo.NotRepo) { $global:LASTEXITCODE = 128 }; return }
            'rev-parse --show-toplevel' {
                if ($script:g.Top) { $script:g.Top } else { $global:LASTEXITCODE = 128 }
                return
            }
            'status --porcelain*' {
                if ($repo.StatusError) { $repo.StatusError; $global:LASTEXITCODE = 128 } else { $script:g.Dirty }
                return
            }
            'fsck *' { if ($repo.FsckError) { $repo.FsckError; $global:LASTEXITCODE = 1 }; return }
            'stash push --quiet -m *' { if ($script:g.StashCreates) { $script:g.StashRef = 'stash-created' }; return }
            'config --get pull.rebase' {
                if ($script:g.Rebase) { $script:g.Rebase } else { $global:LASTEXITCODE = 1 }
                return
            }
            'symbolic-ref --short -q HEAD' { $repo.Branch; return }
            'config --get branch.*.remote' { 'origin'; return }
            'config --get branch.*.merge' { "refs/heads/$($repo.Branch)"; return }
            'ls-tree -r --name-only *' { $script:g.RemoteFiles; return }
            'ls-files --others --exclude-standard' { $repo.Untracked; return }
            'ls-files' { $repo.Tracked; return }
            'branch --all --format=%(refname:short)' { $script:g.Branches; return }
            'branch --merged' { $script:g.Merged; return }
            'clean -ffdxn' {
                # After "clean -ffdx" only the CleanLeft entries that still exist on disk under Top remain.
                if (-not $script:g.Cleaned) { $script:g.CleanPreview; return }
                foreach ($line in $script:g.CleanLeft) {
                    $p = "\\?\$(Join-Path $script:g.Top (($line -replace '^Would remove ', '').TrimEnd('/') -replace '/', '\'))"
                    if ([IO.File]::Exists($p) -or [IO.Directory]::Exists($p)) { $line }
                }
                return
            }
            'clean -ffdx' { $script:g.Cleaned = $true; return }
            'log *' { $script:g.LogLines; return }
            'clone *' {
                if ($script:g.CloneDir) { New-Item -ItemType Directory -Path $script:g.CloneDir | Out-Null }
                return
            }
        }
    }
    function gita {
        $script:gitaCalls.Add([string[]]$args)
        if ($args[0] -eq 'ls') {
            if ($args.Count -eq 1) { $script:g.GitaNames } else { $script:g.GitaPaths[[string]$args[1]] }
        }
    }
    function lazygit { $script:toolCalls.Add([string[]](@('lazygit') + $args)) }
    function gh { $script:toolCalls.Add([string[]](@('gh') + $args)) }
    function fzf { $script:fzfArgs = @($args); $script:fzfInput = @($input); $script:fzfPick }
    function Read-Host { param($Prompt) $script:prompts += $Prompt; $script:answer }

    # --- Helpers -------------------------------------------------------------------------
    function Get-Calls { @($script:calls | ForEach-Object { $_ -join ' ' }) }
    function Get-CallIndex([string]$Pattern) {
        $c = @(Get-Calls)
        for ($i = 0; $i -lt $c.Count; $i++) { if ($c[$i] -like $Pattern) { return $i } }
        -1
    }
    function Test-Called([string]$Pattern) { (Get-CallIndex $Pattern) -ge 0 }
    # Runs code and returns every output/warning/host line as plain strings.
    function Get-Output([scriptblock]$Code) { @(& $Code *>&1 | ForEach-Object { "$_" }) }
    function Test-Line([string[]]$Lines, [string]$Text) { @($Lines | Where-Object { $_ -and $_.Contains($Text) }).Count -gt 0 }
    function New-ScratchDir {
        $d = Join-Path $scratch ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $d | Out-Null
        $d
    }
    function New-TestFile([string]$Dir, [string]$Rel, [string]$Content = 'x') {
        $p = Join-Path $Dir ($Rel -replace '/', '\')
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
        # \\?\ lets us create/read the Windows-reserved name "nul".
        [IO.File]::WriteAllText("\\?\$p", $Content)
    }
    function Test-TestFile([string]$Dir, [string]$Rel) { [IO.File]::Exists("\\?\$(Join-Path $Dir ($Rel -replace '/', '\'))") }
    function New-FakeWorktree {
        $top = New-ScratchDir
        New-Item -ItemType Directory -Path (Join-Path $top '.git') | Out-Null
        $script:g.Top = $top
        $script:g.GitDir = Join-Path $top '.git'
        $top
    }
    # Files moved into .git\pull-backup\<timestamp>\, as paths relative to the timestamp directory.
    function Get-BackedUp([string]$Top) {
        $b = Join-Path $Top '.git\pull-backup'
        if (-not (Test-Path -LiteralPath $b)) { return @() }
        @(Get-ChildItem -LiteralPath $b -Recurse -File | ForEach-Object { ($_.FullName.Substring($b.Length + 1) -split '\\', 2)[1] })
    }
    function New-FakeRepo([string]$Name, [hashtable]$Overrides = @{}) {
        $dir = Join-Path (New-ScratchDir) $Name
        New-Item -ItemType Directory -Path $dir | Out-Null
        $cfg = @{ Branch = 'main'; HasOrigin = $true; Tracked = @(); Untracked = @(); GitDir = (Join-Path $dir '.git') }
        foreach ($k in $Overrides.Keys) { $cfg[$k] = $Overrides[$k] }
        if (-not $cfg.NotRepo -and -not $cfg.Bare) { New-Item -ItemType Directory -Path $cfg.GitDir | Out-Null }
        $script:g.Repos[$dir] = $cfg
        $script:g.GitaPaths[$Name] = $dir
        $script:g.GitaNames += $Name
        $dir
    }

    Reset-Fake

    # --- gl: the one wrapper that still just forwards to git -----------------------------
    Test-Case 'gl runs its fixed log options and appends caller arguments unsplit' {
        Reset-Fake
        $null = gl 'a b' '--flag'
        $script:calls.Count -eq 1 -and
        ($script:calls[0] -join '|') -ceq 'log|--oneline|--graph|--decorate|-20|a b|--flag'
    }
    Test-Case 'A failing wrapper leaves the git exit code visible to the caller' {
        Reset-Fake
        $script:g.Fail = @('log*')
        $null = gl
        $LASTEXITCODE -eq 1
    }

    # --- Native tool wrappers ------------------------------------------------------------
    $toolWrappers = @(
        @{ Cmd = 'lg'; Base = @('lazygit') }
        @{ Cmd = 'prc'; Base = @('gh', 'pr', 'create') }
        @{ Cmd = 'prv'; Base = @('gh', 'pr', 'view', '--web') }
        @{ Cmd = 'prl'; Base = @('gh', 'pr', 'list') }
        @{ Cmd = 'prs'; Base = @('gh', 'pr', 'status') }
    )
    foreach ($w in $toolWrappers) {
        Test-Case "$($w.Cmd) runs only its fixed arguments when called bare" {
            Reset-Fake
            $null = & $w.Cmd
            $script:toolCalls.Count -eq 1 -and ($script:toolCalls[0] -join '|') -ceq ($w.Base -join '|')
        }
        Test-Case "$($w.Cmd) appends caller arguments unsplit" {
            Reset-Fake
            $null = & $w.Cmd 'two words' '--flag'
            ($script:toolCalls[0] -join '|') -ceq ((@($w.Base) + 'two words' + '--flag') -join '|')
        }
    }
    Test-Case 'Tool wrappers do not call git' {
        Reset-Fake
        lg; prc; prv; prl; prs
        $script:calls.Count -eq 0
    }

    # --- gf ------------------------------------------------------------------------------
    Test-Case 'gf packs refs, fetches all with prune, then packs refs again' {
        Reset-Fake
        gf
        (Get-Calls) -join ';' -ceq 'pack-refs --all;fetch --all --prune;pack-refs --all'
    }
    Test-Case 'gf forwards extra arguments to fetch only' {
        Reset-Fake
        gf --tags
        (Get-Calls) -join ';' -ceq 'pack-refs --all;fetch --all --prune --tags;pack-refs --all'
    }
    Test-Case 'gf still packs refs afterwards when fetch fails' {
        Reset-Fake
        $script:g.Fail = @('fetch*')
        $null = Get-Output { gf }
        (Get-Calls) -join ';' -ceq 'pack-refs --all;fetch --all --prune;fetch --all --no-prune;pack-refs --all'
    }
    # What Git 2.55 prints when the remote has branches that differ only by case (files ref backend on NTFS).
    $caseCollisionOutput = @(
        "error: You're on a case-insensitive filesystem, and the remote you are"
        'trying to fetch from has references that only differ in casing. It'
        'is impossible to store such references with the ''files'' backend. You'
        ''
        '    git refs migrate --ref-format=reftable'
        ''
        'repository it may not be an option to migrate to reftables.'
        ''
        ' ! [new branch]      x/bar      -> origin/x/bar  (unable to update local ref)'
    )
    Test-Case 'gf treats a fetch that failed only on case-colliding remote branches as a warning' {
        Reset-Fake
        $script:g.FailOnce.Add(@{ Pattern = 'fetch*'; Output = $caseCollisionOutput })
        $out = Get-Output { gf }
        (Get-Calls) -join ';' -ceq 'pack-refs --all;fetch --all --prune;pack-refs --all' -and
        (Test-Line $out '大文字小文字だけ違うリモートブランチ')
    }

    # --- Resolve-GitPullCollision (real files under the scratch dir) ---------------------
    Test-Case 'Resolve lists the upstream tree with quotepath off and returns when it is empty' {
        Reset-Fake
        $script:g.RemoteFiles = @()
        $null = Get-Output { Resolve-GitPullCollision -Upstream 'origin/main' }
        (Get-Calls) -join ';' -ceq '-c core.quotepath=false ls-tree -r --name-only origin/main'
    }
    Test-Case 'Resolve throws when listing the upstream tree fails' {
        Reset-Fake
        $script:g.Fail = @('ls-tree*')
        $msg = $null
        try { Resolve-GitPullCollision -Upstream 'origin/main' } catch { $msg = $_.Exception.Message }
        $msg -like '*ls-tree origin/main failed with exit code 1*' -and -not (Test-Called '*ls-files*')
    }
    Test-Case 'Resolve moves a tracked file that differs from upstream only by case and drops it from the index' {
        Reset-Fake
        $top = New-FakeWorktree
        New-TestFile $top 'foo.cs' 'local body'
        $script:g.RemoteFiles = @('Foo.cs'); $script:g.Tracked = @('foo.cs')
        $out = Get-Output { Resolve-GitPullCollision -Upstream 'origin/main' }
        $moved = Get-BackedUp $top
        $backup = Get-ChildItem -LiteralPath (Join-Path $top '.git\pull-backup') -Recurse -File | Select-Object -First 1
        $moved -contains 'foo.cs' -and -not (Test-TestFile $top 'foo.cs') -and
        (Get-Content -LiteralPath $backup.FullName -Raw) -ceq 'local body' -and
        (Test-Called 'rm --cached --quiet foo.cs') -and (Test-Line $out '(Foo.cs)')
    }
    Test-Case 'Resolve leaves a tracked file whose case matches upstream exactly' {
        Reset-Fake
        $top = New-FakeWorktree
        New-TestFile $top 'foo.cs'
        $script:g.RemoteFiles = @('foo.cs'); $script:g.Tracked = @('foo.cs')
        $null = Get-Output { Resolve-GitPullCollision -Upstream 'origin/main' }
        (Test-TestFile $top 'foo.cs') -and (Get-BackedUp $top).Count -eq 0 -and -not (Test-Called 'rm *')
    }
    Test-Case 'Resolve with -UntrackedOnly never lists or moves tracked files' {
        Reset-Fake
        $top = New-FakeWorktree
        New-TestFile $top 'foo.cs'
        $script:g.RemoteFiles = @('Foo.cs'); $script:g.Tracked = @('foo.cs')
        $null = Get-Output { Resolve-GitPullCollision -Upstream 'origin/main' -UntrackedOnly }
        (Test-TestFile $top 'foo.cs') -and -not (Test-Called '-c core.quotepath=false ls-files') -and
        (Test-Called '-c core.quotepath=false ls-files --others --exclude-standard')
    }
    Test-Case 'Resolve moves an untracked file with the same path as an upstream file, without touching the index' {
        Reset-Fake
        $top = New-FakeWorktree
        New-TestFile $top 'new.txt'
        $script:g.RemoteFiles = @('new.txt'); $script:g.Untracked = @('new.txt')
        $null = Get-Output { Resolve-GitPullCollision -Upstream 'origin/main' }
        (Get-BackedUp $top) -contains 'new.txt' -and -not (Test-TestFile $top 'new.txt') -and -not (Test-Called 'rm *')
    }
    Test-Case 'Resolve matches untracked files case-insensitively and keeps nested directories in the backup' {
        Reset-Fake
        $top = New-FakeWorktree
        New-TestFile $top 'Dir/Sub/a.txt'
        $script:g.RemoteFiles = @('dir/sub/A.TXT'); $script:g.Untracked = @('Dir/Sub/a.txt')
        $null = Get-Output { Resolve-GitPullCollision -Upstream 'origin/main' }
        (Get-BackedUp $top) -contains 'Dir\Sub\a.txt' -and -not (Test-TestFile $top 'Dir/Sub/a.txt')
    }
    Test-Case 'Resolve moves an untracked file that is a directory upstream' {
        Reset-Fake
        $top = New-FakeWorktree
        New-TestFile $top 'Docs'
        $script:g.RemoteFiles = @('docs/readme.md'); $script:g.Untracked = @('Docs')
        $null = Get-Output { Resolve-GitPullCollision -Upstream 'origin/main' }
        (Get-BackedUp $top) -contains 'Docs' -and -not (Test-TestFile $top 'Docs')
    }
    Test-Case 'Resolve moves an untracked file that sits under a path that is a file upstream' {
        Reset-Fake
        $top = New-FakeWorktree
        New-TestFile $top 'lib/x.txt'
        $script:g.RemoteFiles = @('lib'); $script:g.Untracked = @('lib/x.txt')
        $null = Get-Output { Resolve-GitPullCollision -Upstream 'origin/main' }
        (Get-BackedUp $top) -contains 'lib\x.txt' -and -not (Test-TestFile $top 'lib/x.txt')
    }
    Test-Case 'Resolve does nothing when no local file collides' {
        Reset-Fake
        $top = New-FakeWorktree
        New-TestFile $top 'src/a.cs'; New-TestFile $top 'other.txt'
        $script:g.RemoteFiles = @('src/a.cs', 'README.md')
        $script:g.Tracked = @('src/a.cs'); $script:g.Untracked = @('other.txt')
        $null = Get-Output { Resolve-GitPullCollision -Upstream 'origin/main' }
        (Get-BackedUp $top).Count -eq 0 -and (Test-TestFile $top 'src/a.cs') -and (Test-TestFile $top 'other.txt') -and
        -not (Test-Called 'rev-parse*') -and -not (Test-Called 'rm *')
    }
    Test-Case 'Resolve puts every file from one run in a single backup directory' {
        Reset-Fake
        $top = New-FakeWorktree
        New-TestFile $top 'a.txt'; New-TestFile $top 'b.txt'
        $script:g.RemoteFiles = @('a.txt', 'b.txt'); $script:g.Untracked = @('a.txt', 'b.txt')
        $null = Get-Output { Resolve-GitPullCollision -Upstream 'origin/main' }
        $dirs = @(Get-ChildItem -LiteralPath (Join-Path $top '.git\pull-backup') -Directory)
        $dirs.Count -eq 1 -and ((Get-BackedUp $top) | Sort-Object) -join ',' -ceq 'a.txt,b.txt'
    }
    Test-Case 'Resolve skips a tracked file with no working-tree copy (skip-worktree / sparse checkout)' {
        Reset-Fake
        $top = New-FakeWorktree
        $script:g.RemoteFiles = @('Ghost.cs'); $script:g.Tracked = @('ghost.cs')
        $out = Get-Output { Resolve-GitPullCollision -Upstream 'origin/main' }
        (Get-BackedUp $top).Count -eq 0 -and -not (Test-Called 'rm *') -and -not (Test-Line $out '[退避]')
    }
    Test-Case 'Resolve warns and keeps the file and index entry when the move fails because the file is locked' {
        Reset-Fake
        $top = New-FakeWorktree
        New-TestFile $top 'locked.txt'
        $script:g.RemoteFiles = @('LOCKED.txt'); $script:g.Tracked = @('locked.txt')
        $lock = [IO.File]::Open((Join-Path $top 'locked.txt'), 'Open', 'ReadWrite', 'None')
        try { $out = Get-Output { Resolve-GitPullCollision -Upstream 'origin/main' } } finally { $lock.Dispose() }
        (Test-Line $out '退避に失敗 (locked.txt)') -and (Test-TestFile $top 'locked.txt') -and
        (Get-BackedUp $top).Count -eq 0 -and -not (Test-Called 'rm *') -and -not (Test-Line $out '[退避]')
    }
    Test-Case 'Resolve warns but still reports the move when git rm --cached fails' {
        Reset-Fake
        $top = New-FakeWorktree
        New-TestFile $top 'foo.cs'
        $script:g.RemoteFiles = @('Foo.cs'); $script:g.Tracked = @('foo.cs')
        $script:g.Fail = @('rm --cached*')
        $out = Get-Output { Resolve-GitPullCollision -Upstream 'origin/main' }
        (Test-Line $out 'git rm --cached に失敗: foo.cs') -and (Test-Line $out '[退避] foo.cs') -and
        (Get-BackedUp $top) -contains 'foo.cs'
    }

    # --- gpl -----------------------------------------------------------------------------
    Test-Case 'gpl on a clean tree runs pack, fetch, upstream lookup, collision scan, pull, pack in order' {
        Reset-Fake
        $null = Get-Output { gpl }
        $expected = @(
            'pack-refs --all'
            'fetch --prune --quiet'
            'rev-parse --abbrev-ref --symbolic-full-name @{u}'
            'status --porcelain --untracked-files=no'
            'config --get pull.rebase'
            '-c core.quotepath=false ls-tree -r --name-only origin/main'
            '-c core.quotepath=false ls-files'
            '-c core.quotepath=false ls-files --others --exclude-standard'
            'symbolic-ref --short -q HEAD'
            'config --get branch.main.remote'
            'config --get branch.main.merge'
            'pull origin refs/heads/main'
            'pack-refs --all'
        )
        (Get-Calls) -join ';' -ceq ($expected -join ';')
    }
    Test-Case 'gpl forwards its arguments to git pull' {
        Reset-Fake
        $null = Get-Output { gpl --ff-only }
        Test-Called 'pull --ff-only origin refs/heads/main'
    }
    Test-Case 'gpl stops after a failed fetch without stashing or pulling' {
        Reset-Fake
        $script:g.Dirty = 'M file.txt'; $script:g.Fail = @('fetch*')
        $out = Get-Output { gpl }
        (Test-Line $out 'fetch 失敗') -and -not (Test-Called 'pull*') -and -not (Test-Called 'stash*') -and
        -not (Test-Called 'rev-parse*') -and
        (@(Get-Calls | Where-Object { $_ -like 'fetch*' }) -join ';') -ceq 'fetch --prune --quiet;fetch --no-prune --quiet'
    }
    Test-Case 'gpl retries a failed fetch --prune without prune and then pulls' {
        Reset-Fake
        $script:g.FailOnce.Add(@{ Pattern = 'fetch --prune*'; Output = "error: cannot lock ref 'refs/remotes/origin/Feature/b'" })
        $out = Get-Output { gpl }
        (Test-Line $out 'prune を外して取得し直す') -and (Test-Called 'fetch --no-prune --quiet') -and
        -not (Test-Line $out 'fetch 失敗') -and (Test-Called 'pull origin refs/heads/main')
    }
    Test-Case 'gpl warns and carries on when fetch fails only on case-colliding remote branches' {
        Reset-Fake
        $script:g.FailOnce.Add(@{ Pattern = 'fetch*'; Output = $caseCollisionOutput })
        $out = Get-Output { gpl }
        (Test-Line $out 'unable to update local ref') -and (Test-Line $out '大文字小文字だけ違うリモートブランチ') -and
        -not (Test-Line $out 'case-insensitive filesystem') -and -not (Test-Line $out 'impossible to store') -and
        -not (Test-Line $out 'fetch 失敗') -and (Test-Called 'pull origin refs/heads/main') -and
        @(Get-Calls | Where-Object { $_ -like 'fetch*' }).Count -eq 1
    }
    Test-Case 'gpl keeps explicit repository and branch arguments as given' {
        Reset-Fake
        $null = Get-Output { gpl --rebase upstream dev }
        (Test-Called 'pull --rebase upstream dev') -and -not (Test-Called 'symbolic-ref*')
    }
    Test-Case 'gpl warns and stops when there is no upstream and no arguments' {
        Reset-Fake
        $script:g.Upstream = $null
        $out = Get-Output { gpl }
        (Test-Line $out 'upstream 未設定') -and -not (Test-Called 'pull*') -and -not (Test-Called 'status*')
    }
    Test-Case 'gpl without an upstream but with explicit arguments pulls them and skips the collision scan' {
        Reset-Fake
        $script:g.Upstream = $null
        $null = Get-Output { gpl origin main }
        (Test-Called 'pull origin main') -and -not (Test-Called '*ls-tree*')
    }
    Test-Case 'gpl warns twice but carries on when pack-refs is blocked' {
        Reset-Fake
        $script:g.Fail = @('pack-refs*')
        $out = Get-Output { gpl }
        @($out | Where-Object { $_.Contains('pack-refs をスキップ') }).Count -eq 2 -and (Test-Called 'pull origin refs/heads/main')
    }
    Test-Case 'gpl on a clean tree never stashes' {
        Reset-Fake
        $null = Get-Output { gpl }
        -not (Test-Called 'stash*')
    }
    Test-Case 'gpl stashes dirty changes before the pull and pops them afterwards' {
        Reset-Fake
        $script:g.Dirty = 'M file.txt'
        $null = Get-Output { gpl }
        $push = Get-CallIndex 'stash push --quiet -m gpl: auto stash before pull'
        $pull = Get-CallIndex 'pull origin refs/heads/main'
        $pop = Get-CallIndex 'stash pop --quiet'
        $c = @(Get-Calls)
        $push -ge 0 -and $push -lt $pull -and $pull -lt $pop -and $c[-1] -ceq 'pack-refs --all'
    }
    Test-Case 'gpl stops without pulling when the stash fails' {
        Reset-Fake
        $script:g.Dirty = 'M file.txt'; $script:g.Fail = @('stash push*')
        $out = Get-Output { gpl }
        (Test-Line $out 'stash 失敗') -and -not (Test-Called 'pull*')
    }
    Test-Case 'gpl does not pop an older stash when stash push created nothing' {
        Reset-Fake
        $script:g.Dirty = 'M submodule'; $script:g.StashRef = 'old-stash'; $script:g.StashCreates = $false
        $null = Get-Output { gpl }
        (Test-Called 'stash push*') -and (Test-Called 'pull origin refs/heads/main') -and -not (Test-Called 'stash pop*')
    }
    Test-Case 'gpl pops the new stash even when an older stash already exists' {
        Reset-Fake
        $script:g.Dirty = 'M file.txt'; $script:g.StashRef = 'old-stash'
        $null = Get-Output { gpl }
        Test-Called 'stash pop --quiet'
    }
    Test-Case 'gpl reports a failed pull, keeps the stash and does not pop or repack' {
        Reset-Fake
        $script:g.Dirty = 'M file.txt'; $script:g.Fail = @('pull*')
        $out = Get-Output { gpl }
        $c = @(Get-Calls)
        (Test-Line $out 'pull 失敗') -and (Test-Line $out 'git stash pop') -and
        -not (Test-Called 'stash pop*') -and $c[-1] -ceq 'pull origin refs/heads/main'
    }
    Test-Case 'gpl omits the stash hint when a failed pull had nothing stashed' {
        Reset-Fake
        $script:g.Fail = @('pull*')
        $out = Get-Output { gpl }
        (Test-Line $out 'pull 失敗') -and -not (Test-Line $out 'git stash pop')
    }
    Test-Case 'gpl reports a conflicting stash restore and skips the final repack' {
        Reset-Fake
        $script:g.Dirty = 'M file.txt'; $script:g.Fail = @('stash pop*')
        $out = Get-Output { gpl }
        $c = @(Get-Calls)
        (Test-Line $out 'stash の復元で競合') -and $c[-1] -ceq 'stash pop --quiet'
    }
    Test-Case 'gpl aborts before pulling when the collision scan fails and mentions the stash' {
        Reset-Fake
        $script:g.Dirty = 'M file.txt'; $script:g.Fail = @('ls-tree*')
        $out = Get-Output { gpl }
        (Test-Line $out '衝突ファイルの退避に失敗') -and (Test-Line $out 'git stash pop') -and
        -not (Test-Called 'pull*') -and -not (Test-Called 'stash pop*')
    }
    Test-Case 'gpl moves a colliding untracked file before pulling' {
        Reset-Fake
        $top = New-FakeWorktree
        New-TestFile $top 'new.txt'
        $script:g.RemoteFiles = @('new.txt'); $script:g.Untracked = @('new.txt')
        $null = Get-Output { gpl }
        (Get-BackedUp $top) -contains 'new.txt' -and (Test-Called 'pull origin refs/heads/main')
    }

    # pull.rebase / argument detection decides whether tracked files are scanned. The tracked listing is
    # the plain "ls-files" call; rebase mode (UntrackedOnly) must not make it.
    $rebaseCases = @(
        @{ Name = 'pull.rebase=true'; Config = 'true'; Args = @(); Rebase = $true }
        @{ Name = 'pull.rebase=false'; Config = 'false'; Args = @(); Rebase = $false }
        @{ Name = 'pull.rebase unset'; Config = $null; Args = @(); Rebase = $false }
        @{ Name = '--rebase'; Config = $null; Args = @('--rebase'); Rebase = $true }
        @{ Name = '-r'; Config = $null; Args = @('-r'); Rebase = $true }
        @{ Name = '--rebase=merges'; Config = $null; Args = @('--rebase=merges'); Rebase = $true }
        @{ Name = '--rebase over pull.rebase=false'; Config = 'false'; Args = @('--rebase'); Rebase = $true }
        @{ Name = '--no-rebase over pull.rebase=true'; Config = 'true'; Args = @('--no-rebase'); Rebase = $false }
        @{ Name = '--rebase=false over pull.rebase=true'; Config = 'true'; Args = @('--rebase=false'); Rebase = $false }
    )
    foreach ($r in $rebaseCases) {
        Test-Case "gpl treats $($r.Name) as rebase=$($r.Rebase) when deciding what to scan" {
            Reset-Fake
            $script:g.Rebase = $r.Config
            $null = Get-Output { gpl @($r.Args) }
            $scannedTracked = Test-Called '-c core.quotepath=false ls-files'
            $scannedTracked -eq (-not $r.Rebase)
        }
    }

    # --- git-clone / git-root (real Set-Location inside scratch dirs) ---------------------------
    Test-Case 'git-clone clones the URL and enters the directory named after the repository' {
        Reset-Fake
        $dir = New-ScratchDir
        $script:g.CloneDir = 'repo'
        Push-Location -LiteralPath $dir
        try { $null = Get-Output { git-clone 'https://github.com/o/repo.git' }; $here = (Get-Location).Path } finally { Pop-Location }
        ($script:calls[0] -join '|') -ceq 'clone|https://github.com/o/repo.git' -and (Split-Path -Leaf $here) -eq 'repo'
    }
    Test-Case 'git-clone handles a trailing slash and a URL without .git' {
        Reset-Fake
        $dir = New-ScratchDir
        $script:g.CloneDir = 'proj'
        Push-Location -LiteralPath $dir
        try { $null = Get-Output { git-clone 'https://host.example/o/proj/' }; $here = (Get-Location).Path } finally { Pop-Location }
        (Split-Path -Leaf $here) -eq 'proj'
    }
    Test-Case 'git-clone handles an scp-style URL' {
        Reset-Fake
        $dir = New-ScratchDir
        $script:g.CloneDir = 'scp-repo'
        Push-Location -LiteralPath $dir
        try { $null = Get-Output { git-clone 'git@github.com:o/scp-repo.git' }; $here = (Get-Location).Path } finally { Pop-Location }
        (Split-Path -Leaf $here) -eq 'scp-repo'
    }
    Test-Case 'git-clone stays put when git clone fails, even if the directory exists' {
        Reset-Fake
        $dir = New-ScratchDir
        New-Item -ItemType Directory -Path (Join-Path $dir 'repo') | Out-Null
        $script:g.Fail = @('clone*')
        Push-Location -LiteralPath $dir
        try { $null = Get-Output { git-clone 'https://github.com/o/repo.git' }; $here = (Get-Location).Path } finally { Pop-Location }
        $here -eq $dir
    }
    Test-Case 'git-clone stays put when the clone succeeded but the directory is missing' {
        Reset-Fake
        $dir = New-ScratchDir
        Push-Location -LiteralPath $dir
        try { $null = Get-Output { git-clone 'https://github.com/o/repo.git' }; $here = (Get-Location).Path } finally { Pop-Location }
        $here -eq $dir
    }
    Test-Case 'git-root changes to the repository top level' {
        Reset-Fake
        $top = New-ScratchDir
        $elsewhere = New-ScratchDir
        $script:g.Top = $top
        Push-Location -LiteralPath $elsewhere
        try { $null = Get-Output { git-root }; $here = (Get-Location).Path } finally { Pop-Location }
        $here -eq $top -and ($script:calls[0] -join '|') -ceq 'rev-parse|--show-toplevel'
    }
    Test-Case 'git-root warns and stays put outside a repository' {
        Reset-Fake
        $elsewhere = New-ScratchDir
        Push-Location -LiteralPath $elsewhere
        try { $out = Get-Output { git-root }; $here = (Get-Location).Path } finally { Pop-Location }
        (Test-Line $out 'Not a git repository') -and $here -eq $elsewhere
    }

    # --- git-log-browse ----------------------------------------------------------------------------
    Test-Case 'git-log-browse warns and runs nothing without fzf' {
        Reset-Fake
        $script:_cmdCache['fzf'] = $false
        $out = Get-Output { git-log-browse }
        (Test-Line $out 'git-log-browse needs fzf') -and $script:calls.Count -eq 0 -and $null -eq $script:fzfArgs
    }
    Test-Case 'git-log-browse feeds the colored log to fzf with a plain git show preview when delta is absent' {
        Reset-Fake
        $script:g.LogLines = @('abc1234 first', 'def5678 second')
        $null = Get-Output { git-log-browse }
        ($script:calls[0] -join '|') -ceq 'log|--color=always|--format=%C(auto)%h %s %C(dim)%an, %ar' -and
        ($script:fzfArgs -join '|') -ceq '--ansi|--no-sort|--reverse|--preview|git show --color=always {1}' -and
        ($script:fzfInput -join '|') -ceq 'abc1234 first|def5678 second'
    }
    Test-Case 'git-log-browse pipes the preview through delta when it is available' {
        Reset-Fake
        $script:_cmdCache['delta'] = $true
        $null = Get-Output { git-log-browse }
        $script:fzfArgs[-1] -ceq 'git show --color=always {1} | delta'
    }
    Test-Case 'git-log-browse passes extra arguments to git log' {
        Reset-Fake
        $null = Get-Output { git-log-browse --author=me -5 }
        ($script:calls[0] -join '|') -ceq 'log|--color=always|--format=%C(auto)%h %s %C(dim)%an, %ar|--author=me|-5'
    }

    # --- git-switch ----------------------------------------------------------------------
    Test-Case 'git-switch warns and runs nothing without fzf' {
        Reset-Fake
        $script:_cmdCache['fzf'] = $false
        $out = Get-Output { git-switch }
        (Test-Line $out 'git-switch needs fzf') -and $script:calls.Count -eq 0
    }
    Test-Case 'git-switch offers sorted unique branches without blanks or origin/HEAD' {
        Reset-Fake
        $script:g.Branches = @('topic', '', 'origin/topic', 'origin/HEAD', 'topic')
        $script:fzfPick = $null
        $null = Get-Output { git-switch }
        ($script:calls[0] -join '|') -ceq 'branch|--all|--format=%(refname:short)' -and
        ($script:fzfInput -join '|') -ceq 'origin/topic|topic'
    }
    Test-Case 'git-switch does nothing when the picker is cancelled' {
        Reset-Fake
        $script:g.Branches = @('main')
        $script:fzfPick = $null
        $null = Get-Output { git-switch }
        $script:calls.Count -eq 1
    }
    Test-Case 'git-switch checks out an existing local branch directly' {
        Reset-Fake
        $script:g.Branches = @('main'); $script:g.LocalBranches = @('main')
        $script:fzfPick = 'main'
        $null = Get-Output { git-switch }
        $c = @(Get-Calls)
        $c[1] -ceq 'rev-parse --verify --quiet refs/heads/main' -and $c[2] -ceq 'checkout main' -and $c.Count -eq 3
    }
    Test-Case 'git-switch picking origin/x checks out the existing local x' {
        Reset-Fake
        $script:g.LocalBranches = @('topic')
        $script:fzfPick = 'origin/topic'
        $null = Get-Output { git-switch }
        (Test-Called 'checkout topic') -and -not (Test-Called 'checkout -b*')
    }
    Test-Case 'git-switch picking origin/x creates a tracking branch when no local x exists' {
        Reset-Fake
        $script:fzfPick = 'origin/topic'
        $null = Get-Output { git-switch }
        (Get-Calls)[-1] -ceq 'checkout -b topic --track origin/topic'
    }
    Test-Case 'git-switch keeps slashes inside the branch name and trims the selection' {
        Reset-Fake
        $script:fzfPick = '  origin/feature/x  '
        $null = Get-Output { git-switch }
        (Test-Called 'rev-parse --verify --quiet refs/heads/feature/x') -and
        (Get-Calls)[-1] -ceq 'checkout -b feature/x --track origin/feature/x'
    }

    # --- git-clean-branches --------------------------------------------------------------
    $mergedList = @('* main', '  feature/a', '  feature/b', '  develop', '  master', '+ wt-branch')
    Test-Case 'git-clean-branches deletes merged branches except current and protected ones, stripping markers' {
        Reset-Fake
        $script:g.Merged = $mergedList
        $out = Get-Output { git-clean-branches }
        $deleted = @(Get-Calls | Where-Object { $_ -like 'branch -d *' })
        ($deleted -join ';') -ceq 'branch -d feature/a;branch -d feature/b;branch -d wt-branch' -and
        (Test-Line $out '  feature/a') -and $script:prompts.Count -eq 1
    }
    Test-Case 'git-clean-branches honors a custom -Protected list' {
        Reset-Fake
        $script:g.Merged = @('* main', '  develop', '  keep')
        $null = Get-Output { git-clean-branches -Protected 'keep' }
        $deleted = @(Get-Calls | Where-Object { $_ -like 'branch -d *' })
        ($deleted -join ';') -ceq 'branch -d develop'
    }
    Test-Case 'git-clean-branches reports nothing to do without prompting' {
        Reset-Fake
        $script:g.Merged = @('* main', '  develop')
        $out = Get-Output { git-clean-branches }
        (Test-Line $out 'No merged branches to delete.') -and $script:prompts.Count -eq 0 -and
        -not (Test-Called 'branch -d*')
    }
    foreach ($yes in 'y', 'Y', 'yes', 'YES') {
        Test-Case "git-clean-branches deletes after the answer '$yes'" {
            Reset-Fake
            $script:g.Merged = @('* main', '  feature/a')
            $script:answer = $yes
            $null = Get-Output { git-clean-branches }
            Test-Called 'branch -d feature/a'
        }
    }
    foreach ($no in 'n', '', 'no', 'yy', 'yes please') {
        Test-Case "git-clean-branches aborts without deleting after the answer '$no'" {
            Reset-Fake
            $script:g.Merged = @('* main', '  feature/a')
            $script:answer = $no
            $out = Get-Output { git-clean-branches }
            (Test-Line $out 'Aborted.') -and -not (Test-Called 'branch -d*')
        }
    }

    # --- git-reset-clean ------------------------------------------------------------------------
    Test-Case 'git-reset-clean reports an already clean tree without resetting' {
        Reset-Fake
        $top = New-FakeWorktree
        $out = Get-Output { git-reset-clean }
        (Test-Line $out 'Already clean.') -and $script:prompts.Count -eq 0 -and
        (Get-Calls) -join ';' -ceq "rev-parse --show-toplevel;-C $top status --porcelain;-C $top -c core.quotepath=false clean -ffdxn"
    }
    Test-Case 'git-reset-clean resets hard then cleans at the repo root without prompting' {
        Reset-Fake
        $top = New-FakeWorktree
        $script:g.Dirty = 'M a.txt'; $script:g.CleanPreview = @('Would remove junk/')
        $out = Get-Output { git-reset-clean }
        $reset = Get-CallIndex "-C $top reset --hard HEAD"
        $clean = Get-CallIndex "-C $top clean -ffdx"
        $script:prompts.Count -eq 0 -and $reset -ge 0 -and $reset -lt $clean -and
        (Test-Line $out 'removing 1 untracked/ignored item(s)') -and (Test-Line $out '  junk/') -and
        -not (Test-Line $out 'Could not remove')
    }
    Test-Case 'git-reset-clean -Ref resets to that ref' {
        Reset-Fake
        $top = New-FakeWorktree
        $script:g.Dirty = 'M a.txt'
        $out = Get-Output { git-reset-clean -Ref origin/main }
        (Test-Called "-C $top reset --hard origin/main") -and (Test-Line $out 'git reset --hard origin/main') -and
        -not (Test-Called '*reset --hard HEAD')
    }
    Test-Case 'git-reset-clean proceeds when only untracked or ignored files exist' {
        Reset-Fake
        $top = New-FakeWorktree
        $script:g.CleanPreview = @('Would remove build/')
        $null = Get-Output { git-reset-clean }
        (Test-Called "-C $top reset --hard HEAD") -and (Test-Called "-C $top clean -ffdx")
    }
    Test-Case 'git-reset-clean ignores the refusal to remove the current directory' {
        Reset-Fake
        $null = New-FakeWorktree
        $script:g.CleanPreview = @('Would refuse to remove current working directory')
        $out = Get-Output { git-reset-clean }
        Test-Line $out 'Already clean.'
    }
    Test-Case 'git-reset-clean deletes what git clean left behind (reserved names) through a \\?\ path' {
        Reset-Fake
        $top = New-FakeWorktree
        New-TestFile $top 'nul'
        New-TestFile $top 'deep/nul'
        $script:g.CleanPreview = @('Would remove nul', 'Would remove deep/')
        $script:g.CleanLeft = @('Would remove nul', 'Would remove deep/')
        $out = Get-Output { git-reset-clean }
        -not (Test-TestFile $top 'nul') -and -not (Test-Path -LiteralPath (Join-Path $top 'deep')) -and
        -not (Test-Line $out 'Could not remove')
    }
    Test-Case 'git-reset-clean throws outside a repository' {
        Reset-Fake
        $msg = $null
        try { $null = Get-Output { git-reset-clean } } catch { $msg = $_.Exception.Message }
        $msg -like '*git rev-parse --show-toplevel failed*' -and -not (Test-Called '*reset*')
    }
    Test-Case 'git-reset-clean throws and skips the clean when reset fails' {
        Reset-Fake
        $null = New-FakeWorktree
        $script:g.Dirty = 'M a.txt'; $script:g.Fail = @('reset*')
        $msg = $null
        try { $null = Get-Output { git-reset-clean } } catch { $msg = $_.Exception.Message }
        $msg -like '*git reset --hard HEAD failed with exit code 1*' -and -not (Test-Called '*clean -ffdx')
    }
    Test-Case 'git-reset-clean throws when the clean fails' {
        Reset-Fake
        $null = New-FakeWorktree
        $script:g.Dirty = 'M a.txt'; $script:g.Fail = @('clean -ffdx')
        $msg = $null
        try { $null = Get-Output { git-reset-clean } } catch { $msg = $_.Exception.Message }
        $msg -like '*git clean -ffdx failed with exit code 1*' -and (Test-Called '*reset --hard HEAD')
    }

    # --- gita-scan -----------------------------------------------------------------------
    Test-Case 'gita-scan warns and registers nothing without gita' {
        Reset-Fake
        $script:_cmdCache['gita'] = $false
        $out = Get-Output { gita-scan }
        (Test-Line $out 'gita-scan needs gita') -and $script:gitaCalls.Count -eq 0
    }
    Test-Case 'gita-scan warns about a missing path' {
        Reset-Fake
        $missing = Join-Path $scratch 'does-not-exist'
        $out = Get-Output { gita-scan -Path $missing }
        (Test-Line $out "Path not found: $missing") -and $script:gitaCalls.Count -eq 0
    }
    Test-Case 'gita-scan reports when neither the directory nor its children are repositories' {
        Reset-Fake
        $d = New-ScratchDir
        New-Item -ItemType Directory -Path (Join-Path $d 'plain') | Out-Null
        $out = Get-Output { gita-scan -Path $d }
        (Test-Line $out 'No git repos found') -and $script:gitaCalls.Count -eq 0
    }
    Test-Case 'gita-scan registers the root and direct child repos only, including .git files and hidden dirs' {
        Reset-Fake
        $d = New-ScratchDir
        New-Item -ItemType Directory -Path (Join-Path $d '.git') | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $d 'a\.git') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $d 'plain') | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $d 'worktree') | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'worktree\.git') -Value 'gitdir: elsewhere'
        New-Item -ItemType Directory -Path (Join-Path $d 'deep\nested\.git') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $d 'hid\.git') -Force | Out-Null
        (Get-Item -LiteralPath (Join-Path $d 'hid')).Attributes = 'Directory, Hidden'
        $full = (Resolve-Path -LiteralPath $d).Path
        $out = Get-Output { gita-scan -Path $d }
        $added = @($script:gitaCalls | ForEach-Object { $_[1] } | Sort-Object)
        $expected = @($full, (Join-Path $full 'a'), (Join-Path $full 'hid'), (Join-Path $full 'worktree')) | Sort-Object
        ($script:gitaCalls | ForEach-Object { $_[0] } | Select-Object -Unique) -ceq 'add' -and
        ($added -join ';') -ceq ($expected -join ';') -and (Test-Line $out 'Registered 4 repo(s) with gita.')
    }
    Test-Case 'gita-scan defaults to the current directory' {
        Reset-Fake
        $d = New-ScratchDir
        New-Item -ItemType Directory -Path (Join-Path $d '.git') | Out-Null
        Push-Location -LiteralPath $d
        try { $null = Get-Output { gita-scan } } finally { Pop-Location }
        $script:gitaCalls.Count -eq 1 -and $script:gitaCalls[0][1] -eq (Resolve-Path -LiteralPath $d).Path
    }

    # --- gita-pull-all ------------------------------------------------------------------
    Test-Case 'gita-pull-all warns and does nothing without gita' {
        Reset-Fake
        $script:_cmdCache['gita'] = $false
        $out = Get-Output { gita-pull-all }
        (Test-Line $out 'gita-pull-all needs gita') -and $script:calls.Count -eq 0 -and $script:gitaCalls.Count -eq 0
    }
    Test-Case 'gita-pull-all warns when gita has no repositories' {
        Reset-Fake
        $out = Get-Output { gita-pull-all }
        (Test-Line $out 'No repos registered in gita') -and $script:calls.Count -eq 0
    }
    Test-Case 'gita-pull-all fetches then fast-forward pulls a repo whose branch has an origin counterpart' {
        Reset-Fake
        $repo = New-FakeRepo 'alpha'
        $null = Get-Output { gita-pull-all }
        $expected = @(
            "-C $repo ls-files"
            "-C $repo ls-files --others --exclude-standard"
            "-C $repo fetch --prune --quiet"
            "-C $repo rev-parse --abbrev-ref HEAD"
            "-C $repo rev-parse --verify --quiet origin/main"
            "-C $repo pull --ff-only"
        )
        (Get-Calls) -join ';' -ceq ($expected -join ';')
    }
    Test-Case 'gita-pull-all switches to the fallback branch when the current one has no origin branch' {
        Reset-Fake
        $repo = New-FakeRepo 'alpha' @{ Branch = 'wip'; HasOrigin = $false }
        $out = Get-Output { gita-pull-all }
        $c = @(Get-Calls)
        $co = $c.IndexOf("-C $repo checkout main")
        (Test-Line $out 'no origin/wip -> switching to main') -and $co -ge 0 -and $c[-1] -ceq "-C $repo pull --ff-only" -and
        $c.IndexOf("-C $repo rev-parse --verify --quiet origin/wip") -lt $co
    }
    Test-Case 'gita-pull-all -Fallback selects the branch to switch to' {
        Reset-Fake
        $repo = New-FakeRepo 'alpha' @{ Branch = 'wip'; HasOrigin = $false }
        $null = Get-Output { gita-pull-all -Fallback develop }
        (Test-Called "-C $repo checkout develop") -and -not (Test-Called "-C $repo checkout main")
    }
    Test-Case 'gita-pull-all warns and skips the pull when the fallback checkout fails, then continues with the next repo' {
        Reset-Fake
        $bad = New-FakeRepo 'alpha' @{ Branch = 'wip'; HasOrigin = $false }
        $good = New-FakeRepo 'beta'
        $script:g.Fail = @('checkout*')
        $out = Get-Output { gita-pull-all }
        (Test-Line $out 'checkout main failed') -and -not (Test-Called "-C $bad pull*") -and (Test-Called "-C $good pull --ff-only")
    }
    Test-Case 'gita-pull-all warns about a registered path that no longer exists and continues' {
        Reset-Fake
        $good = New-FakeRepo 'beta'
        $ghost = Join-Path $scratch 'ghost-repo'
        $script:g.GitaNames = @('ghost', 'beta')
        $script:g.GitaPaths['ghost'] = $ghost
        $out = Get-Output { gita-pull-all }
        (Test-Line $out "path not found: $ghost") -and -not (Test-Called "-C $ghost*") -and (Test-Called "-C $good pull --ff-only")
    }
    Test-Case 'gita-pull-all accepts gita ls output as one space-separated line' {
        Reset-Fake
        $a = New-FakeRepo 'alpha'
        $b = New-FakeRepo 'beta'
        $script:g.GitaNames = @('alpha beta')
        $null = Get-Output { gita-pull-all }
        (Test-Called "-C $a pull --ff-only") -and (Test-Called "-C $b pull --ff-only")
    }
    Test-Case 'gita-pull-all removes stray nul files (tracked or untracked, once each) and nothing else' {
        Reset-Fake
        $repo = New-FakeRepo 'alpha' @{
            Tracked   = @('nul', 'sub/nul', 'src/nullable.txt', 'nul.txt')
            Untracked = @('other/nul', 'nul')
        }
        foreach ($f in 'nul', 'sub/nul', 'other/nul', 'nul.txt', 'src/nullable.txt') { New-TestFile $repo $f }
        $out = Get-Output { gita-pull-all }
        $removedLines = @($out | Where-Object { $_.Contains('removed stray file:') })
        -not (Test-TestFile $repo 'nul') -and -not (Test-TestFile $repo 'sub/nul') -and -not (Test-TestFile $repo 'other/nul') -and
        (Test-TestFile $repo 'nul.txt') -and (Test-TestFile $repo 'src/nullable.txt') -and
        $removedLines.Count -eq 3 -and (Test-Line $out 'removed stray file: sub/nul')
    }
    Test-Case 'gita-pull-all removes stray files before it fetches' {
        Reset-Fake
        $repo = New-FakeRepo 'alpha' @{ Tracked = @('nul') }
        New-TestFile $repo 'nul'
        $null = Get-Output { gita-pull-all }
        (Get-CallIndex "-C $repo ls-files*") -ge 0 -and (Get-CallIndex "-C $repo ls-files*") -lt (Get-CallIndex "-C $repo fetch*")
    }

    Test-Case 'gita-pull-all switches a detached HEAD to the fallback branch without probing origin/HEAD' {
        Reset-Fake
        $repo = New-FakeRepo 'alpha' @{ Branch = 'HEAD' }
        $out = Get-Output { gita-pull-all }
        (Test-Line $out 'detached HEAD -> switching to main') -and (Test-Called "-C $repo checkout main") -and
        -not (Test-Called "-C $repo rev-parse --verify --quiet origin/HEAD") -and (Test-Called "-C $repo pull --ff-only")
    }
    Test-Case 'gita-pull-all skips the pull when fetch fails and lists the repo at the end' {
        Reset-Fake
        $repo = New-FakeRepo 'alpha'
        $script:g.Fail = @('fetch*')
        $out = Get-Output { gita-pull-all }
        (Test-Line $out 'fetch failed') -and -not (Test-Called "-C $repo pull*") -and
        (Test-Line $out '1 of 1 repo(s) failed: alpha (fetch)')
    }
    Test-Case 'gita-pull-all skips a repo whose HEAD cannot be read' {
        Reset-Fake
        $repo = New-FakeRepo 'alpha'
        $script:g.Fail = @('rev-parse --abbrev-ref HEAD')
        $out = Get-Output { gita-pull-all }
        (Test-Line $out 'cannot read HEAD') -and -not (Test-Called "-C $repo pull*") -and (Test-Line $out 'alpha (HEAD)')
    }
    Test-Case 'gita-pull-all lists every failed repo at the end and stays quiet when all succeed' {
        Reset-Fake
        $null = New-FakeRepo 'alpha'
        $b = New-FakeRepo 'beta'
        $ok = Get-Output { gita-pull-all }
        $script:calls.Clear()
        $script:g.FailOnce.Add(@{ Pattern = 'pull*'; Output = 'fatal: Not possible to fast-forward' })
        $ghost = Join-Path $scratch 'ghost-repo'
        $script:g.GitaNames += 'ghost'
        $script:g.GitaPaths['ghost'] = $ghost
        $out = Get-Output { gita-pull-all }
        -not (Test-Line $ok 'failed') -and (Test-Line $out 'pull failed') -and (Test-Called "-C $b pull --ff-only") -and
        (Test-Line $out '2 of 3 repo(s) failed: alpha (pull), ghost (path not found)')
    }

    # --- gita-doctor --------------------------------------------------------------------
    # Registry with one healthy repo and one entry for each kind of problem.
    function New-GitaRegistry {
        $good = New-FakeRepo 'good'
        $notRepo = New-FakeRepo 'plain' @{ NotRepo = $true }
        $noName = New-FakeRepo 'noname'
        $ghost = Join-Path $scratch 'ghost-repo'
        $csv = Join-Path (New-ScratchDir) 'repos.csv'
        Set-Content -LiteralPath $csv -Value @("$good,good,,", "$notRepo,plain,,", "$noName,,,", "$ghost,ghost,,")
        @{ Csv = $csv; Good = "$good,good,," }
    }
    Test-Case 'gita-doctor warns about a missing registry' {
        Reset-Fake
        $out = Get-Output { gita-doctor -Path (Join-Path $scratch 'none.csv') }
        Test-Line $out 'gita registry not found'
    }
    Test-Case 'gita-doctor reports a healthy registry without prompting' {
        Reset-Fake
        $good = New-FakeRepo 'good'
        $csv = Join-Path (New-ScratchDir) 'repos.csv'
        Set-Content -LiteralPath $csv -Value "$good,good,,"
        $out = Get-Output { gita-doctor -Path $csv }
        (Test-Line $out 'No problems in 1 gita entries.') -and $script:prompts.Count -eq 0
    }
    Test-Case 'gita-doctor lists every kind of broken entry and removes them on yes, keeping a backup' {
        Reset-Fake
        $r = New-GitaRegistry
        $before = Get-Content -LiteralPath $r.Csv -Raw
        $out = Get-Output { gita-doctor -Path $r.Csv }
        (Test-Line $out 'not a git repository') -and (Test-Line $out 'empty name') -and (Test-Line $out 'folder not found') -and
        (Test-Line $out 'Removed 3 entries') -and
        ((Get-Content -LiteralPath $r.Csv) -join ';') -ceq $r.Good -and
        (Get-Content -LiteralPath "$($r.Csv).bak" -Raw) -ceq $before
    }
    Test-Case 'gita-doctor changes nothing when the prompt is declined' {
        Reset-Fake
        $r = New-GitaRegistry
        $before = Get-Content -LiteralPath $r.Csv -Raw
        $script:answer = 'n'
        $out = Get-Output { gita-doctor -Path $r.Csv }
        (Test-Line $out 'Aborted.') -and (Get-Content -LiteralPath $r.Csv -Raw) -ceq $before -and -not (Test-Path -LiteralPath "$($r.Csv).bak")
    }
    # Registry file with one line per given repo path / name.
    function New-GitaCsv([string[]]$Lines) {
        $csv = Join-Path (New-ScratchDir) 'repos.csv'
        Set-Content -LiteralPath $csv -Value $Lines
        $csv
    }
    Test-Case 'gita-doctor reports a repo whose git status fails, with the git error, and keeps its entry' {
        Reset-Fake
        $repo = New-FakeRepo 'corrupt' @{ StatusError = @('error: object file .git/objects/aa/bb is empty', 'fatal: bad object HEAD') }
        $csv = New-GitaCsv "$repo,corrupt,,"
        $before = Get-Content -LiteralPath $csv -Raw
        $out = Get-Output { gita-doctor -Path $csv }
        (Test-Line $out 'Broken repos') -and (Test-Line $out 'git status failed: error: object file .git/objects/aa/bb is empty') -and
        (Test-Line $out 're-clone') -and $script:prompts.Count -eq 0 -and (Get-Content -LiteralPath $csv -Raw) -ceq $before
    }
    Test-Case 'gita-doctor suggests safe.directory for a dubious-ownership repo and an index rebuild for a broken index' {
        Reset-Fake
        $owned = New-FakeRepo 'owned' @{ StatusError = "fatal: detected dubious ownership in repository at 'x'" }
        $idx = New-FakeRepo 'idx' @{ StatusError = 'fatal: .git/index: index file smaller than expected' }
        $csv = New-GitaCsv @("$owned,owned,,", "$idx,idx,,")
        $out = Get-Output { gita-doctor -Path $csv }
        (Test-Line $out "safe.directory '$($owned -replace '\\', '/')'") -and (Test-Line $out 'git reset')
    }
    Test-Case 'gita-doctor reports stale lock files in the git dir and under refs' {
        Reset-Fake
        $repo = New-FakeRepo 'locked'
        New-TestFile $repo '.git/index.lock'
        New-TestFile $repo '.git/refs/heads/main.lock'
        New-TestFile $repo '.git/refs/heads/main'
        $out = Get-Output { gita-doctor -Path (New-GitaCsv "$repo,locked,,") }
        (Test-Line $out 'stale lock file: index.lock') -and (Test-Line $out 'main.lock') -and
        @($out | Where-Object { $_.Contains('stale lock file') }).Count -eq 2
    }
    Test-Case 'gita-doctor reports a rebase left in progress' {
        Reset-Fake
        $repo = New-FakeRepo 'rebasing'
        New-Item -ItemType Directory -Path (Join-Path $repo '.git\rebase-merge') | Out-Null
        $out = Get-Output { gita-doctor -Path (New-GitaCsv "$repo,rebasing,,") }
        (Test-Line $out 'rebase in progress') -and (Test-Line $out 'git rebase --abort')
    }
    Test-Case 'gita-doctor runs git fsck only with -Deep' {
        Reset-Fake
        $repo = New-FakeRepo 'deep' @{ FsckError = @('missing blob 1234', 'error: 1234: object corrupt or missing') }
        $csv = New-GitaCsv "$repo,deep,,"
        $plain = Get-Output { gita-doctor -Path $csv }
        $fsckBefore = Test-Called '*fsck*'
        $deep = Get-Output { gita-doctor -Path $csv -Deep }
        (Test-Line $plain 'No problems in 1 gita entries.') -and -not $fsckBefore -and
        (Test-Line $deep 'git fsck failed: error: 1234: object corrupt or missing')
    }
    Test-Case 'gita-doctor reads a quoted path containing a comma and accepts a bare repo' {
        Reset-Fake
        $comma = New-FakeRepo 'a,b'
        $bare = New-FakeRepo 'bare' @{ Bare = $true }
        $out = Get-Output { gita-doctor -Path (New-GitaCsv @("`"$comma`",ab,,", "$bare,bare,,")) }
        Test-Line $out 'No problems in 2 gita entries.'
    }
    Test-Case 'gita-doctor shows broken repos and still offers to remove only the bad entries' {
        Reset-Fake
        $r = New-GitaRegistry
        $broken = New-FakeRepo 'broken' @{ StatusError = 'fatal: bad object HEAD' }
        Add-Content -LiteralPath $r.Csv -Value "$broken,broken,,"
        $out = Get-Output { gita-doctor -Path $r.Csv }
        (Test-Line $out 'git status failed: fatal: bad object HEAD') -and (Test-Line $out 'Removed 3 entries') -and
        ((Get-Content -LiteralPath $r.Csv) -join ';') -ceq "$($r.Good);$broken,broken,,"
    }
}
finally {
    $env:PATH = $originalPath
    Set-Location -LiteralPath $startLocation
    if ($global:_dotfilesProfileIdleSubscriptionId) {
        Unregister-Event -SubscriptionId $global:_dotfilesProfileIdleSubscriptionId -ErrorAction Ignore
    }
    Remove-Item -LiteralPath "\\?\$scratch" -Recurse -Force -ErrorAction Ignore
}

Complete-Tests
