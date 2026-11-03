# Real Git/NTFS regression: only temporary local repositories, no network or user config.
# Run with: pwsh -NoProfile -File app-settings/pwsh/tests/Test-GitFixRefs.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$originalPath = $env:PATH
$originalGlobal = $env:GIT_CONFIG_GLOBAL
$originalNoSystem = $env:GIT_CONFIG_NOSYSTEM
$startLocation = Get-Location
$gitExe = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('dotfiles-fixrefs-test-' + [guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'TestHarness.ps1')

function Invoke-TestGit {
    $output = @(& $gitExe @args 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) { throw "git $args failed: $($output -join "`n")" }
    $output
}

try {
    New-Item -ItemType Directory -Path $scratch | Out-Null
    $env:PATH = ''
    . (Join-Path $root 'Microsoft.PowerShell_profile.ps1')
    $env:PATH = $originalPath
    $env:GIT_CONFIG_NOSYSTEM = '1'
    $env:GIT_CONFIG_GLOBAL = Join-Path $scratch 'gitconfig'
    Set-Content -LiteralPath $env:GIT_CONFIG_GLOBAL -Value @'
[user]
    name = Test
    email = test@example.invalid
[commit]
    gpgsign = false
[core]
    hooksPath = NUL
[init]
    defaultBranch = main
'@
    $remote = Join-Path $scratch 'remote.git'
    $seed = Join-Path $scratch 'seed'
    $local = Join-Path $scratch 'local'
    $null = Invoke-TestGit init --quiet --bare --ref-format=reftable $remote
    $null = Invoke-TestGit init --quiet --ref-format=reftable $seed
    Set-Content -LiteralPath (Join-Path $seed 'file.txt') -Value 'base'
    $null = Invoke-TestGit -C $seed add file.txt
    $null = Invoke-TestGit -C $seed commit --quiet -m initial
    $first = Invoke-TestGit -C $seed rev-parse HEAD
    $null = Invoke-TestGit -C $seed push --quiet $remote HEAD:refs/heads/main HEAD:refs/heads/Feature/Foo
    $null = Invoke-TestGit -C $seed commit --quiet --allow-empty -m second
    $second = Invoke-TestGit -C $seed rev-parse HEAD
    $null = Invoke-TestGit -C $seed push --quiet $remote HEAD:refs/heads/Feature/foo HEAD:refs/heads/feature/foo
    $null = Invoke-TestGit init --quiet --ref-format=files $local
    $null = Invoke-TestGit -C $local remote add origin $remote
    Set-Location -LiteralPath $local

    Test-Case 'Real files backend reproduces a case-collision fetch failure on Windows' {
        $output = @(git fetch origin 2>&1 | ForEach-Object { "$_" })
        $LASTEXITCODE -ne 0 -and ($output -match 'only differ in casing')
    }
    $null = Invoke-TestGit checkout --quiet -b main origin/main
    $null = Invoke-TestGit commit --quiet --allow-empty -m 'local commit'
    $null = Invoke-TestGit tag local-tag
    $null = Invoke-TestGit symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
    Set-Content -LiteralPath (Join-Path $local 'file.txt') -Value 'stashed edit'
    $null = Invoke-TestGit stash push --quiet -m 'keep this stash'
    Set-Content -LiteralPath (Join-Path $local 'file.txt') -Value 'staged edit'
    $null = Invoke-TestGit add file.txt
    Set-Content -LiteralPath (Join-Path $local 'file.txt') -Value 'unstaged edit'
    Set-Content -LiteralPath (Join-Path $local 'untracked.txt') -Value 'untracked edit'
    $headBefore = Invoke-TestGit rev-parse HEAD
    $stashBefore = Invoke-TestGit rev-parse refs/stash
    $statusBefore = (Invoke-TestGit status --porcelain) -join "`n"
    $reflogBefore = (Invoke-TestGit reflog show '--format=%H %gs' HEAD) -join "`n"
    $gitDir = Join-Path $local '.git'

    Test-Case 'Real WhatIf leaves files format and references untouched' {
        $refsBefore = (Invoke-TestGit show-ref) -join "`n"
        git-fixrefs -WhatIf
        (Invoke-TestGit rev-parse --show-ref-format) -ceq 'files' -and
        ((Invoke-TestGit show-ref) -join "`n") -ceq $refsBefore -and
        -not (Test-Path -LiteralPath (Join-Path $gitDir 'fixrefs-backup'))
    }
    Test-Case 'Real repair fetches all case-distinct refs with their correct object IDs' {
        git-fixrefs
        (Invoke-TestGit rev-parse --show-ref-format) -ceq 'reftable' -and
        (Invoke-TestGit rev-parse refs/remotes/origin/Feature/Foo) -ceq $first -and
        (Invoke-TestGit rev-parse refs/remotes/origin/Feature/foo) -ceq $second -and
        (Invoke-TestGit rev-parse refs/remotes/origin/feature/foo) -ceq $second
    }
    Test-Case 'Real repair preserves local commits, tags, stash, reflog, symbolic refs and dirty files' {
        (Invoke-TestGit rev-parse HEAD) -ceq $headBefore -and
        (Invoke-TestGit rev-parse refs/tags/local-tag) -ceq $headBefore -and
        (Invoke-TestGit rev-parse refs/stash) -ceq $stashBefore -and
        ((Invoke-TestGit status --porcelain) -join "`n") -ceq $statusBefore -and
        ((Invoke-TestGit reflog show '--format=%H %gs' HEAD) -join "`n") -ceq $reflogBefore -and
        (Invoke-TestGit symbolic-ref refs/remotes/origin/HEAD) -ceq 'refs/remotes/origin/main' -and
        (Get-Content -LiteralPath (Join-Path $local 'file.txt')).Trim() -ceq 'unstaged edit' -and
        (Get-Content -LiteralPath (Join-Path $local 'untracked.txt')).Trim() -ceq 'untracked edit'
    }
    Test-Case 'Real repair keeps the original files refs, config and reflog in its backup' {
        $backups = @(Get-ChildItem -LiteralPath (Join-Path $gitDir 'fixrefs-backup') -Directory)
        $backups.Count -eq 1 -and
        (Get-Content -LiteralPath (Join-Path $backups[0].FullName 'refs/heads/main')).Trim() -ceq $headBefore -and
        (Get-Content -LiteralPath (Join-Path $backups[0].FullName 'refs/stash')).Trim() -ceq $stashBefore -and
        (Test-Path -LiteralPath (Join-Path $backups[0].FullName 'logs/HEAD')) -and
        (Get-Content -LiteralPath (Join-Path $backups[0].FullName 'config') -Raw) -notmatch 'ref[Ss]torage'
    }
    Test-Case 'Real repair can run again and passes Git reference verification' {
        git-fixrefs
        $null = Invoke-TestGit refs verify --strict
        @(Get-ChildItem -LiteralPath (Join-Path $gitDir 'fixrefs-backup') -Directory).Count -eq 1
    }
    Test-Case 'Real worktrees stop migration from either checkout without changing refs' {
        $blocked = Join-Path $scratch 'blocked'
        $linked = Join-Path $scratch 'linked'
        $null = Invoke-TestGit init --quiet --ref-format=files $blocked
        $null = Invoke-TestGit -C $blocked commit --quiet --allow-empty -m initial
        $null = Invoke-TestGit -C $blocked worktree add --quiet -b linked $linked
        $messages = @(foreach ($path in $blocked, $linked) {
            Set-Location -LiteralPath $path
            try { git-fixrefs } catch { $_.Exception.Message }
        })
        $messages.Count -eq 2 -and @($messages -match '追加の worktree').Count -eq 2 -and
        (Invoke-TestGit rev-parse --show-ref-format) -ceq 'files' -and
        -not (Test-Path -LiteralPath (Join-Path $blocked '.git/fixrefs-backup'))
    }
}
finally {
    $env:PATH = $originalPath
    $env:GIT_CONFIG_GLOBAL = $originalGlobal
    $env:GIT_CONFIG_NOSYSTEM = $originalNoSystem
    Set-Location -LiteralPath $startLocation
    if ($global:_dotfilesProfileIdleSubscriptionId) {
        Unregister-Event -SubscriptionId $global:_dotfilesProfileIdleSubscriptionId -ErrorAction Ignore
    }
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not [IO.Path]::GetFullPath($scratch).StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unexpected test directory: $scratch"
    }
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
Complete-Tests
