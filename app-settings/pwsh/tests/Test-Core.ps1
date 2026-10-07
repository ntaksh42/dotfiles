# Run with: pwsh -NoProfile -File app-settings/pwsh/tests/Test-Core.ps1
# Covers the loader helpers/aliases (§0/§1) and profile.d\navigation.ps1, vs-build.ps1, ai-cli.ps1.
# External tools are never launched: they are faked with functions defined after the profile loads.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$originalPath = $env:PATH
$originalLocation = (Get-Location).Path
$originalExitCode = $global:LASTEXITCODE
. (Join-Path $PSScriptRoot 'TestHarness.ps1')

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('dotfiles-core-test-' + [guid]::NewGuid().ToString('N'))
$script:dirSeq = 0
$builtinAliases = 'gl', 'gp', 'gcm', 'cat'
$preLoadAliases = @{}
foreach ($aliasName in $builtinAliases) { $preLoadAliases[$aliasName] = [bool](Get-Alias $aliasName -ErrorAction Ignore) }

function New-TestDir {
    param([string]$Name)
    $script:dirSeq++
    (New-Item -ItemType Directory -Path (Join-Path $scratch ('{0}-{1}' -f $Name, $script:dirSeq))).FullName
}

# Run a block with $Location as the current location; always return to the previous one.
function Invoke-InDirectory {
    param([string]$Location, [scriptblock]$Body)
    $previous = (Get-Location).Path
    try { Set-Location -LiteralPath $Location; & $Body }
    finally { Set-Location -LiteralPath $previous }
}

# Run a block with process environment variables overridden ($null removes one); always restore them.
function Invoke-WithEnv {
    param([hashtable]$Vars, [scriptblock]$Body)
    $saved = @{}
    foreach ($key in $Vars.Keys) { $saved[$key] = [Environment]::GetEnvironmentVariable($key) }
    # [NullString]::Value is a real null; a PowerShell $null would arrive as '' and leave an empty variable behind.
    $set = { param($k, $v) [Environment]::SetEnvironmentVariable($k, $(if ($null -eq $v) { [NullString]::Value } else { [string]$v })) }
    try {
        foreach ($key in $Vars.Keys) { & $set $key $Vars[$key] }
        & $Body
    }
    finally {
        foreach ($key in $saved.Keys) { & $set $key $saved[$key] }
    }
}

