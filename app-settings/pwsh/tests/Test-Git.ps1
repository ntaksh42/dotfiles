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
            Branches = @(); LocalBranches = @(); Merged = @(); CleanPreview = @(); LogLines = @()
            Fail = @(); Repos = @{}; GitaNames = @(); GitaPaths = @{}
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
            'rev-parse --absolute-git-dir' { $script:g.GitDir; return }
            'rev-parse --show-toplevel' {
                if ($script:g.Top) { $script:g.Top } else { $global:LASTEXITCODE = 128 }
                return
            }
            'status --porcelain*' { $script:g.Dirty; return }
            'stash push --quiet -m *' { if ($script:g.StashCreates) { $script:g.StashRef = 'stash-created' }; return }
            'config --get pull.rebase' {
                if ($script:g.Rebase) { $script:g.Rebase } else { $global:LASTEXITCODE = 1 }
                return
            }
            'ls-tree -r --name-only *' { $script:g.RemoteFiles; return }
            'ls-files --others --exclude-standard' { $repo.Untracked; return }
            'ls-files' { $repo.Tracked; return }
            'branch --all --format=%(refname:short)' { $script:g.Branches; return }
            'branch --merged' { $script:g.Merged; return }
            'clean -ffdxn' { $script:g.CleanPreview; return }
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
        $cfg = @{ Branch = 'main'; HasOrigin = $true; Tracked = @(); Untracked = @() }
        foreach ($k in $Overrides.Keys) { $cfg[$k] = $Overrides[$k] }
        $script:g.Repos[$dir] = $cfg
        $script:g.GitaPaths[$Name] = $dir
        $script:g.GitaNames += $Name
        $dir
    }

    Reset-Fake

    # --- Simple git wrappers -------------------------------------------------------------
    $gitWrappers = @(
        @{ Cmd = 'gs'; Base = @('status', '-sb') }
        @{ Cmd = 'ga'; Base = @('add') }
        @{ Cmd = 'gaa'; Base = @('add', '-A') }
        @{ Cmd = 'gb'; Base = @('branch') }
        @{ Cmd = 'gd'; Base = @('diff') }
        @{ Cmd = 'gds'; Base = @('diff', '--staged') }
        @{ Cmd = 'gpf'; Base = @('push', '--force-with-lease') }
        @{ Cmd = 'gsta'; Base = @('stash', 'push') }
        @{ Cmd = 'gstp'; Base = @('stash', 'pop') }
        @{ Cmd = 'gstl'; Base = @('stash', 'list') }
    )
    foreach ($w in $gitWrappers) {
        Test-Case "$($w.Cmd) runs only its fixed git arguments when called bare" {
            Reset-Fake
            $null = & $w.Cmd
            $script:calls.Count -eq 1 -and ($script:calls[0] -join '|') -ceq ($w.Base -join '|')
        }
        Test-Case "$($w.Cmd) appends caller arguments unsplit after its fixed arguments" {
            Reset-Fake
            $null = & $w.Cmd 'a b' '--flag'
            $script:calls.Count -eq 1 -and
            ($script:calls[0] -join '|') -ceq ((@($w.Base) + 'a b' + '--flag') -join '|')
        }
    }
    Test-Case 'git-undo soft-resets one commit' {
        Reset-Fake
        git-undo
        $script:calls.Count -eq 1 -and ($script:calls[0] -join '|') -ceq 'reset|--soft|HEAD~1'
    }
    Test-Case 'A failing wrapper leaves the git exit code visible to the caller' {
        Reset-Fake
        $script:g.Fail = @('push*')
        gpf origin topic
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

    # --- gcm / gco edge cases (basic forwarding is in Test-Profile.ps1) ------------------
    Test-Case 'gcm without a message warns with usage and does not commit' {
        Reset-Fake
        $out = Get-Output { gcm }
        (Test-Line $out 'usage: gcm <message>') -and $script:calls.Count -eq 0
    }
    Test-Case 'gcm joins several unquoted words into one commit message' {
        Reset-Fake
        gcm fix the build
        $script:calls.Count -eq 1 -and ($script:calls[0] -join '|') -ceq 'commit|-m|fix the build'
    }
    Test-Case 'gco without arguments and without fzf warns and runs no git command' {
        Reset-Fake
        $script:_cmdCache['fzf'] = $false
        $out = Get-Output { gco }
        (Test-Line $out 'git-switch needs fzf') -and $script:calls.Count -eq 0
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
        gf
        (Get-Calls) -join ';' -ceq 'pack-refs --all;fetch --all --prune;pack-refs --all'
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
            'pull'
            'pack-refs --all'
        )
        (Get-Calls) -join ';' -ceq ($expected -join ';')
    }
    Test-Case 'gpl forwards its arguments to git pull' {
        Reset-Fake
        $null = Get-Output { gpl --ff-only }
        Test-Called 'pull --ff-only'
    }
    Test-Case 'gpl stops after a failed fetch without stashing or pulling' {
        Reset-Fake
        $script:g.Dirty = 'M file.txt'; $script:g.Fail = @('fetch*')
        $out = Get-Output { gpl }
        (Test-Line $out 'fetch 失敗') -and -not (Test-Called 'pull*') -and -not (Test-Called 'stash*') -and
        -not (Test-Called 'rev-parse*')
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
        @($out | Where-Object { $_.Contains('pack-refs をスキップ') }).Count -eq 2 -and (Test-Called 'pull')
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
        $pull = Get-CallIndex 'pull'
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
        (Test-Called 'stash push*') -and (Test-Called 'pull') -and -not (Test-Called 'stash pop*')
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
        -not (Test-Called 'stash pop*') -and $c[-1] -ceq 'pull'
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
        (Get-BackedUp $top) -contains 'new.txt' -and (Test-Called 'pull')
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

    # --- gclone / groot (real Set-Location inside scratch dirs) ---------------------------
    Test-Case 'gclone clones the URL and enters the directory named after the repository' {
        Reset-Fake
        $dir = New-ScratchDir
        $script:g.CloneDir = 'repo'
        Push-Location -LiteralPath $dir
        try { $null = Get-Output { gclone 'https://github.com/o/repo.git' }; $here = (Get-Location).Path } finally { Pop-Location }
        ($script:calls[0] -join '|') -ceq 'clone|https://github.com/o/repo.git' -and (Split-Path -Leaf $here) -eq 'repo'
    }
    Test-Case 'gclone handles a trailing slash and a URL without .git' {
        Reset-Fake
        $dir = New-ScratchDir
        $script:g.CloneDir = 'proj'
        Push-Location -LiteralPath $dir
        try { $null = Get-Output { gclone 'https://host.example/o/proj/' }; $here = (Get-Location).Path } finally { Pop-Location }
        (Split-Path -Leaf $here) -eq 'proj'
    }
    Test-Case 'gclone handles an scp-style URL' {
        Reset-Fake
        $dir = New-ScratchDir
        $script:g.CloneDir = 'scp-repo'
        Push-Location -LiteralPath $dir
        try { $null = Get-Output { gclone 'git@github.com:o/scp-repo.git' }; $here = (Get-Location).Path } finally { Pop-Location }
        (Split-Path -Leaf $here) -eq 'scp-repo'
    }
    Test-Case 'gclone stays put when git clone fails, even if the directory exists' {
        Reset-Fake
        $dir = New-ScratchDir
        New-Item -ItemType Directory -Path (Join-Path $dir 'repo') | Out-Null
        $script:g.Fail = @('clone*')
        Push-Location -LiteralPath $dir
        try { $null = Get-Output { gclone 'https://github.com/o/repo.git' }; $here = (Get-Location).Path } finally { Pop-Location }
        $here -eq $dir
    }
    Test-Case 'gclone stays put when the clone succeeded but the directory is missing' {
        Reset-Fake
        $dir = New-ScratchDir
        Push-Location -LiteralPath $dir
        try { $null = Get-Output { gclone 'https://github.com/o/repo.git' }; $here = (Get-Location).Path } finally { Pop-Location }
        $here -eq $dir
    }
    Test-Case 'groot changes to the repository top level' {
        Reset-Fake
        $top = New-ScratchDir
        $elsewhere = New-ScratchDir
        $script:g.Top = $top
        Push-Location -LiteralPath $elsewhere
        try { $null = Get-Output { groot }; $here = (Get-Location).Path } finally { Pop-Location }
        $here -eq $top -and ($script:calls[0] -join '|') -ceq 'rev-parse|--show-toplevel'
    }
    Test-Case 'groot warns and stays put outside a repository' {
        Reset-Fake
        $elsewhere = New-ScratchDir
        Push-Location -LiteralPath $elsewhere
        try { $out = Get-Output { groot }; $here = (Get-Location).Path } finally { Pop-Location }
        (Test-Line $out 'Not a git repository') -and $here -eq $elsewhere
    }

    # --- glog ----------------------------------------------------------------------------
    Test-Case 'glog warns and runs nothing without fzf' {
        Reset-Fake
        $script:_cmdCache['fzf'] = $false
        $out = Get-Output { glog }
        (Test-Line $out 'glog needs fzf') -and $script:calls.Count -eq 0 -and $null -eq $script:fzfArgs
    }
    Test-Case 'glog feeds the colored log to fzf with a plain git show preview when delta is absent' {
        Reset-Fake
        $script:g.LogLines = @('abc1234 first', 'def5678 second')
        $null = Get-Output { glog }
        ($script:calls[0] -join '|') -ceq 'log|--color=always|--format=%C(auto)%h %s %C(dim)%an, %ar' -and
        ($script:fzfArgs -join '|') -ceq '--ansi|--no-sort|--reverse|--preview|git show --color=always {1}' -and
        ($script:fzfInput -join '|') -ceq 'abc1234 first|def5678 second'
    }
    Test-Case 'glog pipes the preview through delta when it is available' {
        Reset-Fake
        $script:_cmdCache['delta'] = $true
        $null = Get-Output { glog }
        $script:fzfArgs[-1] -ceq 'git show --color=always {1} | delta'
    }
    Test-Case 'glog passes extra arguments to git log' {
        Reset-Fake
        $null = Get-Output { glog --author=me -5 }
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

    # --- git-nuke ------------------------------------------------------------------------
    Test-Case 'git-nuke reports an already clean tree without prompting or resetting' {
        Reset-Fake
        $out = Get-Output { git-nuke }
        (Test-Line $out 'Already clean.') -and $script:prompts.Count -eq 0 -and
        (Get-Calls) -join ';' -ceq 'status --porcelain;clean -ffdxn'
    }
    Test-Case 'git-nuke shows the preview and aborts on a negative answer' {
        Reset-Fake
        $script:g.Dirty = 'M a.txt'; $script:g.CleanPreview = @('Would remove junk/')
        $script:answer = 'n'
        $out = Get-Output { git-nuke }
        (Test-Line $out "git reset --hard HEAD") -and (Test-Line $out '  Would remove junk/') -and (Test-Line $out 'Aborted.') -and
        -not (Test-Called 'reset*') -and -not (Test-Called 'clean -ffdx')
    }
    Test-Case 'git-nuke resets hard then cleans after a positive answer' {
        Reset-Fake
        $script:g.Dirty = 'M a.txt'
        $script:answer = 'y'
        $null = Get-Output { git-nuke }
        $reset = Get-CallIndex 'reset --hard HEAD'
        $clean = Get-CallIndex 'clean -ffdx'
        $script:prompts.Count -eq 1 -and $reset -ge 0 -and $reset -lt $clean
    }
    Test-Case 'git-nuke -Force skips the prompt' {
        Reset-Fake
        $script:g.Dirty = 'M a.txt'
        $null = Get-Output { git-nuke -Force }
        $script:prompts.Count -eq 0 -and (Test-Called 'reset --hard HEAD') -and (Test-Called 'clean -ffdx')
    }
    Test-Case 'git-nuke -Ref resets to that ref' {
        Reset-Fake
        $script:g.Dirty = 'M a.txt'
        $out = Get-Output { git-nuke -Ref origin/main -Force }
        (Test-Called 'reset --hard origin/main') -and (Test-Line $out "git reset --hard origin/main") -and
        -not (Test-Called 'reset --hard HEAD')
    }
    Test-Case 'git-nuke proceeds when only untracked or ignored files exist' {
        Reset-Fake
        $script:g.CleanPreview = @('Would remove build/')
        $null = Get-Output { git-nuke -Force }
        (Test-Called 'reset --hard HEAD') -and (Test-Called 'clean -ffdx')
    }
    Test-Case 'git-nuke throws and skips the clean when reset fails' {
        Reset-Fake
        $script:g.Dirty = 'M a.txt'; $script:g.Fail = @('reset*')
        $msg = $null
        try { $null = Get-Output { git-nuke -Force } } catch { $msg = $_.Exception.Message }
        $msg -like '*git reset --hard HEAD failed with exit code 1*' -and -not (Test-Called 'clean -ffdx')
    }
    Test-Case 'git-nuke throws when the clean fails' {
        Reset-Fake
        $script:g.Dirty = 'M a.txt'; $script:g.Fail = @('clean -ffdx')
        $msg = $null
        try { $null = Get-Output { git-nuke -Force } } catch { $msg = $_.Exception.Message }
        $msg -like '*git clean -ffdx failed with exit code 1*' -and (Test-Called 'reset --hard HEAD')
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

    # --- clean-pull-all ------------------------------------------------------------------
    Test-Case 'clean-pull-all warns and does nothing without gita' {
        Reset-Fake
        $script:_cmdCache['gita'] = $false
        $out = Get-Output { clean-pull-all }
        (Test-Line $out 'clean-pull-all needs gita') -and $script:calls.Count -eq 0 -and $script:gitaCalls.Count -eq 0
    }
    Test-Case 'clean-pull-all warns when gita has no repositories' {
        Reset-Fake
        $out = Get-Output { clean-pull-all }
        (Test-Line $out 'No repos registered in gita') -and $script:calls.Count -eq 0
    }
    Test-Case 'clean-pull-all fetches then fast-forward pulls a repo whose branch has an origin counterpart' {
        Reset-Fake
        $repo = New-FakeRepo 'alpha'
        $null = Get-Output { clean-pull-all }
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
    Test-Case 'clean-pull-all switches to the fallback branch when the current one has no origin branch' {
        Reset-Fake
        $repo = New-FakeRepo 'alpha' @{ Branch = 'wip'; HasOrigin = $false }
        $out = Get-Output { clean-pull-all }
        $c = @(Get-Calls)
        $co = $c.IndexOf("-C $repo checkout main")
        (Test-Line $out 'no origin/wip -> switching to main') -and $co -ge 0 -and $c[-1] -ceq "-C $repo pull --ff-only" -and
        $c.IndexOf("-C $repo rev-parse --verify --quiet origin/wip") -lt $co
    }
    Test-Case 'clean-pull-all -Fallback selects the branch to switch to' {
        Reset-Fake
        $repo = New-FakeRepo 'alpha' @{ Branch = 'wip'; HasOrigin = $false }
        $null = Get-Output { clean-pull-all -Fallback develop }
        (Test-Called "-C $repo checkout develop") -and -not (Test-Called "-C $repo checkout main")
    }
    Test-Case 'clean-pull-all warns and skips the pull when the fallback checkout fails, then continues with the next repo' {
        Reset-Fake
        $bad = New-FakeRepo 'alpha' @{ Branch = 'wip'; HasOrigin = $false }
        $good = New-FakeRepo 'beta'
        $script:g.Fail = @('checkout*')
        $out = Get-Output { clean-pull-all }
        (Test-Line $out 'checkout main failed') -and -not (Test-Called "-C $bad pull*") -and (Test-Called "-C $good pull --ff-only")
    }
    Test-Case 'clean-pull-all warns about a registered path that no longer exists and continues' {
        Reset-Fake
        $good = New-FakeRepo 'beta'
        $ghost = Join-Path $scratch 'ghost-repo'
        $script:g.GitaNames = @('ghost', 'beta')
        $script:g.GitaPaths['ghost'] = $ghost
        $out = Get-Output { clean-pull-all }
        (Test-Line $out "path not found: $ghost") -and -not (Test-Called "-C $ghost*") -and (Test-Called "-C $good pull --ff-only")
    }
    Test-Case 'clean-pull-all accepts gita ls output as one space-separated line' {
        Reset-Fake
        $a = New-FakeRepo 'alpha'
        $b = New-FakeRepo 'beta'
        $script:g.GitaNames = @('alpha beta')
        $null = Get-Output { clean-pull-all }
        (Test-Called "-C $a pull --ff-only") -and (Test-Called "-C $b pull --ff-only")
    }
    Test-Case 'clean-pull-all removes stray nul files (tracked or untracked, once each) and nothing else' {
        Reset-Fake
        $repo = New-FakeRepo 'alpha' @{
            Tracked   = @('nul', 'sub/nul', 'src/nullable.txt', 'nul.txt')
            Untracked = @('other/nul', 'nul')
        }
        foreach ($f in 'nul', 'sub/nul', 'other/nul', 'nul.txt', 'src/nullable.txt') { New-TestFile $repo $f }
        $out = Get-Output { clean-pull-all }
        $removedLines = @($out | Where-Object { $_.Contains('removed stray file:') })
        -not (Test-TestFile $repo 'nul') -and -not (Test-TestFile $repo 'sub/nul') -and -not (Test-TestFile $repo 'other/nul') -and
        (Test-TestFile $repo 'nul.txt') -and (Test-TestFile $repo 'src/nullable.txt') -and
        $removedLines.Count -eq 3 -and (Test-Line $out 'removed stray file: sub/nul')
    }
    Test-Case 'clean-pull-all removes stray files before it fetches' {
        Reset-Fake
        $repo = New-FakeRepo 'alpha' @{ Tracked = @('nul') }
        New-TestFile $repo 'nul'
        $null = Get-Output { clean-pull-all }
        (Get-CallIndex "-C $repo ls-files*") -ge 0 -and (Get-CallIndex "-C $repo ls-files*") -lt (Get-CallIndex "-C $repo fetch*")
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