function Get-WarningText {
    param([scriptblock]$Body)
    , @(& $Body 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
}

function Test-Throws {
    param([scriptblock]$Body)
    try { & $Body | Out-Null } catch { return $true }
    $false
}

function Set-FileTime {
    param([string]$Path, [datetime]$Time)
    [IO.File]::SetLastWriteTime($Path, $Time)
}

try {
    New-Item -ItemType Directory -Path $scratch | Out-Null
    $scratch = (Get-Item -LiteralPath $scratch).FullName
    $env:PATH = ''
    . (Join-Path $root 'Microsoft.PowerShell_profile.ps1')

    # =====================================================================================
    # §0 Loader helpers
    # =====================================================================================
    Test-Case 'DotfilesProfilePath points at the loader file that was dot-sourced' {
        $script:DotfilesProfilePath -eq (Join-Path $root 'Microsoft.PowerShell_profile.ps1')
    }

    # --- Test-Cmd --------------------------------------------------------------------
    Test-Case 'Test-Cmd returns $true for an existing command' {
        function dotfiles-test-probe-exists { }
        $result = Test-Cmd 'dotfiles-test-probe-exists'
        $result -is [bool] -and $result
    }
    Test-Case 'Test-Cmd returns $false (a bool) for a missing command' {
        $result = Test-Cmd 'dotfiles-test-probe-missing'
        $result -is [bool] -and -not $result
    }
    Test-Case 'Test-Cmd finds an application on PATH, not only functions' {
        $bin = New-TestDir 'cmd-bin'
        Set-Content -LiteralPath (Join-Path $bin 'dotfiles-fake-app.cmd') -Value '@echo off'
        Invoke-WithEnv @{ PATH = $bin } { Test-Cmd 'dotfiles-fake-app' }
    }
    Test-Case 'Test-Cmd caches a positive result after the command disappears' {
        function dotfiles-test-probe-pos { }
        $first = Test-Cmd 'dotfiles-test-probe-pos'
        Remove-Item Function:dotfiles-test-probe-pos
        $first -and (Test-Cmd 'dotfiles-test-probe-pos') -and $script:_cmdCache['dotfiles-test-probe-pos'] -eq $true
    }
    Test-Case 'Test-Cmd caches a negative result until the cache entry is cleared' {
        $before = Test-Cmd 'dotfiles-test-probe-neg'
        function dotfiles-test-probe-neg { }
        $stillCached = Test-Cmd 'dotfiles-test-probe-neg'
        $script:_cmdCache.Remove('dotfiles-test-probe-neg')
        $afterClear = Test-Cmd 'dotfiles-test-probe-neg'
        -not $before -and -not $stillCached -and $afterClear
    }
    Test-Case 'Test-Cmd answers from a pre-seeded cache entry without looking the command up' {
        $script:_cmdCache['dotfiles-test-seeded'] = $true
        Test-Cmd 'dotfiles-test-seeded'
    }
    Test-Case 'Test-Cmd rejects an empty command name' {
        Test-Throws { Test-Cmd '' }
    }

    # --- Assert-NativeCommandSucceeded ------------------------------------------------
    Test-Case 'Assert-NativeCommandSucceeded is silent when LASTEXITCODE is 0' {
        $global:LASTEXITCODE = 0
        $null -eq (Assert-NativeCommandSucceeded 'git')
    }
    Test-Case 'Assert-NativeCommandSucceeded is silent when LASTEXITCODE is $null' {
        $global:LASTEXITCODE = $null
        $null -eq (Assert-NativeCommandSucceeded 'git')
    }
    Test-Case 'Assert-NativeCommandSucceeded throws naming the command and exit code' {
        $global:LASTEXITCODE = 3
        $message = $null
        try { Assert-NativeCommandSucceeded 'dotnet' } catch { $message = $_.Exception.Message }
        $message -ceq 'dotnet failed with exit code 3.'
    }
    Test-Case 'Assert-NativeCommandSucceeded also throws for negative exit codes' {
        $global:LASTEXITCODE = -1
        $message = $null
        try { Assert-NativeCommandSucceeded 'msbuild' } catch { $message = $_.Exception.Message }
        $message -ceq 'msbuild failed with exit code -1.'
    }
    Test-Case 'Assert-NativeCommandSucceeded reports the exit code of a real failing native command' {
        & $env:ComSpec /c exit 5
        $message = $null
        try { Assert-NativeCommandSucceeded 'cmd' } catch { $message = $_.Exception.Message }
        $message -ceq 'cmd failed with exit code 5.'
    }
    Test-Case 'Assert-NativeCommandSucceeded accepts a real succeeding native command' {
        & $env:ComSpec /c exit 0
        $null -eq (Assert-NativeCommandSucceeded 'cmd')
    }

    # --- Get-InitCache ----------------------------------------------------------------
    $initBin = New-TestDir 'init-bin'
    $initExe = Join-Path $initBin 'fake-init-tool.exe'
    Set-Content -LiteralPath $initExe -Value 'not a real executable'   # only its timestamp is read
    $script:genCalls = 0
    $initGen = { $script:genCalls++; "# generated $script:genCalls"; 'line2' }
    function Read-CacheLines { param([string]$Path) @(Get-Content -LiteralPath $Path | Where-Object { $_ -ne '' }) -join '|' }

    Test-Case 'Get-InitCache generates a missing cache under LOCALAPPDATA and returns its path' {
        $la = New-TestDir 'la'
        $script:genCalls = 0
        Invoke-WithEnv @{ LOCALAPPDATA = $la } {
            $p = Get-InitCache -Name 'tool' -Exe $initExe -Generator $initGen
            $p -is [string] -and $p -eq (Join-Path $la 'pwsh-init-cache\tool.ps1') -and
            (Read-CacheLines $p) -ceq '# generated 1|line2' -and $script:genCalls -eq 1
        }
    }
    Test-Case 'Get-InitCache creates the pwsh-init-cache directory when it is missing' {
        $la = New-TestDir 'la'
        $dir = Join-Path $la 'pwsh-init-cache'
        $before = Test-Path -LiteralPath $dir
        Invoke-WithEnv @{ LOCALAPPDATA = $la } { $null = Get-InitCache -Name 'tool' -Exe $initExe -Generator $initGen }
        -not $before -and (Test-Path -LiteralPath $dir -PathType Container)
    }
    Test-Case 'Get-InitCache keeps a cache that is newer than the executable' {
        $la = New-TestDir 'la'
        $script:genCalls = 0
        Invoke-WithEnv @{ LOCALAPPDATA = $la } {
            $p = Get-InitCache -Name 'tool' -Exe $initExe -Generator $initGen
            Set-FileTime $initExe (Get-Date).AddHours(-1)
            Set-FileTime $p (Get-Date)
            $p2 = Get-InitCache -Name 'tool' -Exe $initExe -Generator $initGen
            $p2 -eq $p -and $script:genCalls -eq 1 -and (Read-CacheLines $p) -ceq '# generated 1|line2'
        }
    }
    Test-Case 'Get-InitCache regenerates when the executable is newer than the cache' {
        $la = New-TestDir 'la'
        $script:genCalls = 0
        Invoke-WithEnv @{ LOCALAPPDATA = $la } {
            $p = Get-InitCache -Name 'tool' -Exe $initExe -Generator $initGen
            Set-FileTime $p (Get-Date).AddHours(-2)
            Set-FileTime $initExe (Get-Date).AddHours(-1)
            $null = Get-InitCache -Name 'tool' -Exe $initExe -Generator $initGen
            $script:genCalls -eq 2 -and (Read-CacheLines $p) -ceq '# generated 2|line2'
        }
    }
    Test-Case 'Get-InitCache is not stale again right after it regenerated' {
        $la = New-TestDir 'la'
        $script:genCalls = 0
        Invoke-WithEnv @{ LOCALAPPDATA = $la } {
            $p = Get-InitCache -Name 'tool' -Exe $initExe -Generator $initGen
            Set-FileTime $p (Get-Date).AddHours(-2)
            Set-FileTime $initExe (Get-Date).AddHours(-1)
            $null = Get-InitCache -Name 'tool' -Exe $initExe -Generator $initGen
            $null = Get-InitCache -Name 'tool' -Exe $initExe -Generator $initGen
            $script:genCalls -eq 2
        }
    }
    Test-Case 'Get-InitCache treats equal timestamps as fresh' {
        $la = New-TestDir 'la'
        $script:genCalls = 0
        Invoke-WithEnv @{ LOCALAPPDATA = $la } {
            $p = Get-InitCache -Name 'tool' -Exe $initExe -Generator $initGen
            $same = [datetime]'2024-01-02 03:04:05'
            Set-FileTime $p $same
            Set-FileTime $initExe $same
            $null = Get-InitCache -Name 'tool' -Exe $initExe -Generator $initGen
            $script:genCalls -eq 1
        }
    }
    Test-Case 'Get-InitCache resolves the executable by name through PATH' {
        $la = New-TestDir 'la'
        $script:genCalls = 0
        Invoke-WithEnv @{ LOCALAPPDATA = $la; PATH = $initBin } {
            $p = Get-InitCache -Name 'tool' -Exe 'fake-init-tool' -Generator $initGen
            Set-FileTime $p (Get-Date).AddHours(-2)
            Set-FileTime $initExe (Get-Date).AddHours(-1)
            $null = Get-InitCache -Name 'tool' -Exe 'fake-init-tool' -Generator $initGen
            $script:genCalls -eq 2
        }
    }
    Test-Case 'Get-InitCache keeps an existing cache when the executable cannot be found' {
        $la = New-TestDir 'la'
        $script:genCalls = 0
        Invoke-WithEnv @{ LOCALAPPDATA = $la } {
            $p = Get-InitCache -Name 'tool' -Exe $initExe -Generator $initGen
            Set-FileTime $p (Get-Date).AddHours(-2)
            $null = Get-InitCache -Name 'tool' -Exe 'dotfiles-no-such-exe' -Generator $initGen
            $script:genCalls -eq 1
        }
    }
    Test-Case 'Get-InitCache still generates a missing cache when the executable cannot be found' {
        $la = New-TestDir 'la'
        $script:genCalls = 0
        Invoke-WithEnv @{ LOCALAPPDATA = $la } {
            $p = Get-InitCache -Name 'tool' -Exe 'dotfiles-no-such-exe' -Generator $initGen
            $script:genCalls -eq 1 -and (Test-Path -LiteralPath $p -PathType Leaf)
        }
    }
    Test-Case 'Get-InitCache keeps a separate cache file per name' {
        $la = New-TestDir 'la'
        $script:genCalls = 0
        Invoke-WithEnv @{ LOCALAPPDATA = $la } {
            $a = Get-InitCache -Name 'alpha' -Exe $initExe -Generator $initGen
            $b = Get-InitCache -Name 'beta' -Exe $initExe -Generator $initGen
            $a -ne $b -and (Split-Path -Leaf $a) -eq 'alpha.ps1' -and (Split-Path -Leaf $b) -eq 'beta.ps1' -and
            $script:genCalls -eq 2
        }
    }
    Test-Case 'Get-InitCache output is a script that can be dot-sourced' {
        $la = New-TestDir 'la'
        Invoke-WithEnv @{ LOCALAPPDATA = $la } {
            $p = Get-InitCache -Name 'sourced' -Exe $initExe -Generator { 'function dotfiles-init-probe { 42 }' }
            . $p
            (dotfiles-init-probe) -eq 42
        }
    }

    # =====================================================================================
    # §1 Aliases
    # =====================================================================================
    foreach ($aliasName in $builtinAliases) {
        Test-Case "Built-in alias '$aliasName' existed before the profile and is removed afterwards" {
            $preLoadAliases[$aliasName] -and $null -eq (Get-Alias $aliasName -ErrorAction Ignore) -and
            (Get-Command $aliasName).CommandType -ne 'Alias'
        }
    }
    $aliasExpect = [ordered]@{
        cop = 'copilot'; g = 'git'; cx = 'codex'; which = 'Get-Command'; cl = 'Clear-Host'
        profile = 'Edit-Profile'; ccf = 'fable-orchest'; ccfo = 'fable-orchest-opus'
        cco = 'opus-orchest'; ccfp = 'fable-orchest-plan'; ccop = 'cc'
    }
    foreach ($aliasName in $aliasExpect.Keys) {
        Test-Case "Alias '$aliasName' resolves to '$($aliasExpect[$aliasName])'" {
            (Get-Alias $aliasName).Definition -ceq $aliasExpect[$aliasName]
        }
    }

    # =====================================================================================
    # navigation.ps1
    # =====================================================================================
    $nav = New-TestDir 'nav'

    # --- mkcd -------------------------------------------------------------------------
    Test-Case 'mkcd creates nested directories, changes into the deepest one and outputs nothing' {
        $target = Join-Path $nav 'mk\a\b'
        Invoke-InDirectory $nav {
            $out = mkcd $target
            $null -eq $out -and (Get-Location).Path -eq $target -and (Test-Path -LiteralPath $target -PathType Container)
        }
    }
    Test-Case 'mkcd resolves a relative path against the current directory' {
        Invoke-InDirectory $nav {
            mkcd 'rel dir'
            (Get-Location).Path -eq (Join-Path $nav 'rel dir')
        }
    }
    Test-Case 'mkcd on an existing directory just changes into it and keeps its contents' {
        $dir = New-TestDir 'mk-existing'
        Set-Content -LiteralPath (Join-Path $dir 'keep.txt') -Value 'keep'
        Invoke-InDirectory $nav {
            mkcd $dir
            (Get-Location).Path -eq $dir -and (Test-Path -LiteralPath (Join-Path $dir 'keep.txt'))
        }
    }
    Test-Case 'mkcd rejects an empty path and stays where it was' {
        Invoke-InDirectory $nav {
            $threw = Test-Throws { mkcd '' }
            $threw -and (Get-Location).Path -eq $nav
        }
    }
    Test-Case 'mkcd throws when the path is an existing file and stays where it was' {
        $file = Join-Path $nav 'mk-file.txt'
        Set-Content -LiteralPath $file -Value 'x'
        Invoke-InDirectory $nav {
            $threw = Test-Throws { mkcd $file }
            $threw -and (Get-Location).Path -eq $nav
        }
    }

    # --- size -------------------------------------------------------------------------
    $sz = New-TestDir 'size'
    [IO.File]::WriteAllBytes((Join-Path $sz 'big.bin'), [byte[]]::new(3MB))
    [IO.File]::WriteAllBytes((Join-Path $sz 'round.bin'), [byte[]]::new(1234567))
    [IO.File]::WriteAllBytes((Join-Path $sz 'small.bin'), [byte[]]::new(512KB))
    New-Item -ItemType Directory -Path (Join-Path $sz 'sub\deep'), (Join-Path $sz 'emptydir') | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $sz 'sub\one.bin'), [byte[]]::new(1MB))
    [IO.File]::WriteAllBytes((Join-Path $sz 'sub\deep\two.bin'), [byte[]]::new(512KB))
    function Get-SizeRows {
        param([string]$Path)
        $text = if ($Path) { size $Path | Out-String } else { size | Out-String }
        @($text -split "`r?`n" | ForEach-Object { if ($_ -match '^(\S+)\s+(\d+(?:\.\d+)?)\s*$') { '{0}={1}' -f $Matches[1], [double]$Matches[2] } })
    }
    Test-Case 'size lists entries sorted by size, largest first' {
        (Get-SizeRows $sz) -join '|' -ceq 'big.bin=3|sub=1.5|round.bin=1.18|small.bin=0.5|emptydir=0'
    }
    Test-Case 'size sums a directory recursively and counts an empty directory as 0' {
        $rows = Get-SizeRows $sz
        $rows -contains 'sub=1.5' -and $rows -contains 'emptydir=0'
    }
    Test-Case 'size reports megabytes rounded to two decimals' {
        (Get-SizeRows $sz) -contains 'round.bin=1.18'
    }
    Test-Case 'size without a path lists the current directory' {
        Invoke-InDirectory $sz { ((Get-SizeRows) -join '|') -ceq 'big.bin=3|sub=1.5|round.bin=1.18|small.bin=0.5|emptydir=0' }
    }

    # --- .. / ... / .... / up ---------------------------------------------------------
    $deep = Join-Path $nav 'u\a\b\c'
    New-Item -ItemType Directory -Path $deep | Out-Null
    Test-Case '.. goes up one level' {
        Invoke-InDirectory $deep { .. ; (Get-Location).Path -eq (Join-Path $nav 'u\a\b') }
    }
    Test-Case '... goes up two levels' {
        Invoke-InDirectory $deep { ... ; (Get-Location).Path -eq (Join-Path $nav 'u\a') }
    }
    Test-Case '.... goes up three levels' {
        Invoke-InDirectory $deep { .... ; (Get-Location).Path -eq (Join-Path $nav 'u') }
    }
    Test-Case 'up without an argument goes up one level' {
        Invoke-InDirectory $deep { up; (Get-Location).Path -eq (Join-Path $nav 'u\a\b') }
    }
    Test-Case 'up N goes up N levels' {
        Invoke-InDirectory $deep { up 3; (Get-Location).Path -eq (Join-Path $nav 'u') }
    }
    Test-Case 'up clamps zero and negative levels to one level' {
        Invoke-InDirectory $deep {
            up 0
            $zero = (Get-Location).Path
            up -5
            $zero -eq (Join-Path $nav 'u\a\b') -and (Get-Location).Path -eq (Join-Path $nav 'u\a')
        }
    }

    # --- repos ------------------------------------------------------------------------
    Test-Case 'repos changes into source\repos under USERPROFILE' {
        $fakeHome = New-TestDir 'home'
        New-Item -ItemType Directory -Path (Join-Path $fakeHome 'source\repos') | Out-Null
        Invoke-InDirectory $nav {
            Invoke-WithEnv @{ USERPROFILE = $fakeHome } { repos }
            (Get-Location).Path -eq (Join-Path $fakeHome 'source\repos')
        }
    }
    Test-Case 'repos throws and stays put when source\repos does not exist' {
        $fakeHome = New-TestDir 'home-empty'
        Invoke-InDirectory $nav {
            $threw = Invoke-WithEnv @{ USERPROFILE = $fakeHome } { Test-Throws { repos } }
            $threw -and (Get-Location).Path -eq $nav
        }
    }

    # --- ll / la / lt -----------------------------------------------------------------
    $ls = New-TestDir 'ls'
    Set-Content -LiteralPath (Join-Path $ls 'a.txt') -Value 'a'
    Set-Content -LiteralPath (Join-Path $ls '.hid') -Value 'h'
    [IO.File]::SetAttributes((Join-Path $ls '.hid'), 'Hidden')
    New-Item -ItemType Directory -Path (Join-Path $ls 'sub\deeper') | Out-Null
    Set-Content -LiteralPath (Join-Path $ls 'sub\inner.txt') -Value 'i'
    Set-Content -LiteralPath (Join-Path $ls 'sub\deeper\x.txt') -Value 'x'
    function eza { $script:ezaArgs = @($args) }
    foreach ($row in @(
            @{ Cmd = 'll'; Fixed = '-lh|--git|--icons|--group-directories-first' }
            @{ Cmd = 'la'; Fixed = '-lah|--git|--icons|--group-directories-first' }
            @{ Cmd = 'lt'; Fixed = '--tree|--level=2|--icons' })) {
        Test-Case "$($row.Cmd) runs eza with its fixed options when eza exists" {
            $script:_cmdCache['eza'] = $true
            $script:ezaArgs = $null
            & $row.Cmd
            ($script:ezaArgs -join '|') -ceq $row.Fixed
        }
        Test-Case "$($row.Cmd) forwards extra arguments to eza after the fixed options" {
            $script:_cmdCache['eza'] = $true
            $script:ezaArgs = $null
            & $row.Cmd 'some dir' --sort=size
            $script:ezaArgs.Count -eq (($row.Fixed -split '\|').Count + 2) -and
            ($script:ezaArgs -join '|') -ceq "$($row.Fixed)|some dir|--sort=size"
        }
    }
    Test-Case 'll looks eza up lazily through Test-Cmd on first use' {
        $script:_cmdCache.Remove('eza')
        $script:ezaArgs = $null
        ll
        $null -ne $script:ezaArgs -and $script:_cmdCache['eza'] -eq $true
    }
    Test-Case 'll without eza lists the directory without hidden entries' {
        $script:_cmdCache['eza'] = $false
        $script:ezaArgs = $null
        $names = @(Invoke-InDirectory $ls { ll } | ForEach-Object Name | Sort-Object)
        ($names -join '|') -ceq 'a.txt|sub' -and $null -eq $script:ezaArgs
    }
    Test-Case 'la without eza includes hidden entries' {
        $script:_cmdCache['eza'] = $false
        $names = @(Invoke-InDirectory $ls { la } | ForEach-Object Name | Sort-Object)
        ($names -join '|') -ceq '.hid|a.txt|sub'
    }
    Test-Case 'lt without eza recurses exactly one level deep' {
        $script:_cmdCache['eza'] = $false
        $names = @(Invoke-InDirectory $ls { lt } | ForEach-Object Name | Sort-Object)
        ($names -join '|') -ceq 'a.txt|deeper|inner.txt|sub'
    }
    Test-Case 'll without eza forwards parameters such as a path and -Name to Get-ChildItem' {
        $script:_cmdCache['eza'] = $false
        $names = @(ll $ls -Name | Sort-Object)
        ($names -join '|') -ceq 'a.txt|sub'
    }
    Remove-Item Function:eza

    # --- ff / fcd (fake fd / fzf / Invoke-Item) -----------------------------------------
    $fz = New-TestDir 'fz'
    Set-Content -LiteralPath (Join-Path $fz 'f1.txt') -Value '1'
    New-Item -ItemType Directory -Path (Join-Path $fz 'sub') | Out-Null
    Set-Content -LiteralPath (Join-Path $fz 'sub\f2.txt') -Value '2'
    $script:fzfInput = $null; $script:fzfPick = $null; $script:fdArgs = $null; $script:fdOut = @(); $script:opened = @()
    function fzf { $script:fzfInput = @($input); $script:fzfPick }
    function fd { $script:fdArgs = @($args); $script:fdOut }
    function Invoke-Item { $script:opened += , @($args) }
    function Reset-Fuzzy { $script:fzfInput = $null; $script:fzfPick = $null; $script:fdArgs = $null; $script:fdOut = @(); $script:opened = @() }

    Test-Case 'ff warns and does nothing when fzf is missing' {
        Reset-Fuzzy
        $script:_cmdCache['fzf'] = $false; $script:_cmdCache['fd'] = $true
        $warnings = Get-WarningText { ff }
        ($warnings -join '|') -ceq 'ff needs fzf' -and $null -eq $script:fdArgs -and $script:opened.Count -eq 0
    }
    Test-Case 'ff with fd pipes `fd --type f` into fzf and opens the selection' {
        Reset-Fuzzy
        $script:_cmdCache['fzf'] = $true; $script:_cmdCache['fd'] = $true
        $script:fdOut = @('one.txt', 'two.txt'); $script:fzfPick = 'two.txt'
        ff
        ($script:fdArgs -join '|') -ceq '--type|f' -and ($script:fzfInput -join '|') -ceq 'one.txt|two.txt' -and
        $script:opened.Count -eq 1 -and $script:opened[0].Count -eq 1 -and $script:opened[0][0] -ceq 'two.txt'
    }
    Test-Case 'ff without fd feeds fzf the full paths of files only' {
        Reset-Fuzzy
        $script:_cmdCache['fzf'] = $true; $script:_cmdCache['fd'] = $false
        Invoke-InDirectory $fz { ff }
        $expected = @((Join-Path $fz 'f1.txt'), (Join-Path $fz 'sub\f2.txt')) | Sort-Object
        ($script:fzfInput | Sort-Object) -join '|' -ceq ($expected -join '|') -and $null -eq $script:fdArgs
    }
    Test-Case 'ff opens nothing when the fzf selection is cancelled' {
        Reset-Fuzzy
        $script:_cmdCache['fzf'] = $true; $script:_cmdCache['fd'] = $true
        $script:fdOut = @('one.txt'); $script:fzfPick = $null
        ff
        $script:opened.Count -eq 0
    }
    Test-Case 'fcd warns and stays put when fzf is missing' {
        Reset-Fuzzy
        $script:_cmdCache['fzf'] = $false
        Invoke-InDirectory $nav {
            $warnings = Get-WarningText { fcd }
            ($warnings -join '|') -ceq 'fcd needs fzf' -and (Get-Location).Path -eq $nav
        }
    }
    Test-Case 'fcd with fd pipes `fd --type d` into fzf and changes into the selection' {
        Reset-Fuzzy
        $script:_cmdCache['fzf'] = $true; $script:_cmdCache['fd'] = $true
        $script:fdOut = @('x', 'y'); $script:fzfPick = Join-Path $fz 'sub'
        Invoke-InDirectory $nav {
            fcd
            ($script:fdArgs -join '|') -ceq '--type|d' -and ($script:fzfInput -join '|') -ceq 'x|y' -and
            (Get-Location).Path -eq (Join-Path $fz 'sub')
        }
    }
    Test-Case 'fcd without fd feeds fzf the full paths of directories only' {
        Reset-Fuzzy
        $script:_cmdCache['fzf'] = $true; $script:_cmdCache['fd'] = $false
        Invoke-InDirectory $fz { fcd }
        ($script:fzfInput -join '|') -ceq (Join-Path $fz 'sub') -and $null -eq $script:fdArgs
    }
    Test-Case 'fcd stays put when the fzf selection is cancelled' {
        Reset-Fuzzy
        $script:_cmdCache['fzf'] = $true; $script:_cmdCache['fd'] = $true
        $script:fdOut = @('x'); $script:fzfPick = $null
        Invoke-InDirectory $nav { fcd; (Get-Location).Path -eq $nav }
    }
    Remove-Item Function:fzf, Function:fd, Function:Invoke-Item, Function:Reset-Fuzzy

    # --- touch ------------------------------------------------------------------------
    $tc = New-TestDir 'touch'
    Test-Case 'touch creates a missing empty file and outputs nothing' {
        Invoke-InDirectory $tc {
            $out = touch 'new file.txt'
            $item = Get-Item -LiteralPath (Join-Path $tc 'new file.txt')
            $null -eq $out -and $item.Length -eq 0
        }
    }
    Test-Case 'touch updates the timestamp of an existing file without changing its content' {
        $f = Join-Path $tc 'old.txt'
        [IO.File]::WriteAllText($f, 'keep')
        Set-FileTime $f ([datetime]'2000-01-01')
        Invoke-InDirectory $tc { touch 'old.txt' }
        (Get-Item -LiteralPath $f).LastWriteTime -gt (Get-Date).AddMinutes(-5) -and [IO.File]::ReadAllText($f) -ceq 'keep'
    }
    Test-Case 'touch updates the timestamp of an existing directory' {
        $d = Join-Path $tc 'olddir'
        New-Item -ItemType Directory -Path $d | Out-Null
        [IO.Directory]::SetLastWriteTime($d, [datetime]'2000-01-01')
        Invoke-InDirectory $tc { touch 'olddir' }
        (Get-Item -LiteralPath $d).LastWriteTime -gt (Get-Date).AddMinutes(-5)
    }
    Test-Case 'touch throws and creates nothing when the parent directory is missing' {
        Invoke-InDirectory $tc {
            $threw = Test-Throws { touch 'no-such-parent\x.txt' }
            $threw -and -not (Test-Path -LiteralPath (Join-Path $tc 'no-such-parent'))
        }
    }

    # --- backup-file ------------------------------------------------------------------
    $bk = New-TestDir 'backup'
    Test-Case 'backup-file copies the file next to itself as <name>.bak-<timestamp> and keeps the original' {
        $f = Join-Path $bk 'note.txt'
        [IO.File]::WriteAllText($f, 'payload')
        function Get-Date { param($Format) '20240102-030405' }
        try { Invoke-InDirectory $bk { backup-file 'note.txt' *>$null } }
        finally { Remove-Item Function:Get-Date }
        $copy = Join-Path $bk 'note.txt.bak-20240102-030405'
        (Test-Path -LiteralPath $copy -PathType Leaf) -and [IO.File]::ReadAllText($copy) -ceq 'payload' -and
        [IO.File]::ReadAllText($f) -ceq 'payload'
    }
    Test-Case 'backup-file uses a yyyyMMdd-HHmmss timestamp with the real clock' {
        $f = Join-Path $bk 'clock.txt'
        [IO.File]::WriteAllText($f, 'c')
        backup-file $f *>$null
        $copies = @(Get-ChildItem -LiteralPath $bk -Filter 'clock.txt.bak-*')
        $copies.Count -eq 1 -and $copies[0].Name -cmatch '^clock\.txt\.bak-\d{8}-\d{6}$'
    }
    Test-Case 'backup-file announces the destination path' {
        $f = Join-Path $bk 'announce.txt'
        [IO.File]::WriteAllText($f, 'a')
        $text = (backup-file $f *>&1 | Out-String)
        $copy = @(Get-ChildItem -LiteralPath $bk -Filter 'announce.txt.bak-*')[0]
        $text.Contains("Backed up -> $($copy.FullName)")
    }
    Test-Case 'backup-file treats wildcard characters in the name literally' {
        $f = Join-Path $bk 'a[1].txt'
        [IO.File]::WriteAllText($f, 'lit')
        [IO.File]::WriteAllText((Join-Path $bk 'a1.txt'), 'decoy')
        backup-file $f *>$null
        $copies = @(Get-ChildItem -LiteralPath $bk | Where-Object { $_.Name -like 'a`[1`].txt.bak-*' })
        $decoyCopies = @(Get-ChildItem -LiteralPath $bk -Filter 'a1.txt.bak-*')
        $copies.Count -eq 1 -and [IO.File]::ReadAllText($copies[0].FullName) -ceq 'lit' -and $decoyCopies.Count -eq 0
    }
    Test-Case 'backup-file warns and copies nothing for a missing path' {
        $before = @(Get-ChildItem -LiteralPath $bk).Count
        $warnings = Get-WarningText { backup-file (Join-Path $bk 'missing.txt') }
        $warnings.Count -eq 1 -and $warnings[0] -ceq "Not a file: $(Join-Path $bk 'missing.txt')" -and
        @(Get-ChildItem -LiteralPath $bk).Count -eq $before
    }
    Test-Case 'backup-file warns and copies nothing for a directory' {
        $d = Join-Path $bk 'adir'
        New-Item -ItemType Directory -Path $d | Out-Null
        $before = @(Get-ChildItem -LiteralPath $bk).Count
        $warnings = Get-WarningText { backup-file $d }
        $warnings.Count -eq 1 -and $warnings[0] -ceq "Not a file: $d" -and @(Get-ChildItem -LiteralPath $bk).Count -eq $before
    }

    # --- reload / Edit-Profile / Measure-ProfileStartup ---------------------------------
    Test-Case 'reload dot-sources the file recorded in DotfilesProfilePath' {
        $marker = Join-Path $scratch 'reload-marker.ps1'
        Set-Content -LiteralPath $marker -Value '$global:DotfilesReloadMarker = "reloaded"'
        $saved = $script:DotfilesProfilePath
        $global:DotfilesReloadMarker = $null
        try { $script:DotfilesProfilePath = $marker; reload }
        finally { $script:DotfilesProfilePath = $saved }
        $result = $global:DotfilesReloadMarker -ceq 'reloaded'
        Remove-Variable DotfilesReloadMarker -Scope Global -ErrorAction Ignore
        $result
    }
    function code { $script:editorCalls += , (@('code') + @($args)) }
    function notepad { $script:editorCalls += , (@('notepad') + @($args)) }
    Test-Case 'Edit-Profile opens the profile in VS Code when code exists' {
        $script:editorCalls = @()
        $script:_cmdCache['code'] = $true
        $saved = $script:DotfilesProfilePath
        try { $script:DotfilesProfilePath = 'C:\some dir\profile.ps1'; Edit-Profile }
        finally { $script:DotfilesProfilePath = $saved }
        $script:editorCalls.Count -eq 1 -and ($script:editorCalls[0] -join '|') -ceq 'code|C:\some dir\profile.ps1'
    }
    Test-Case 'Edit-Profile falls back to Notepad when code is missing' {
        $script:editorCalls = @()
        $script:_cmdCache['code'] = $false
        $saved = $script:DotfilesProfilePath
        try { $script:DotfilesProfilePath = 'C:\some dir\profile.ps1'; Edit-Profile }
        finally { $script:DotfilesProfilePath = $saved }
        $script:editorCalls.Count -eq 1 -and ($script:editorCalls[0] -join '|') -ceq 'notepad|C:\some dir\profile.ps1'
    }
    Remove-Item Function:code, Function:notepad

    $measureMarker = Join-Path $scratch 'measure-marker.txt'
    $measureScript = Join-Path $scratch 'measure-target.ps1'
    Set-Content -LiteralPath $measureScript -Value "[IO.File]::AppendAllText('$measureMarker', 'x')"
    Test-Case 'Measure-ProfileStartup runs one clean child per sample and summarises the timings' {
        Remove-Item -LiteralPath $measureMarker -ErrorAction Ignore
        $r = Measure-ProfileStartup -Samples 2 -Path $measureScript
        $r.Samples -eq 2 -and [IO.File]::ReadAllText($measureMarker) -ceq 'xx' -and
        $r.MinimumMs -gt 0 -and $r.MinimumMs -le $r.AverageMs -and $r.AverageMs -le $r.MaximumMs
    }
    Test-Case 'Measure-ProfileStartup defaults to the profile file recorded in DotfilesProfilePath' {
        Remove-Item -LiteralPath $measureMarker -ErrorAction Ignore
        $saved = $script:DotfilesProfilePath
        try { $script:DotfilesProfilePath = $measureScript; $r = Measure-ProfileStartup -Samples 1 }
        finally { $script:DotfilesProfilePath = $saved }
        $r.Samples -eq 1 -and [IO.File]::ReadAllText($measureMarker) -ceq 'x'
    }
    Test-Case 'Measure-ProfileStartup rejects out-of-range sample counts and a missing path' {
        (Test-Throws { Measure-ProfileStartup -Samples 0 -Path $measureScript }) -and
        (Test-Throws { Measure-ProfileStartup -Samples 21 -Path $measureScript }) -and
        (Test-Throws { Measure-ProfileStartup -Samples 1 -Path (Join-Path $scratch 'nope.ps1') })
    }
    Test-Case 'Measure-ProfileStartup reports a failing child with its exit code and stderr' {
        $failing = Join-Path $scratch 'measure-fail.ps1'
        Set-Content -LiteralPath $failing -Value "throw 'child boom'"
        $message = $null
        try { $null = Measure-ProfileStartup -Samples 1 -Path $failing } catch { $message = $_.Exception.Message }
        $message -like 'Profile measurement failed (exit 1):*child boom*'
    }

    # =====================================================================================
    # vs-build.ps1
    # =====================================================================================
    # --- Get-VsInstallPath (vswhere is faked as a function named after its full path) ---
    $pf86 = New-TestDir 'pf86'
    $vswhereDir = Join-Path $pf86 'Microsoft Visual Studio\Installer'
    $vswhere = Join-Path $pf86 'Microsoft Visual Studio\Installer\vswhere.exe'
    $global:DotfilesVsWhereArgs = $null
    $global:DotfilesVsWhereOut = $null

    Test-Case 'Get-VsInstallPath returns $null when vswhere.exe is not installed' {
        Invoke-WithEnv @{ 'ProgramFiles(x86)' = $pf86 } { $null -eq (Get-VsInstallPath) }
    }
    New-Item -ItemType Directory -Path $vswhereDir | Out-Null
    Set-Content -LiteralPath $vswhere -Value 'placeholder, never executed'
    Invoke-Expression ('function global:"{0}" {{ $global:DotfilesVsWhereArgs = @($args); $global:DotfilesVsWhereOut }}' -f $vswhere)
    Test-Case 'Get-VsInstallPath asks vswhere for the latest installationPath and returns its output' {
        $global:DotfilesVsWhereArgs = $null
        $global:DotfilesVsWhereOut = 'C:\VS\Latest'
        Invoke-WithEnv @{ 'ProgramFiles(x86)' = $pf86 } {
            $r = Get-VsInstallPath
            $r -ceq 'C:\VS\Latest' -and ($global:DotfilesVsWhereArgs -join '|') -ceq '-latest|-property|installationPath'
        }
    }
    Test-Case 'Get-VsInstallPath returns nothing when vswhere finds no installation' {
        $global:DotfilesVsWhereOut = $null
        Invoke-WithEnv @{ 'ProgramFiles(x86)' = $pf86 } { -not (Get-VsInstallPath) }
    }
    Remove-Item -LiteralPath "Function:$vswhere" -ErrorAction Ignore

    # --- Find-Sln ---------------------------------------------------------------------
    $slnRoot = New-TestDir 'sln'
    New-Item -ItemType Directory -Path (Join-Path $slnRoot 'src\proj\deep'), (Join-Path $slnRoot 'multi'), (Join-Path $slnRoot 'near\inner'), (Join-Path $slnRoot 'dirsln\x.sln') | Out-Null
    Set-Content -LiteralPath (Join-Path $slnRoot 'top.sln') -Value ''
    Set-Content -LiteralPath (Join-Path $slnRoot 'multi\a.sln') -Value ''
    Set-Content -LiteralPath (Join-Path $slnRoot 'multi\b.sln') -Value ''
    Set-Content -LiteralPath (Join-Path $slnRoot 'multi\c.slnx') -Value ''
    Set-Content -LiteralPath (Join-Path $slnRoot 'near\near.sln') -Value ''
    Test-Case 'Find-Sln finds a solution in a parent directory when walking up' {
        $found = @(Invoke-InDirectory (Join-Path $slnRoot 'src\proj\deep') { Find-Sln })
        $found.Count -eq 1 -and $found[0].FullName -eq (Join-Path $slnRoot 'top.sln')
    }
    Test-Case 'Find-Sln finds a solution in the current directory' {
        $found = @(Invoke-InDirectory $slnRoot { Find-Sln })
        $found.Count -eq 1 -and $found[0].Name -eq 'top.sln'
    }
    Test-Case 'Find-Sln prefers the nearest solution over one further up' {
        $found = @(Invoke-InDirectory (Join-Path $slnRoot 'near\inner') { Find-Sln })
        $found.Count -eq 1 -and $found[0].Name -eq 'near.sln'
    }
    Test-Case 'Find-Sln returns every .sln in the nearest directory and ignores other extensions' {
        $found = @(Invoke-InDirectory (Join-Path $slnRoot 'multi') { Find-Sln } | ForEach-Object Name | Sort-Object)
        ($found -join '|') -ceq 'a.sln|b.sln'
    }
    Test-Case 'Find-Sln ignores a directory whose name ends in .sln' {
        $found = @(Invoke-InDirectory (Join-Path $slnRoot 'dirsln') { Find-Sln })
        $found.Count -eq 1 -and $found[0].Name -eq 'top.sln'
    }
    Test-Case 'Find-Sln returns nothing when no ancestor holds a solution and stops at the drive root' {
        # The scratch dir lives under TEMP; only assert emptiness when no ancestor of it has a .sln.
        $ancestorHasSln = $false
        for ($d = (Split-Path $scratch -Parent); $d; $d = Split-Path $d -Parent) {
            if (@(Get-ChildItem -Path $d -Filter *.sln -File -ErrorAction SilentlyContinue).Count -gt 0) { $ancestorHasSln = $true }
        }
        $bare = New-TestDir 'bare'
        $found = @(Invoke-InDirectory $bare { Find-Sln })
        if ($ancestorHasSln) { $found.Count -gt 0 } else { $found.Count -eq 0 }
    }

    # --- Get-DevEnvPath / vsdev (Get-VsInstallPath faked) -------------------------------
    $vsHome = New-TestDir 'vs'
    New-Item -ItemType Directory -Path (Join-Path $vsHome 'Common7\IDE'), (Join-Path $vsHome 'Common7\Tools') | Out-Null
    $vsNoDevenv = New-TestDir 'vs-nodevenv'
    $script:fakeVsPath = $null
    function Get-VsInstallPath { $script:fakeVsPath }

    Test-Case 'Get-DevEnvPath returns $null when Visual Studio is not installed' {
        $script:fakeVsPath = $null
        $null -eq (Get-DevEnvPath)
    }
    Test-Case 'Get-DevEnvPath returns $null when devenv.exe is missing from the install' {
        $script:fakeVsPath = $vsNoDevenv
        $null -eq (Get-DevEnvPath)
    }
    Test-Case 'Get-DevEnvPath returns Common7\IDE\devenv.exe of the install when present' {
        Set-Content -LiteralPath (Join-Path $vsHome 'Common7\IDE\devenv.exe') -Value 'placeholder, never executed'
        $script:fakeVsPath = $vsHome
        (Get-DevEnvPath) -eq (Join-Path $vsHome 'Common7\IDE\devenv.exe')
    }

    $script:imported = @(); $script:devShell = $null; $script:importThrows = $false; $script:devShellThrows = $false
    function Import-Module { $script:imported += , @($args); if ($script:importThrows) { throw 'import boom' } }
    function Enter-VsDevShell {
        param($VsInstallPath, [switch]$SkipAutomaticLocation, $DevCmdArguments)
        if ($script:devShellThrows) { throw 'shell boom' }
        $script:devShell = @{ Vs = $VsInstallPath; Skip = [bool]$SkipAutomaticLocation; Args = $DevCmdArguments }
    }
    function Reset-DevShell { $script:imported = @(); $script:devShell = $null; $script:importThrows = $false; $script:devShellThrows = $false }
    $devShellDll = Join-Path $vsHome 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll'

    Test-Case 'vsdev warns and imports nothing when Visual Studio is not found' {
        Reset-DevShell; $script:fakeVsPath = $null
        $warnings = Get-WarningText { vsdev }
        ($warnings -join '|') -ceq 'Visual Studio not found (vswhere)' -and $script:imported.Count -eq 0 -and $null -eq $script:devShell
    }
    Test-Case 'vsdev warns with the dll path when the DevShell module is missing' {
        Reset-DevShell; $script:fakeVsPath = $vsHome
        Remove-Item -LiteralPath $devShellDll -ErrorAction Ignore
        $warnings = Get-WarningText { vsdev }
        ($warnings -join '|') -ceq "DevShell module not found: $devShellDll" -and $script:imported.Count -eq 0 -and $null -eq $script:devShell
    }
    Set-Content -LiteralPath $devShellDll -Value 'placeholder, never loaded'
    Test-Case 'vsdev imports the DevShell dll and enters the x64 dev shell for the install' {
        Reset-DevShell; $script:fakeVsPath = $vsHome
        $warnings = Get-WarningText { vsdev }
        $warnings.Count -eq 0 -and $script:imported.Count -eq 1 -and $script:imported[0][0] -eq $devShellDll -and
        $script:devShell.Vs -eq $vsHome -and $script:devShell.Skip -and $script:devShell.Args -ceq '-arch=x64 -host_arch=x64'
    }
    Test-Case 'vsdev turns an Enter-VsDevShell failure into a warning' {
        Reset-DevShell; $script:fakeVsPath = $vsHome; $script:devShellThrows = $true
        $warnings = Get-WarningText { vsdev }
        ($warnings -join '|') -ceq 'vsdev failed: shell boom'
    }
    Test-Case 'vsdev turns an Import-Module failure into a warning and does not enter the shell' {
        Reset-DevShell; $script:fakeVsPath = $vsHome; $script:importThrows = $true
        $warnings = Get-WarningText { vsdev }
        ($warnings -join '|') -ceq 'vsdev failed: import boom' -and $null -eq $script:devShell
    }
    Remove-Item Function:Import-Module, Function:Enter-VsDevShell, Function:Reset-DevShell, Function:Get-VsInstallPath

    # --- sln / vs (Get-DevEnvPath, Find-Sln, Start-Process, fzf faked) --------------------
    $script:fakeDevenv = $null; $script:fakeSlns = @(); $script:started = @(); $script:fzfInput = $null; $script:fzfPick = $null
    function Get-DevEnvPath { $script:fakeDevenv }
    function Find-Sln { $script:fakeSlns }
    function Start-Process { param($FilePath, $ArgumentList) $script:started += [pscustomobject]@{ File = $FilePath; Args = $ArgumentList } }
    function fzf { $script:fzfInput = @($input); $script:fzfPick }
    function Reset-SlnFakes { $script:fakeDevenv = 'C:\VS\devenv.exe'; $script:fakeSlns = @(); $script:started = @(); $script:fzfInput = $null; $script:fzfPick = $null }
    function New-FakeSln { param([string]$Path) [pscustomobject]@{ FullName = $Path } }

    Test-Case 'sln warns and starts nothing when devenv is not found' {
        Reset-SlnFakes; $script:fakeDevenv = $null
        $warnings = Get-WarningText { sln }
        ($warnings -join '|') -ceq 'Visual Studio (devenv) not found' -and $script:started.Count -eq 0
    }
    Test-Case 'sln warns and starts nothing when no solution is found' {
        Reset-SlnFakes
        $warnings = Get-WarningText { sln }
        ($warnings -join '|') -ceq 'No .sln found upward from current directory' -and $script:started.Count -eq 0
    }
    Test-Case 'sln opens a single solution in devenv without consulting fzf' {
        Reset-SlnFakes; $script:_cmdCache['fzf'] = $true
        $script:fakeSlns = @(New-FakeSln 'C:\src\only.sln')
        sln
        $script:started.Count -eq 1 -and $script:started[0].File -ceq 'C:\VS\devenv.exe' -and
        $script:started[0].Args -ceq 'C:\src\only.sln' -and $null -eq $script:fzfInput
    }
    Test-Case 'sln lets fzf pick among several solutions' {
        Reset-SlnFakes; $script:_cmdCache['fzf'] = $true
        $script:fakeSlns = @((New-FakeSln 'C:\src\a.sln'), (New-FakeSln 'C:\src\b.sln'))
        $script:fzfPick = 'C:\src\b.sln'
        sln
        ($script:fzfInput -join '|') -ceq 'C:\src\a.sln|C:\src\b.sln' -and $script:started.Count -eq 1 -and
        $script:started[0].Args -ceq 'C:\src\b.sln'
    }
    Test-Case 'sln picks the first solution when fzf is unavailable' {
        Reset-SlnFakes; $script:_cmdCache['fzf'] = $false
        $script:fakeSlns = @((New-FakeSln 'C:\src\a.sln'), (New-FakeSln 'C:\src\b.sln'))
        sln
        $script:started.Count -eq 1 -and $script:started[0].Args -ceq 'C:\src\a.sln' -and $null -eq $script:fzfInput
    }
    Test-Case 'sln starts nothing when the fzf selection is cancelled' {
        Reset-SlnFakes; $script:_cmdCache['fzf'] = $true
        $script:fakeSlns = @((New-FakeSln 'C:\src\a.sln'), (New-FakeSln 'C:\src\b.sln'))
        sln
        $script:started.Count -eq 0
    }

    Test-Case 'vs warns and starts nothing when devenv is not found' {
        Reset-SlnFakes; $script:fakeDevenv = $null
        $warnings = Get-WarningText { vs }
        ($warnings -join '|') -ceq 'Visual Studio (devenv) not found' -and $script:started.Count -eq 0
    }
    Test-Case 'vs without a path opens the current directory' {
        Reset-SlnFakes
        Invoke-InDirectory $slnRoot { vs }
        $script:started.Count -eq 1 -and $script:started[0].File -ceq 'C:\VS\devenv.exe' -and $script:started[0].Args -eq $slnRoot
    }
    Test-Case 'vs resolves a relative path to a full path' {
        Reset-SlnFakes
        Invoke-InDirectory $slnRoot { vs 'src\proj' }
        $script:started.Count -eq 1 -and $script:started[0].Args -eq (Join-Path $slnRoot 'src\proj')
    }
    Test-Case 'vs throws and starts nothing for a path that does not exist' {
        Reset-SlnFakes
        $threw = Invoke-InDirectory $slnRoot { Test-Throws { vs 'no-such-path' } }
        $threw -and $script:started.Count -eq 0
    }
    Remove-Item Function:Get-DevEnvPath, Function:Find-Sln, Function:Start-Process, Function:fzf, Function:Reset-SlnFakes, Function:New-FakeSln

    # --- db / dr / dt / msb --------------------------------------------------------------
    function dotnet { $script:dotnetArgs = @($args) }
    function msbuild { $script:msbuildArgs = @($args) }
    foreach ($row in @(
            @{ Cmd = 'db'; Sub = 'build' }, @{ Cmd = 'dr'; Sub = 'run' }, @{ Cmd = 'dt'; Sub = 'test' })) {
        Test-Case "$($row.Cmd) runs 'dotnet $($row.Sub)' with no extra arguments" {
            $script:dotnetArgs = $null
            & $row.Cmd
            ($script:dotnetArgs -join '|') -ceq $row.Sub -and $script:dotnetArgs.Count -eq 1
        }
        Test-Case "$($row.Cmd) forwards flags and spaced arguments to 'dotnet $($row.Sub)'" {
            $script:dotnetArgs = $null
            & $row.Cmd -c Release --no-restore 'My Project.csproj'
            $script:dotnetArgs.Count -eq 5 -and ($script:dotnetArgs -join '|') -ceq "$($row.Sub)|-c|Release|--no-restore|My Project.csproj"
        }
    }
    Test-Case 'msb forwards its arguments to msbuild unchanged' {
        $script:msbuildArgs = $null
        msb 'My.sln' /t:Rebuild /p:Configuration=Release '-v:m'
        $script:msbuildArgs.Count -eq 4 -and ($script:msbuildArgs -join '|') -ceq 'My.sln|/t:Rebuild|/p:Configuration=Release|-v:m'
    }
    Test-Case 'msb with no arguments runs bare msbuild' {
        $script:msbuildArgs = $null
        msb
        $null -ne $script:msbuildArgs -and $script:msbuildArgs.Count -eq 0
    }
    Remove-Item Function:dotnet, Function:msbuild

    # =====================================================================================
    # ai-cli.ps1
    # =====================================================================================
    $script:claudeCalls = [System.Collections.Generic.List[object]]::new()
    $script:claudeThrows = $false
    function claude {
        $script:claudeCalls.Add([pscustomobject]@{ Args = @($args); Sub = $env:CLAUDE_CODE_SUBAGENT_MODEL })
        if ($script:claudeThrows) { throw 'claude failed' }
    }
    function Reset-Claude { $script:claudeCalls.Clear(); $script:claudeThrows = $false }
    function Get-ClaudeArgs { ($script:claudeCalls[0].Args -join '|') }

    # --- orchestrated launchers ---------------------------------------------------------
    foreach ($row in @(
            @{ Fn = 'fable-orchest'; Main = 'claude-fable-5'; Sub = 'claude-sonnet-5-5'; Pre = '' }
            @{ Fn = 'fable-orchest-opus'; Main = 'claude-fable-5'; Sub = 'claude-opus-5-5'; Pre = '' }
            @{ Fn = 'opus-orchest'; Main = 'claude-opus-5-5'; Sub = 'claude-sonnet-5-5'; Pre = '' }
            @{ Fn = 'fable-orchest-plan'; Main = 'claude-fable-5'; Sub = 'claude-sonnet-5-5'; Pre = '|--permission-mode|plan' })) {
        Test-Case "$($row.Fn) starts claude with its main model and sets the subagent model during the call" {
            Reset-Claude
            Invoke-WithEnv @{ CLAUDE_CODE_SUBAGENT_MODEL = $null } { & $row.Fn }
            $script:claudeCalls.Count -eq 1 -and (Get-ClaudeArgs) -ceq "--model|$($row.Main)$($row.Pre)" -and
            $script:claudeCalls[0].Sub -ceq $row.Sub
        }
        Test-Case "$($row.Fn) forwards extra arguments after its fixed ones" {
            Reset-Claude
            Invoke-WithEnv @{ CLAUDE_CODE_SUBAGENT_MODEL = $null } { & $row.Fn -p 'hello world' --verbose }
            $c = $script:claudeCalls[0]
            $c.Args.Count -eq (5 + @($row.Pre -split '\|' | Where-Object { $_ }).Count) -and
            ($c.Args -join '|') -ceq "--model|$($row.Main)$($row.Pre)|-p|hello world|--verbose"
        }
    }
    Test-Case 'Invoke-ClaudeOrchest with an empty Rest passes only --model' {
        Reset-Claude
        Invoke-WithEnv @{ CLAUDE_CODE_SUBAGENT_MODEL = $null } { Invoke-ClaudeOrchest -MainModel 'm-main' -SubagentModel 'm-sub' -Rest @() }
        $script:claudeCalls.Count -eq 1 -and (Get-ClaudeArgs) -ceq '--model|m-main' -and $script:claudeCalls[0].Sub -ceq 'm-sub'
    }
    Test-Case 'Invoke-ClaudeOrchest removes the subagent variable afterwards when it was unset before' {
        Reset-Claude
        Invoke-WithEnv @{ CLAUDE_CODE_SUBAGENT_MODEL = $null } {
            Invoke-ClaudeOrchest 'm-main' 'm-sub'
            $null -eq [Environment]::GetEnvironmentVariable('CLAUDE_CODE_SUBAGENT_MODEL') -and -not (Test-Path Env:CLAUDE_CODE_SUBAGENT_MODEL)
        }
    }
    Test-Case 'Invoke-ClaudeOrchest restores a pre-existing subagent variable afterwards' {
        Reset-Claude
        Invoke-WithEnv @{ CLAUDE_CODE_SUBAGENT_MODEL = 'user-preset' } {
            Invoke-ClaudeOrchest 'm-main' 'm-sub'
            $env:CLAUDE_CODE_SUBAGENT_MODEL -ceq 'user-preset' -and $script:claudeCalls[0].Sub -ceq 'm-sub'
        }
    }
    Test-Case 'Invoke-ClaudeOrchest restores the environment and rethrows when claude fails' {
        Reset-Claude; $script:claudeThrows = $true
        Invoke-WithEnv @{ CLAUDE_CODE_SUBAGENT_MODEL = 'user-preset' } {
            $threw = Test-Throws { Invoke-ClaudeOrchest 'm-main' 'm-sub' }
            $threw -and $env:CLAUDE_CODE_SUBAGENT_MODEL -ceq 'user-preset'
        }
    }
    Test-Case 'Orchestrated launchers leave a pre-existing subagent variable untouched afterwards' {
        Reset-Claude
        Invoke-WithEnv @{ CLAUDE_CODE_SUBAGENT_MODEL = 'user-preset' } {
            opus-orchest
            $env:CLAUDE_CODE_SUBAGENT_MODEL -ceq 'user-preset'
        }
    }
    foreach ($row in @(
            @{ Alias = 'ccf'; Args = '--model|claude-fable-5' }
            @{ Alias = 'ccfo'; Args = '--model|claude-fable-5' }
            @{ Alias = 'cco'; Args = '--model|claude-opus-5-5' }
            @{ Alias = 'ccfp'; Args = '--model|claude-fable-5|--permission-mode|plan' })) {
        Test-Case "Alias $($row.Alias) launches claude through its orchestrated function with arguments" {
            Reset-Claude
            Invoke-WithEnv @{ CLAUDE_CODE_SUBAGENT_MODEL = $null } { & $row.Alias 'task one' }
            (Get-ClaudeArgs) -ceq "$($row.Args)|task one"
        }
    }

    # --- plain claude launchers ---------------------------------------------------------
    foreach ($row in @(
            @{ Fn = 'cc'; Fixed = '--model|claude-opus-5-5' }
            @{ Fn = 'ccop'; Fixed = '--model|claude-opus-5-5' }
            @{ Fn = 'ccp'; Fixed = '--model|claude-opus-5-5|--permission-mode|plan' }
            @{ Fn = 'ccs'; Fixed = '--model|claude-sonnet-5-5' }
            @{ Fn = 'cch'; Fixed = '--model|claude-haiku-5-5' }
            @{ Fn = 'ccc'; Fixed = '--continue' }
            @{ Fn = 'ccr'; Fixed = '--resume' })) {
        Test-Case "$($row.Fn) runs claude with exactly its fixed arguments" {
            Reset-Claude
            & $row.Fn
            $script:claudeCalls.Count -eq 1 -and (Get-ClaudeArgs) -ceq $row.Fixed
        }
        Test-Case "$($row.Fn) forwards extra arguments, keeping spaced ones as one argument" {
            Reset-Claude
            & $row.Fn -p 'hello world' --verbose
            $script:claudeCalls[0].Args.Count -eq (($row.Fixed -split '\|').Count + 3) -and
            (Get-ClaudeArgs) -ceq "$($row.Fixed)|-p|hello world|--verbose"
        }
    }
    Test-Case 'Plain claude launchers do not touch the subagent model variable' {
        Reset-Claude
        Invoke-WithEnv @{ CLAUDE_CODE_SUBAGENT_MODEL = $null } { cc; ccs }
        $script:claudeCalls.Count -eq 2 -and $null -eq $script:claudeCalls[0].Sub -and $null -eq $script:claudeCalls[1].Sub
    }
    Remove-Item Function:claude, Function:Reset-Claude, Function:Get-ClaudeArgs

    # --- codex (real function; wrapper and native codex.cmd are fake files) ---------------
    $cxRoot = New-TestDir 'codex'
    $cxAppData = Join-Path $cxRoot 'appdata'
    $cxLocal = Join-Path $cxRoot 'local'
    $cxLocalNoWrapper = Join-Path $cxRoot 'local-empty'
    New-Item -ItemType Directory -Path (Join-Path $cxAppData 'npm'), (Join-Path $cxLocal 'CodexStatusline'), $cxLocalNoWrapper | Out-Null
    Set-Content -LiteralPath (Join-Path $cxAppData 'npm\codex.cmd') -Value "@echo off`r`necho NATIVE:%*"
    Set-Content -LiteralPath (Join-Path $cxLocal 'CodexStatusline\codex-wt.ps1') -Value '"WRAPPER n=$($args.Count): $($args -join ''|'')"'
    $cxPathBin = New-TestDir 'codex-path'
    Set-Content -LiteralPath (Join-Path $cxPathBin 'codex.cmd') -Value "@echo off`r`necho PATHNATIVE:%*"
    $cxEnv = @{ APPDATA = $cxAppData; LOCALAPPDATA = $cxLocal; WT_SESSION = $null }
    function Invoke-RealCodex {
        param([hashtable]$Env, [object[]]$CodexArgs)
        Invoke-WithEnv $Env { (@(codex @CodexArgs) -join '|').Trim() }
    }

    foreach ($sub in 'exec', 'review', 'cloud', 'mcp', 'completion', 'login', 'logout', 'features', 'app-server') {
        Test-Case "codex $sub goes straight to the native codex.cmd even when the wrapper exists" {
            (Invoke-RealCodex $cxEnv @($sub, 'x')) -ceq "NATIVE:$sub x"
        }
    }
    foreach ($flag in '--help', '-h', '--version', '-V') {
        Test-Case "codex $flag goes straight to the native codex.cmd" {
            (Invoke-RealCodex $cxEnv @($flag)) -ceq "NATIVE:$flag"
        }
    }
    Test-Case 'codex matches native-only subcommands case-insensitively' {
        (Invoke-RealCodex $cxEnv @('EXEC', 'x')) -ceq 'NATIVE:EXEC x'
    }
    Test-Case 'codex uses the native codex.cmd for everything when the wrapper is missing' {
        $env2 = @{ APPDATA = $cxAppData; LOCALAPPDATA = $cxLocalNoWrapper; WT_SESSION = $null }
        (Invoke-RealCodex $env2 @('fix the bug')) -ceq 'NATIVE:"fix the bug"'
    }
    Test-Case 'codex runs the wrapper without -InternalCurrentWindow outside Windows Terminal' {
        (Invoke-RealCodex $cxEnv @('-s', 'read-only', 'do it')) -ceq 'WRAPPER n=3: -s|read-only|do it'
    }
    Test-Case 'codex passes -InternalCurrentWindow first to the wrapper inside Windows Terminal' {
        $env2 = @{ APPDATA = $cxAppData; LOCALAPPDATA = $cxLocal; WT_SESSION = 'wt-guid' }
        (Invoke-RealCodex $env2 @('-s', 'read-only', 'do it')) -ceq 'WRAPPER n=4: -InternalCurrentWindow|-s|read-only|do it'
    }
    Test-Case 'codex with no arguments runs the wrapper with no arguments' {
        (Invoke-RealCodex $cxEnv @()) -ceq 'WRAPPER n=0:'
    }
    Test-Case 'codex only inspects the first argument for native-only subcommands' {
        (Invoke-RealCodex $cxEnv @('-s', 'read-only', 'exec')) -ceq 'WRAPPER n=3: -s|read-only|exec'
    }
    Test-Case 'codex prefers codex.cmd found on PATH over the APPDATA npm fallback' {
        $env2 = @{ APPDATA = $cxAppData; LOCALAPPDATA = $cxLocal; WT_SESSION = $null; PATH = $cxPathBin }
        (Invoke-RealCodex $env2 @('exec', 'x')) -ceq 'PATHNATIVE:exec x'
    }

    # --- codex presets (codex itself faked) ---------------------------------------------
    $script:codexCalls = [System.Collections.Generic.List[object]]::new()
    function codex { $script:codexCalls.Add(@($args)) }
    foreach ($row in @(
            @{ Fn = 'cxr'; Fixed = '-s|read-only|-a|untrusted' }
            @{ Fn = 'cxa'; Fixed = '-a|never|-s|workspace-write' }
            @{ Fn = 'cxh'; Fixed = '-c|model_reasoning_effort=high' }
            @{ Fn = 'cxrev'; Fixed = 'review' }
            @{ Fn = 'cxc'; Fixed = 'resume|--last' }
            @{ Fn = 'cxs'; Fixed = 'resume' }
            @{ Fn = 'cxfa'; Fixed = '-s|danger-full-access' }
            @{ Fn = 'cxyolo'; Fixed = '--dangerously-bypass-approvals-and-sandbox' })) {
        Test-Case "$($row.Fn) calls codex with exactly its preset arguments" {
            $script:codexCalls.Clear()
            & $row.Fn
            $script:codexCalls.Count -eq 1 -and ($script:codexCalls[0] -join '|') -ceq $row.Fixed
        }
        Test-Case "$($row.Fn) appends extra arguments after its preset, keeping spaced ones whole" {
            $script:codexCalls.Clear()
            & $row.Fn -m gpt-5 'write tests'
            $script:codexCalls[0].Count -eq (($row.Fixed -split '\|').Count + 3) -and
            ($script:codexCalls[0] -join '|') -ceq "$($row.Fixed)|-m|gpt-5|write tests"
        }
    }
    Test-Case 'Alias cx resolves to the codex function' {
        $script:codexCalls.Clear()
        cx exec 'a b'
        $script:codexCalls.Count -eq 1 -and ($script:codexCalls[0] -join '|') -ceq 'exec|a b'
    }
    Remove-Item Function:codex
}
finally {
    Set-Location -LiteralPath $originalLocation
    $env:PATH = $originalPath
    $global:LASTEXITCODE = $originalExitCode
    if ($global:_dotfilesProfileIdleSubscriptionId) {
        Unregister-Event -SubscriptionId $global:_dotfilesProfileIdleSubscriptionId -ErrorAction Ignore
    }
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction Ignore
}

Complete-Tests
