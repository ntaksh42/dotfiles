# Run with: pwsh -NoProfile -File app-settings/pwsh/tests/Test-DevToolsHelpers.ps1
# Covers the catalog (devtools-catalog.ps1) and the helper functions in devtools.ps1, except
# Install-DevTools / Update-DevTools. Every external command and the network are faked.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $root)
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('dotfiles-devtools-test-' + [guid]::NewGuid().ToString('N'))
$originalPath = $env:PATH
$originalLocalAppData = $env:LOCALAPPDATA
. (Join-Path $PSScriptRoot 'TestHarness.ps1')

function New-Scratch {
    $dir = Join-Path $scratch ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $dir
}

# Test-Cmd answers from this cache first, so tests control "is the command on PATH".
function Set-CmdAvailable {
    param([string[]]$Present = @(), [string[]]$Absent = @())
    $script:_cmdCache.Clear()
    foreach ($n in $Present) { $script:_cmdCache[$n] = $true }
    foreach ($n in $Absent) { $script:_cmdCache[$n] = $false }
}

# Runs a script block and returns @{ Result; Warnings; Host } so cases can assert on both.
function Invoke-Captured {
    param([scriptblock]$Block)
    $items = @(& $Block 3>&1 6>&1)
    [pscustomobject]@{
        Result   = @($items | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] -and $_ -isnot [System.Management.Automation.InformationRecord] })
        Warnings = @($items | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
        Host     = @($items | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
    }
}

try {
    New-Item -ItemType Directory -Path $scratch | Out-Null
    $env:PATH = ''
    . (Join-Path $root 'Microsoft.PowerShell_profile.ps1')

    $origCatalog = $script:DevTools
    $origTestToolInstalled = ${function:Test-ToolInstalled}
    $env:LOCALAPPDATA = Join-Path $scratch 'localappdata'

    # =====================================================================================
    # Catalog integrity
    # =====================================================================================
    $knownBackends = 'winget', 'msstore', 'pip', 'psmodule', 'script', 'remote-config', 'claude-plugin'
    $allowedKeys = @{
        'winget'        = 'Id', 'Cmd', 'PostInstall'
        'msstore'       = 'Id'
        'pip'           = 'Id', 'Cmd'
        'psmodule'      = 'Id'
        'script'        = 'Id', 'Path', 'Args', 'RebootRequiredExitCode', 'RequiredCommand', 'Repo', 'VersionSource', 'InstallOnly', 'RemoteFiles'
        'remote-config' = 'RepoPath', 'Dest', 'StripCommentLines'
        'claude-plugin' = 'Id', 'Marketplace', 'MarketplaceSource', 'RequiredCommand'
    }
    $tools = @($origCatalog)
    function Get-ToolsByBackend($Backend) { @($tools | Where-Object { $_.Backend -eq $Backend }) }

    Test-Case 'Catalog is a non-empty array of hashtables' {
        $tools.Count -gt 0 -and @($tools | Where-Object { $_ -isnot [hashtable] }).Count -eq 0
    }
    Test-Case 'Every catalog entry has a non-empty Name' {
        @($tools | Where-Object { [string]::IsNullOrWhiteSpace($_.Name) }).Count -eq 0
    }
    Test-Case 'Catalog names are unique (case-insensitive)' {
        $dupes = @($tools | Group-Object { $_.Name.ToLowerInvariant() } | Where-Object Count -gt 1 | ForEach-Object Name)
        if ($dupes) { throw "duplicate names: $($dupes -join ', ')" }
        $true
    }
    Test-Case 'Every entry uses a known Backend' {
        $bad = @($tools | Where-Object { $knownBackends -notcontains $_.Backend } | ForEach-Object Name)
        if ($bad) { throw "unknown backend: $($bad -join ', ')" }
        $true
    }
    Test-Case 'Every backend is used by at least one catalog entry' {
        @($knownBackends | Where-Object { (Get-ToolsByBackend $_).Count -eq 0 }).Count -eq 0
    }
    Test-Case 'Entries only use keys that their Backend consumes (catches typos)' {
        $bad = foreach ($t in $tools) {
            foreach ($k in $t.Keys) {
                if ($k -in 'Name', 'Backend') { continue }
                if ($allowedKeys[$t.Backend] -notcontains $k) { "$($t.Name).$k" }
            }
        }
        if ($bad) { throw "unexpected keys: $($bad -join ', ')" }
        $true
    }
    Test-Case 'winget and msstore entries have a non-empty Id' {
        @($tools | Where-Object { $_.Backend -in 'winget', 'msstore' -and [string]::IsNullOrWhiteSpace($_.Id) }).Count -eq 0
    }
    Test-Case 'winget Ids look like Publisher.Package' {
        $bad = @(Get-ToolsByBackend 'winget' | Where-Object { $_.Id -notmatch '^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+$' } | ForEach-Object Name)
        if ($bad) { throw "malformed winget Id: $($bad -join ', ')" }
        $true
    }
    Test-Case 'msstore Ids are 12-character Store product IDs' {
        $bad = @(Get-ToolsByBackend 'msstore' | Where-Object { $_.Id -cnotmatch '^[A-Z0-9]{12}$' } | ForEach-Object Name)
        if ($bad) { throw "malformed msstore Id: $($bad -join ', ')" }
        $true
    }
    Test-Case 'Package Ids are unique within a backend' {
        $dupes = @($tools | Where-Object { $_.Id -and $_.Backend -ne 'script' } |
                Group-Object { "$($_.Backend)|$($_.Id.ToLowerInvariant())" } | Where-Object Count -gt 1 | ForEach-Object Name)
        if ($dupes) { throw "duplicate ids: $($dupes -join ', ')" }
        $true
    }
    Test-Case 'pip entries have Id and Cmd (Test-ToolInstalled passes Cmd to Test-Cmd, which is mandatory)' {
        $pip = @(Get-ToolsByBackend 'pip')
        $pip.Count -gt 0 -and @($pip | Where-Object { [string]::IsNullOrWhiteSpace($_.Id) -or [string]::IsNullOrWhiteSpace($_.Cmd) }).Count -eq 0
    }
    Test-Case 'psmodule entries have an Id' {
        $ps = @(Get-ToolsByBackend 'psmodule')
        $ps.Count -gt 0 -and @($ps | Where-Object { [string]::IsNullOrWhiteSpace($_.Id) }).Count -eq 0
    }
    Test-Case 'script entries have an https Id (installer URL) and an absolute Path' {
        $bad = @(Get-ToolsByBackend 'script' | Where-Object {
                $_.Id -notmatch '^https://' -or [string]::IsNullOrWhiteSpace($_.Path) -or -not [IO.Path]::IsPathRooted($_.Path)
            } | ForEach-Object Name)
        if ($bad) { throw "bad script entry: $($bad -join ', ')" }
        $true
    }
    Test-Case 'script installers hosted in this repo point at files that exist' {
        $prefix = "$script:DotfilesRawBase/"
        $own = @(Get-ToolsByBackend 'script' | Where-Object { $_.Id.StartsWith($prefix) })
        $missing = @($own | Where-Object { -not (Test-Path -LiteralPath (Join-Path $repoRoot $_.Id.Substring($prefix.Length)) -PathType Leaf) } | ForEach-Object Name)
        if ($missing) { throw "missing installer: $($missing -join ', ')" }
        $own.Count -gt 0
    }
    Test-Case 'script Args, when present, is a hashtable (Install-DevTools clones and splats it)' {
        @(Get-ToolsByBackend 'script' | Where-Object { $_.ContainsKey('Args') -and $_.Args -isnot [hashtable] }).Count -eq 0
    }
    Test-Case 'script Repo values look like owner/name and VersionSource is product or command' {
        $bad = @(Get-ToolsByBackend 'script' | Where-Object {
                ($_.Repo -and $_.Repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') -or
                ($_.VersionSource -and $_.VersionSource -notin 'product', 'command')
            } | ForEach-Object Name)
        if ($bad) { throw "bad Repo/VersionSource: $($bad -join ', ')" }
        $true
    }
    Test-Case 'script entries with a VersionSource also have a Repo to compare against' {
        @(Get-ToolsByBackend 'script' | Where-Object { $_.VersionSource -and -not $_.Repo }).Count -eq 0
    }
    Test-Case 'script RebootRequiredExitCode is an integer' {
        @(Get-ToolsByBackend 'script' | Where-Object { $_.ContainsKey('RebootRequiredExitCode') -and $_.RebootRequiredExitCode -isnot [int] }).Count -eq 0
    }
    Test-Case 'Windows-Operation-Cli keeps the shape Install-DevTools special-cases' {
        $w = $tools | Where-Object Name -ceq 'Windows-Operation-Cli'
        $w.Backend -eq 'script' -and [bool]$w.Repo -and $w.Args -is [hashtable] -and $w.Args.ContainsKey('FromRelease') -and
        -not $w.VersionSource -and [IO.Path]::GetFileNameWithoutExtension($w.Path) -eq 'windows-operation-cli'
    }
    Test-Case 'remote-config entries have RepoPath and an absolute Dest' {
        $rc = @(Get-ToolsByBackend 'remote-config')
        $rc.Count -gt 0 -and @($rc | Where-Object {
                [string]::IsNullOrWhiteSpace($_.RepoPath) -or [string]::IsNullOrWhiteSpace($_.Dest) -or -not [IO.Path]::IsPathRooted($_.Dest)
            }).Count -eq 0
    }
    Test-Case 'remote-config RepoPath is a relative forward-slash path without ..' {
        $bad = @(Get-ToolsByBackend 'remote-config' | Where-Object {
                $_.RepoPath.StartsWith('/') -or $_.RepoPath.Contains('\') -or $_.RepoPath -match '(^|/)\.\.(/|$)'
            } | ForEach-Object Name)
        if ($bad) { throw "bad RepoPath: $($bad -join ', ')" }
        $true
    }
    Test-Case 'remote-config RepoPath files exist in the repository' {
        $missing = @(Get-ToolsByBackend 'remote-config' | Where-Object { -not (Test-Path -LiteralPath (Join-Path $repoRoot $_.RepoPath) -PathType Leaf) } | ForEach-Object RepoPath)
        if ($missing) { throw "missing in repo: $($missing -join ', ')" }
        $true
    }
    Test-Case 'remote-config Dest keeps the extension of its RepoPath' {
        @(Get-ToolsByBackend 'remote-config' | Where-Object { [IO.Path]::GetExtension($_.Dest) -ne [IO.Path]::GetExtension($_.RepoPath) }).Count -eq 0
    }
    Test-Case 'remote-config StripCommentLines, when present, is a non-negative integer' {
        @(Get-ToolsByBackend 'remote-config' | Where-Object { $_.ContainsKey('StripCommentLines') -and ($_.StripCommentLines -isnot [int] -or $_.StripCommentLines -lt 0) }).Count -eq 0
    }
    Test-Case 'Destination and install paths are unique across the catalog' {
        $paths = @($tools | ForEach-Object { if ($_.Dest) { $_.Dest } elseif ($_.Path) { $_.Path } } | ForEach-Object { $_.ToLowerInvariant() })
        $paths.Count -eq @($paths | Select-Object -Unique).Count
    }
    $marketplace = Get-Content -LiteralPath (Join-Path $repoRoot '.claude-plugin\marketplace.json') -Raw | ConvertFrom-Json
    Test-Case 'claude-plugin entries have Id, Marketplace, MarketplaceSource and RequiredCommand claude' {
        $cp = @(Get-ToolsByBackend 'claude-plugin')
        $cp.Count -gt 0 -and @($cp | Where-Object {
                -not $_.Id -or -not $_.Marketplace -or -not $_.MarketplaceSource -or $_.RequiredCommand -ne 'claude'
            }).Count -eq 0
    }
    Test-Case 'claude-plugin Id is <plugin>@<Marketplace>' {
        $bad = @(Get-ToolsByBackend 'claude-plugin' | Where-Object { $_.Id -notmatch "^[A-Za-z0-9_-]+@$([regex]::Escape($_.Marketplace))$" } | ForEach-Object Name)
        if ($bad) { throw "Id/Marketplace mismatch: $($bad -join ', ')" }
        $true
    }
    Test-Case 'claude-plugin entries reference a plugin listed in .claude-plugin/marketplace.json' {
        $listed = @($marketplace.plugins | ForEach-Object name)
        $bad = @(Get-ToolsByBackend 'claude-plugin' | Where-Object {
                $_.Marketplace -ne $marketplace.name -or ($listed -notcontains ($_.Id -split '@')[0])
            } | ForEach-Object Name)
        if ($bad) { throw "not in marketplace.json: $($bad -join ', ')" }
        $true
    }
    Test-Case 'claude-plugin MarketplaceSource is the repository served by DotfilesRawBase' {
        $cp = @(Get-ToolsByBackend 'claude-plugin')
        @($cp | Where-Object { $script:DotfilesRawBase -notlike "*/$($_.MarketplaceSource)/*" }).Count -eq 0
    }
    Test-Case 'PostInstall values are ones Install-DevTools handles (delta only)' {
        @($tools | Where-Object { $_.PostInstall -and $_.PostInstall -ne 'delta' }).Count -eq 0 -and
        @($tools | Where-Object PostInstall).Count -ge 1
    }

    # =====================================================================================
    # Fakes for external commands / the network (defined after loading the profile)
    # =====================================================================================
    $script:wingetCalls = @(); $script:wingetExit = 0
    function winget { $script:wingetCalls += , @($args); $global:LASTEXITCODE = $script:wingetExit }
    $script:refreshCalls = 0; $script:refreshAction = $null
    function refreshenv { $script:refreshCalls++; if ($script:refreshAction) { & $script:refreshAction } }
    $script:web = @{}; $script:webCalls = @(); $script:webFail = $false
    function Invoke-WebRequest {
        [CmdletBinding()]
        param($Uri, [switch]$UseBasicParsing, $TimeoutSec, $OutFile)
        $script:webCalls += $Uri
        if ($script:webFail) { throw 'offline' }
        if (-not $script:web.ContainsKey($Uri)) { throw "404 $Uri" }
        [pscustomobject]@{ Content = $script:web[$Uri] }
    }
    $script:restCalls = @(); $script:restResult = $null; $script:restThrow = $false
    function Invoke-RestMethod {
        [CmdletBinding()]
        param($Uri, $Headers)
        $script:restCalls += [pscustomobject]@{ Uri = $Uri; Headers = $Headers }
        if ($script:restThrow) { throw 'rate limited' }
        $script:restResult
    }
    function Reset-Fakes {
        $script:wingetCalls = @(); $script:wingetExit = 0
        $script:refreshCalls = 0; $script:refreshAction = $null
        $script:web = @{}; $script:webCalls = @(); $script:webFail = $false
        $script:restCalls = @(); $script:restResult = $null; $script:restThrow = $false
        Set-CmdAvailable
    }

    # =====================================================================================
    # Install-PythonIfMissing
    # =====================================================================================
    Test-Case 'Install-PythonIfMissing returns true without installing when python is on PATH' {
        Reset-Fakes; Set-CmdAvailable -Present python -Absent pip
        $r = Install-PythonIfMissing 6>$null
        $r -eq $true -and $script:wingetCalls.Count -eq 0 -and $script:refreshCalls -eq 0
    }
    Test-Case 'Install-PythonIfMissing returns true without installing when only pip is on PATH' {
        Reset-Fakes; Set-CmdAvailable -Present pip -Absent python
        $r = Install-PythonIfMissing 6>$null
        $r -eq $true -and $script:wingetCalls.Count -eq 0
    }
    Test-Case 'Install-PythonIfMissing installs Python 3.12 through winget with the expected arguments' {
        Reset-Fakes; Set-CmdAvailable -Absent python, pip
        $pyDir = New-Scratch
        Set-Content -LiteralPath (Join-Path $pyDir 'python.cmd') -Value '@echo off'
        $script:refreshAction = { $env:PATH = $pyDir }.GetNewClosure()
        $r = Install-PythonIfMissing 6>$null
        $env:PATH = ''
        $r -eq $true -and $script:wingetCalls.Count -eq 1 -and
        ($script:wingetCalls[0] -join ' ') -eq 'install --id Python.Python.3.12 --exact --source winget --accept-package-agreements --accept-source-agreements'
    }
    Test-Case 'Install-PythonIfMissing refreshes the environment once and re-detects python afterwards' {
        Reset-Fakes; Set-CmdAvailable -Absent python, pip
        $pyDir = New-Scratch
        Set-Content -LiteralPath (Join-Path $pyDir 'python.cmd') -Value '@echo off'
        $script:refreshAction = { $env:PATH = $pyDir }.GetNewClosure()
        $null = Install-PythonIfMissing 6>$null
        $env:PATH = ''
        $script:refreshCalls -eq 1 -and $script:_cmdCache['python'] -eq $true
    }
    Test-Case 'Install-PythonIfMissing throws with the exit code when winget fails and skips refreshenv' {
        Reset-Fakes; Set-CmdAvailable -Absent python, pip
        $script:wingetExit = 5
        $msg = $null
        try { $null = Install-PythonIfMissing 6>$null } catch { $msg = $_.Exception.Message }
        $msg -eq 'winget install Python.Python.3.12 failed with exit code 5.' -and $script:refreshCalls -eq 0
    }
    Test-Case 'Install-PythonIfMissing warns and returns false when python is still missing after install' {
        Reset-Fakes; Set-CmdAvailable -Absent python, pip
        $out = Invoke-Captured { Install-PythonIfMissing }
        $out.Result.Count -eq 1 -and $out.Result[0] -eq $false -and
        @($out.Warnings | Where-Object { $_ -like '*still not on PATH*' }).Count -eq 1 -and $script:refreshCalls -eq 1
    }

    # =====================================================================================
    # Get-DevToolVersionMarkerPath
    # =====================================================================================
    Test-Case 'Marker path lives under LOCALAPPDATA\dotfiles\devtools and ends in <name>.version' {
        (Get-DevToolVersionMarkerPath @{ Name = 'Windows-Operation-Cli' }) -ceq (Join-Path $env:LOCALAPPDATA 'dotfiles\devtools\Windows-Operation-Cli.version')
    }
    Test-Case 'Marker path replaces spaces and punctuation in the tool name with dashes' {
        (Split-Path -Leaf (Get-DevToolVersionMarkerPath @{ Name = 'PowerToys settings (x)' })) -ceq 'PowerToys-settings--x-.version'
    }
    Test-Case 'Marker path cannot escape the devtools directory through the tool name' {
        $p = Get-DevToolVersionMarkerPath @{ Name = '..\..\evil/x' }
        (Split-Path -Parent $p) -ceq (Join-Path $env:LOCALAPPDATA 'dotfiles\devtools') -and (Split-Path -Leaf $p) -ceq '..-..-evil-x.version'
    }
    Test-Case 'Marker path does not create any directory' {
        $null = Get-DevToolVersionMarkerPath @{ Name = 'Anything' }
        -not (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'dotfiles'))
    }
    Test-Case 'Marker path requires a Tool argument' {
        $threw = $false
        try { Get-DevToolVersionMarkerPath $null } catch { $threw = $true }
        $threw
    }

    # =====================================================================================
    # Get-DevToolLatestVersion
    # =====================================================================================
    Test-Case 'Latest version is null without calling the API when the tool has no Repo' {
        Reset-Fakes
        $r = Get-DevToolLatestVersion @{ Name = 'x' }
        $null -eq $r -and $script:restCalls.Count -eq 0
    }
    Test-Case 'Latest version treats an empty Repo like no Repo' {
        Reset-Fakes
        $r = Get-DevToolLatestVersion @{ Name = 'x'; Repo = '' }
        $null -eq $r -and $script:restCalls.Count -eq 0
    }
    Test-Case 'Latest version returns the release tag_name' {
        Reset-Fakes
        $script:restResult = [pscustomobject]@{ tag_name = 'v1.4.2' }
        (Get-DevToolLatestVersion @{ Repo = 'owner/proj' }) -ceq 'v1.4.2'
    }
    Test-Case 'Latest version queries releases/latest of the repo with a User-Agent header' {
        Reset-Fakes
        $script:restResult = [pscustomobject]@{ tag_name = 'v1' }
        $null = Get-DevToolLatestVersion @{ Repo = 'owner/proj' }
        $script:restCalls.Count -eq 1 -and $script:restCalls[0].Uri -ceq 'https://api.github.com/repos/owner/proj/releases/latest' -and
        $script:restCalls[0].Headers['User-Agent'] -ceq 'dotfiles-install-devtools'
    }
    Test-Case 'Latest version is null when the request fails (offline or rate limited)' {
        Reset-Fakes
        $script:restThrow = $true
        $null -eq (Get-DevToolLatestVersion @{ Repo = 'owner/proj' })
    }
    Test-Case 'Latest version is null when the response has no tag_name' {
        Reset-Fakes
        $script:restResult = [pscustomobject]@{ name = 'no tag' }
        $null -eq (Get-DevToolLatestVersion @{ Repo = 'owner/proj' })
    }
    Test-Case 'Latest version is null when the response is empty' {
        Reset-Fakes
        $null -eq (Get-DevToolLatestVersion @{ Repo = 'owner/proj' })
    }

    # =====================================================================================
    # ConvertTo-DevToolVersion
    # =====================================================================================
    foreach ($row in @(
            @('1.2.3', '1.2.3'), @('v1.2.3', '1.2.3'), @('V2.0', '2.0'), @('  v1.2.3  ', '1.2.3'),
            @('1.2.3+build5', '1.2.3'), @('v1.2.3+a+b', '1.2.3'), @("`t1.0.0+meta`n", '1.0.0'), @('1.2.3-beta.1', '1.2.3-beta.1'),
            @('vv1.0', 'v1.0'), @('1.0v', '1.0v'))) {
        Test-Case "ConvertTo-DevToolVersion '$($row[0].Trim())' -> '$($row[1])'" {
            (ConvertTo-DevToolVersion $row[0]) -ceq $row[1]
        }
    }
    Test-Case 'ConvertTo-DevToolVersion returns null for null input' {
        $null -eq (ConvertTo-DevToolVersion $null)
    }
    Test-Case 'ConvertTo-DevToolVersion returns null for an empty string' {
        $null -eq (ConvertTo-DevToolVersion '')
    }
    Test-Case 'ConvertTo-DevToolVersion returns a falsy empty value for whitespace-only input' {
        -not (ConvertTo-DevToolVersion '   ')
    }

    # =====================================================================================
    # Test-DevToolVersionCurrent
    # =====================================================================================
    foreach ($row in @(
            @('1.2.3', '1.2.3', $true), @('1.2.3', '1.2.3.0', $true), @('1.2.3.0', '1.2.3', $true), @('1.2', '1.2.0', $true),
            @('1.3.0', '1.2.9', $true), @('2.0.0', '1.9.9.9', $true), @('1.2.3', '1.2.4', $false), @('1.2.3.1', '1.2.3.2', $false),
            @('1.9', '1.10', $false), @('1.10', '1.9', $true),
            @('v1.2.3', '1.2.3', $true), @('1.2.3+build7', 'v1.2.3', $true), @('1.2.3', '1.2.3+abc', $true),
            @('nightly', 'nightly', $true), @('nightly', 'stable', $false), @('1.2.3', 'nightly', $false),
            @('1.2.3-beta', '1.2.3-beta', $true), @('1.2.3-beta', '1.2.3', $false),
            @('1', '1', $true), @('1', '2', $false))) {
        Test-Case "Version current: installed '$($row[0])' vs latest '$($row[1])' is $($row[2])" {
            (Test-DevToolVersionCurrent $row[0] $row[1]) -eq $row[2]
        }
    }
    Test-Case 'Version current is false when nothing is installed (null)' {
        (Test-DevToolVersionCurrent $null '1.0.0') -eq $false
    }
    Test-Case 'Version current is false when the installed version is empty' {
        (Test-DevToolVersionCurrent '' '1.0.0') -eq $false
    }
    Test-Case 'Version current is false when the installed version is only whitespace' {
        (Test-DevToolVersionCurrent '   ' '1.0.0') -eq $false
    }
    Test-Case 'Version current rejects an empty latest version (mandatory parameter)' {
        $threw = $false
        try { $null = Test-DevToolVersionCurrent '1.0.0' '' } catch { $threw = $true }
        $threw
    }

    # =====================================================================================
    # Test-DevToolTextEqual
    # =====================================================================================
    Test-Case 'Text equal: identical strings' { (Test-DevToolTextEqual 'abc' 'abc') -eq $true }
    Test-Case 'Text equal: CRLF and LF line endings are the same' { (Test-DevToolTextEqual "a`r`nb`r`n" "a`nb`n") -eq $true }
    Test-Case 'Text equal: a leading BOM is ignored on either side' {
        (Test-DevToolTextEqual "$([char]0xFEFF)a`nb" "a`nb") -eq $true -and (Test-DevToolTextEqual "a" "$([char]0xFEFF)a") -eq $true
    }
    Test-Case 'Text equal: trailing newlines are ignored, however many' {
        (Test-DevToolTextEqual "a`n" 'a') -eq $true -and (Test-DevToolTextEqual "a`r`n`r`n" "a`n") -eq $true
    }
    Test-Case 'Text equal: comparison is case-sensitive' { (Test-DevToolTextEqual 'Abc' 'abc') -eq $false }
    Test-Case 'Text equal: differing content is not equal' { (Test-DevToolTextEqual "a`nb" "a`nc") -eq $false }
    Test-Case 'Text equal: trailing spaces are significant' { (Test-DevToolTextEqual 'a ' 'a') -eq $false }
    Test-Case 'Text equal: leading blank lines are significant' { (Test-DevToolTextEqual "`na" 'a') -eq $false }
    Test-Case 'Text equal: a lone CR is not treated as a newline' { (Test-DevToolTextEqual "a`rb" "a`nb") -eq $false }
    Test-Case 'Text equal: null and empty are equal to each other' {
        (Test-DevToolTextEqual $null $null) -eq $true -and (Test-DevToolTextEqual $null '') -eq $true -and (Test-DevToolTextEqual '' $null) -eq $true
    }
    Test-Case 'Text equal: null differs from non-empty text' {
        (Test-DevToolTextEqual $null 'a') -eq $false -and (Test-DevToolTextEqual 'a' $null) -eq $false
    }
    Test-Case 'Text equal: newline-only text equals empty' { (Test-DevToolTextEqual "`r`n" '') -eq $true }

    # =====================================================================================
    # Read-DevToolLocalText
    # =====================================================================================
    $jp = "`u{65E5}`u{672C}`u{8A9E}"
    Test-Case 'Read-DevToolLocalText decodes BOM-less UTF-8 text with non-ASCII characters' {
        $p = Join-Path (New-Scratch) 'nobom.txt'
        [IO.File]::WriteAllText($p, "$jp`nline2", [Text.UTF8Encoding]::new($false))
        (Read-DevToolLocalText $p) -ceq "$jp`nline2"
    }
    Test-Case 'Read-DevToolLocalText strips the BOM from UTF-8-with-BOM files' {
        $p = Join-Path (New-Scratch) 'bom.txt'
        [IO.File]::WriteAllText($p, "$jp", [Text.UTF8Encoding]::new($true))
        $text = Read-DevToolLocalText $p
        $text -ceq $jp -and $text[0] -ne [char]0xFEFF
    }
    Test-Case 'Read-DevToolLocalText preserves CRLF line endings' {
        $p = Join-Path (New-Scratch) 'crlf.txt'
        [IO.File]::WriteAllText($p, "a`r`nb`r`n", [Text.UTF8Encoding]::new($false))
        (Read-DevToolLocalText $p) -ceq "a`r`nb`r`n"
    }
    Test-Case 'Read-DevToolLocalText returns an empty string for an empty file' {
        $p = Join-Path (New-Scratch) 'empty.txt'
        [IO.File]::WriteAllText($p, '')
        (Read-DevToolLocalText $p) -ceq ''
    }
    Test-Case 'Read-DevToolLocalText throws for a missing file' {
        $threw = $false
        try { $null = Read-DevToolLocalText (Join-Path (New-Scratch) 'missing.txt') } catch { $threw = $true }
        $threw
    }
    Test-Case 'Read-DevToolLocalText rejects an empty path (mandatory parameter)' {
        $threw = $false
        try { $null = Read-DevToolLocalText '' } catch { $threw = $true }
        $threw
    }

    # =====================================================================================
    # Get-DevToolInstalledVersion
    # =====================================================================================
    Test-Case "Installed version (product) reads the executable's version info" {
        $exe = (Get-Process -Id $PID).Path
        $expected = ConvertTo-DevToolVersion ((Get-Item -LiteralPath $exe).VersionInfo.ProductVersion)
        $got = Get-DevToolInstalledVersion @{ Name = 't'; VersionSource = 'product'; Path = $exe }
        $expected -match '^\d+\.\d+' -and $got -ceq $expected
    }
    Test-Case 'Installed version (product) is null for a file without version info' {
        $p = Join-Path (New-Scratch) 'plain.exe'
        Set-Content -LiteralPath $p -Value 'not a pe file'
        $null -eq (Get-DevToolInstalledVersion @{ Name = 't'; VersionSource = 'product'; Path = $p })
    }
    Test-Case 'Installed version (product) throws when the file is missing' {
        $threw = $false
        try { $null = Get-DevToolInstalledVersion @{ Name = 't'; VersionSource = 'product'; Path = (Join-Path (New-Scratch) 'gone.exe') } } catch { $threw = $true }
        $threw
    }

    function New-FakeCli {
        param([string]$Body)
        $p = Join-Path (New-Scratch) 'fakecli.ps1'
        Set-Content -LiteralPath $p -Value $Body
        $p
    }
    foreach ($row in @(
            @('prefixed v', "'crit version v0.8.1'; exit 0", '0.8.1'),
            @('bare number', "'crit 2.5.0'; exit 0", '2.5.0'),
            @('build metadata stripped', "'crit 1.4.0+abc123 (windows)'; exit 0", '1.4.0'),
            @('two-component version', "'tool 3.7'; exit 0", '3.7'),
            @('multi-line output', "'crit'; 'v2.1.0'; exit 0", '2.1.0'),
            @('prerelease suffix kept', "'crit 1.0.0-rc1'; exit 0", '1.0.0-rc1'))) {
        Test-Case "Installed version (command) parses --version output: $($row[0])" {
            $p = New-FakeCli $row[1]
            (Get-DevToolInstalledVersion @{ Name = 't'; VersionSource = 'command'; Path = $p }) -ceq $row[2]
        }
    }
    Test-Case 'Installed version (command) passes --version to the executable' {
        $p = New-FakeCli "if (`$args[0] -eq '--version') { 'x 9.9.9' } else { 'x 0.0.1' }; exit 0"
        (Get-DevToolInstalledVersion @{ Name = 't'; VersionSource = 'command'; Path = $p }) -ceq '9.9.9'
    }
    Test-Case 'Installed version (command) is null when output has no version number' {
        $p = New-FakeCli "'hello world'; exit 0"
        $null -eq (Get-DevToolInstalledVersion @{ Name = 't'; VersionSource = 'command'; Path = $p })
    }
    Test-Case 'Installed version (command) is null when the command exits non-zero' {
        $p = New-FakeCli "'crit 1.2.3'; exit 1"
        $null -eq (Get-DevToolInstalledVersion @{ Name = 't'; VersionSource = 'command'; Path = $p })
    }
    Test-Case 'Installed version (command) is null when the command throws' {
        $p = New-FakeCli "throw 'boom'"
        $null -eq (Get-DevToolInstalledVersion @{ Name = 't'; VersionSource = 'command'; Path = $p })
    }
    Test-Case 'Installed version (command) is null when the executable does not exist' {
        $null -eq (Get-DevToolInstalledVersion @{ Name = 't'; VersionSource = 'command'; Path = (Join-Path (New-Scratch) 'nothere.exe') })
    }

    function New-MarkerFixture {
        param([string]$Name = 'Marker-Tool', $MarkerLines, [switch]$NoExe, [switch]$WrongHash)
        $dir = New-Scratch
        $exe = Join-Path $dir 'tool.exe'
        if (-not $NoExe) { Set-Content -LiteralPath $exe -Value 'binary-v1' }
        $tool = @{ Name = $Name; Path = $exe }
        if ($null -ne $MarkerLines) {
            $marker = Get-DevToolVersionMarkerPath $tool
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $marker) | Out-Null
            $hash = if ($WrongHash) { 'DEADBEEF' } elseif ($NoExe) { 'ABC' } else { (Get-FileHash -LiteralPath $exe).Hash }
            Set-Content -LiteralPath $marker -Value ($MarkerLines -f $hash) -NoNewline
        }
        $tool
    }
    Test-Case 'Installed version (marker) returns the recorded tag without the leading v when the hash matches' {
        $t = New-MarkerFixture -Name 'M1' -MarkerLines "v1.2.3`n{0}"
        (Get-DevToolInstalledVersion $t) -ceq '1.2.3'
    }
    Test-Case 'Installed version (marker) accepts a tag without v and CRLF line endings' {
        $t = New-MarkerFixture -Name 'M2' -MarkerLines "2.0.1`r`n{0}"
        (Get-DevToolInstalledVersion $t) -ceq '2.0.1'
    }
    Test-Case 'Installed version (marker) is null when the executable hash differs from the recorded one' {
        $t = New-MarkerFixture -Name 'M3' -MarkerLines "v1.2.3`n{0}" -WrongHash
        $null -eq (Get-DevToolInstalledVersion $t)
    }
    Test-Case 'Installed version (marker) is null when the executable was replaced after the marker was written' {
        $t = New-MarkerFixture -Name 'M4' -MarkerLines "v1.2.3`n{0}"
        Set-Content -LiteralPath $t.Path -Value 'binary-v2'
        $null -eq (Get-DevToolInstalledVersion $t)
    }
    Test-Case 'Installed version (marker) is null when there is no marker file' {
        $t = New-MarkerFixture -Name 'M5'
        $null -eq (Get-DevToolInstalledVersion $t)
    }
    Test-Case 'Installed version (marker) is null when the executable is missing' {
        $t = New-MarkerFixture -Name 'M6' -MarkerLines "v1.2.3`n{0}" -NoExe
        $null -eq (Get-DevToolInstalledVersion $t)
    }
    Test-Case 'Installed version (marker) is null when the marker has only one line' {
        $t = New-MarkerFixture -Name 'M7' -MarkerLines 'v1.2.3'
        $null -eq (Get-DevToolInstalledVersion $t)
    }
    Test-Case 'Installed version (marker) is null when the recorded tag is blank' {
        $t = New-MarkerFixture -Name 'M8' -MarkerLines "   `n{0}"
        $null -eq (Get-DevToolInstalledVersion $t)
    }
    Test-Case 'Installed version (marker) is null for an empty marker file' {
        $t = New-MarkerFixture -Name 'M9' -MarkerLines ''
        $null -eq (Get-DevToolInstalledVersion $t)
    }

    # =====================================================================================
    # Test-DevToolRemoteFilesUpToDate
    # =====================================================================================
    function New-RemoteFilesFixture {
        param([hashtable]$Local, [hashtable]$Remote, [string[]]$Files = @('tools/a.ps1', 'tools/b.ps1'))
        Reset-Fakes
        $dir = New-Scratch
        foreach ($k in $Local.Keys) { [IO.File]::WriteAllText((Join-Path $dir $k), $Local[$k], [Text.UTF8Encoding]::new($false)) }
        foreach ($k in $Remote.Keys) { $script:web["$script:DotfilesRawBase/tools/$k"] = $Remote[$k] }
        @{ Name = 'rf'; Path = (Join-Path $dir 'main.ps1'); RemoteFiles = $Files }
    }
    Test-Case 'Remote files up to date: true when every file matches' {
        $t = New-RemoteFilesFixture @{ 'a.ps1' = 'A'; 'b.ps1' = 'B' } @{ 'a.ps1' = 'A'; 'b.ps1' = 'B' }
        (Test-DevToolRemoteFilesUpToDate $t) -eq $true
    }
    Test-Case 'Remote files up to date: fetches each file from DotfilesRawBase/<relative path>' {
        $t = New-RemoteFilesFixture @{ 'a.ps1' = 'A'; 'b.ps1' = 'B' } @{ 'a.ps1' = 'A'; 'b.ps1' = 'B' }
        $null = Test-DevToolRemoteFilesUpToDate $t
        ($script:webCalls -join '|') -ceq "$script:DotfilesRawBase/tools/a.ps1|$script:DotfilesRawBase/tools/b.ps1"
    }
    Test-Case 'Remote files up to date: line endings and trailing newline differences are ignored' {
        $t = New-RemoteFilesFixture @{ 'a.ps1' = "x`r`ny`r`n"; 'b.ps1' = 'B' } @{ 'a.ps1' = "x`ny"; 'b.ps1' = "B`n" }
        (Test-DevToolRemoteFilesUpToDate $t) -eq $true
    }
    Test-Case 'Remote files up to date: non-ASCII local content is read as UTF-8' {
        $t = New-RemoteFilesFixture @{ 'a.ps1' = $jp; 'b.ps1' = 'B' } @{ 'a.ps1' = $jp; 'b.ps1' = 'B' }
        (Test-DevToolRemoteFilesUpToDate $t) -eq $true
    }
    Test-Case 'Remote files up to date: false when the first file differs' {
        $t = New-RemoteFilesFixture @{ 'a.ps1' = 'old'; 'b.ps1' = 'B' } @{ 'a.ps1' = 'new'; 'b.ps1' = 'B' }
        (Test-DevToolRemoteFilesUpToDate $t) -eq $false
    }
    Test-Case 'Remote files up to date: false when only the second file differs' {
        $t = New-RemoteFilesFixture @{ 'a.ps1' = 'A'; 'b.ps1' = 'old' } @{ 'a.ps1' = 'A'; 'b.ps1' = 'new' }
        (Test-DevToolRemoteFilesUpToDate $t) -eq $false
    }
    Test-Case 'Remote files up to date: false when a local file is missing' {
        $t = New-RemoteFilesFixture @{ 'a.ps1' = 'A' } @{ 'a.ps1' = 'A'; 'b.ps1' = 'B' }
        (Test-DevToolRemoteFilesUpToDate $t) -eq $false
    }
    Test-Case 'Remote files up to date: null when the download fails' {
        $t = New-RemoteFilesFixture @{ 'a.ps1' = 'A'; 'b.ps1' = 'B' } @{ 'a.ps1' = 'A'; 'b.ps1' = 'B' }
        $script:webFail = $true
        $null -eq (Test-DevToolRemoteFilesUpToDate $t)
    }
    Test-Case 'Remote files up to date: null (not false) when a later download fails after an earlier mismatch' {
        $t = New-RemoteFilesFixture @{ 'a.ps1' = 'old'; 'b.ps1' = 'B' } @{ 'a.ps1' = 'new' }
        $null -eq (Test-DevToolRemoteFilesUpToDate $t)
    }
    Test-Case 'Remote files up to date: true when the tool lists no remote files' {
        Reset-Fakes
        (Test-DevToolRemoteFilesUpToDate @{ Name = 'n'; Path = (Join-Path (New-Scratch) 'm.ps1'); RemoteFiles = @() }) -eq $true -and
        (Test-DevToolRemoteFilesUpToDate @{ Name = 'n'; Path = (Join-Path (New-Scratch) 'm.ps1') }) -eq $true -and
        $script:webCalls.Count -eq 0
    }

    # =====================================================================================
    # Test-ToolInstalled
    # =====================================================================================
    # --- psmodule -----------------------------------------------------------------------
    $script:modules = @(); $script:moduleQueries = @()
    function Get-Module {
        [CmdletBinding()]
        param([switch]$ListAvailable, $Name)
        $script:moduleQueries += $Name
        $script:modules | Where-Object { $_.Name -eq $Name }
    }
    Test-Case 'psmodule: installed when the module is available' {
        $script:modules = @([pscustomobject]@{ Name = 'PSFzf' }); $script:moduleQueries = @()
        (Test-ToolInstalled @{ Backend = 'psmodule'; Id = 'PSFzf' }) -eq $true -and $script:moduleQueries[0] -ceq 'PSFzf'
    }
    Test-Case 'psmodule: not installed when the module is not available' {
        $script:modules = @([pscustomobject]@{ Name = 'Other' })
        (Test-ToolInstalled @{ Backend = 'psmodule'; Id = 'PSFzf' }) -eq $false
    }
    Test-Case 'psmodule: not installed when no modules exist at all' {
        $script:modules = @()
        (Test-ToolInstalled @{ Backend = 'psmodule'; Id = 'PSFzf' }) -eq $false
    }
    Remove-Item Function:\Get-Module

    # --- pip ----------------------------------------------------------------------------
    $script:pythonCalls = @(); $script:pipShowExit = 0
    function python { $script:pythonCalls += , @($args); $global:LASTEXITCODE = $script:pipShowExit }
    Test-Case 'pip: installed when the command is on PATH, without asking pip' {
        Reset-Fakes; $script:pythonCalls = @(); Set-CmdAvailable -Present gita
        (Test-ToolInstalled @{ Backend = 'pip'; Id = 'gita'; Cmd = 'gita' }) -eq $true -and $script:pythonCalls.Count -eq 0
    }
    Test-Case 'pip: not installed when neither the command nor python is on PATH' {
        Reset-Fakes; $script:pythonCalls = @(); Set-CmdAvailable -Absent gita, python
        (Test-ToolInstalled @{ Backend = 'pip'; Id = 'gita'; Cmd = 'gita' }) -eq $false -and $script:pythonCalls.Count -eq 0
    }
    Test-Case 'pip: installed when the command is hidden but pip show succeeds' {
        Reset-Fakes; $script:pythonCalls = @(); $script:pipShowExit = 0; Set-CmdAvailable -Absent gita -Present python
        (Test-ToolInstalled @{ Backend = 'pip'; Id = 'gita'; Cmd = 'gita' }) -eq $true -and
        $script:pythonCalls.Count -eq 1 -and ($script:pythonCalls[0] -join ' ') -ceq '-m pip show gita'
    }
    Test-Case 'pip: not installed when pip show fails' {
        Reset-Fakes; $script:pythonCalls = @(); $script:pipShowExit = 1; Set-CmdAvailable -Absent gita -Present python
        (Test-ToolInstalled @{ Backend = 'pip'; Id = 'gita'; Cmd = 'gita' }) -eq $false
    }
    Remove-Item Function:\python

    # --- script -------------------------------------------------------------------------
    Test-Case 'script: installed when the Path file exists' {
        $p = Join-Path (New-Scratch) 'tool.exe'; Set-Content -LiteralPath $p -Value 'x'
        (Test-ToolInstalled @{ Backend = 'script'; Path = $p }) -eq $true
    }
    Test-Case 'script: not installed when the Path file is missing' {
        (Test-ToolInstalled @{ Backend = 'script'; Path = (Join-Path (New-Scratch) 'nope.exe') }) -eq $false
    }
    Test-Case 'script: a directory at Path does not count as installed' {
        (Test-ToolInstalled @{ Backend = 'script'; Path = (New-Scratch) }) -eq $false
    }
    Test-Case 'script: RequiredCommand being absent does not affect the result' {
        Reset-Fakes; Set-CmdAvailable -Absent claude
        $p = Join-Path (New-Scratch) 'tool.exe'; Set-Content -LiteralPath $p -Value 'x'
        (Test-ToolInstalled @{ Backend = 'script'; Path = $p; RequiredCommand = 'claude' }) -eq $true
    }
    Test-Case 'script: Path with wildcard characters is matched literally' {
        $d = New-Scratch
        Set-Content -LiteralPath (Join-Path $d 'real.exe') -Value 'x'
        (Test-ToolInstalled @{ Backend = 'script'; Path = (Join-Path $d '*.exe') }) -eq $false
    }

    # --- claude-plugin ------------------------------------------------------------------
    $script:claudeCalls = @(); $script:claudeOut = '[]'; $script:claudeThrow = $false
    function claude { $script:claudeCalls += , @($args); if ($script:claudeThrow) { throw 'claude exploded' }; $script:claudeOut }
    $pluginTool = @{ Backend = 'claude-plugin'; Id = 'ado-link-bar@dotfiles-mods' }
    Test-Case 'claude-plugin: not installed, and claude is not invoked, when claude is not on PATH' {
        Reset-Fakes; $script:claudeCalls = @(); Set-CmdAvailable -Absent claude
        (Test-ToolInstalled $pluginTool) -eq $false -and $script:claudeCalls.Count -eq 0
    }
    Test-Case 'claude-plugin: installed when the plugin id is in `claude plugin list --json`' {
        Reset-Fakes; $script:claudeCalls = @(); Set-CmdAvailable -Present claude
        $script:claudeOut = '[{"id":"other@m"},{"id":"ado-link-bar@dotfiles-mods","version":"1"}]'
        (Test-ToolInstalled $pluginTool) -eq $true -and ($script:claudeCalls[0] -join ' ') -ceq 'plugin list --json'
    }
    Test-Case 'claude-plugin: installed when the list contains exactly one plugin (single-element JSON array)' {
        Reset-Fakes; Set-CmdAvailable -Present claude
        $script:claudeOut = '[{"id":"ado-link-bar@dotfiles-mods"}]'
        (Test-ToolInstalled $pluginTool) -eq $true
    }
    Test-Case 'claude-plugin: not installed when the id is absent from the list' {
        Reset-Fakes; Set-CmdAvailable -Present claude
        $script:claudeOut = '[{"id":"other@dotfiles-mods"}]'
        (Test-ToolInstalled $pluginTool) -eq $false
    }
    Test-Case 'claude-plugin: the id must match exactly (a different marketplace does not count)' {
        Reset-Fakes; Set-CmdAvailable -Present claude
        $script:claudeOut = '[{"id":"ado-link-bar@someone-else"}]'
        (Test-ToolInstalled $pluginTool) -eq $false
    }
    Test-Case 'claude-plugin: not installed when the plugin list is empty' {
        Reset-Fakes; Set-CmdAvailable -Present claude
        $script:claudeOut = '[]'
        (Test-ToolInstalled $pluginTool) -eq $false
    }
    Test-Case 'claude-plugin: not installed when the output is not valid JSON' {
        Reset-Fakes; Set-CmdAvailable -Present claude
        $script:claudeOut = 'Error: not logged in'
        (Test-ToolInstalled $pluginTool) -eq $false
    }
    Test-Case 'claude-plugin: not installed when running claude throws' {
        Reset-Fakes; Set-CmdAvailable -Present claude
        $script:claudeThrow = $true
        try { (Test-ToolInstalled $pluginTool) -eq $false } finally { $script:claudeThrow = $false }
    }

    # --- remote-config ------------------------------------------------------------------
    function New-RemoteConfigTool {
        param([string]$Dest, [string]$RepoPath = 'app-settings/x/cfg.txt', $Strip)
        $t = @{ Name = 'cfg'; Backend = 'remote-config'; RepoPath = $RepoPath; Dest = $Dest }
        if ($null -ne $Strip) { $t.StripCommentLines = $Strip }
        $t
    }
    function Set-Remote([string]$RepoPath, [string]$Content) { $script:web["$script:DotfilesRawBase/$RepoPath"] = $Content }
    function Get-InstalledResult($Tool) {
        $o = Invoke-Captured { Test-ToolInstalled $Tool }
        [pscustomobject]@{ Value = $o.Result[0]; Count = $o.Result.Count; Warnings = $o.Warnings }
    }

    Test-Case 'remote-config: not installed when Dest does not exist, without any download' {
        Reset-Fakes
        $t = New-RemoteConfigTool (Join-Path (New-Scratch) 'missing.txt')
        (Test-ToolInstalled $t) -eq $false -and $script:webCalls.Count -eq 0
    }
    Test-Case 'remote-config: a directory at Dest does not count as installed' {
        Reset-Fakes
        (Test-ToolInstalled (New-RemoteConfigTool (New-Scratch))) -eq $false
    }
    Test-Case 'remote-config: installed when local and remote content are identical' {
        Reset-Fakes
        $d = Join-Path (New-Scratch) 'cfg.txt'; Set-Content -LiteralPath $d -Value 'hello' -NoNewline
        Set-Remote 'app-settings/x/cfg.txt' 'hello'
        (Test-ToolInstalled (New-RemoteConfigTool $d)) -eq $true -and $script:webCalls[0] -ceq "$script:DotfilesRawBase/app-settings/x/cfg.txt"
    }
    Test-Case 'remote-config: CRLF and trailing-newline differences still count as installed' {
        Reset-Fakes
        $d = Join-Path (New-Scratch) 'cfg.txt'; [IO.File]::WriteAllText($d, "a`r`nb`r`n", [Text.UTF8Encoding]::new($false))
        Set-Remote 'app-settings/x/cfg.txt' "a`nb"
        (Test-ToolInstalled (New-RemoteConfigTool $d)) -eq $true
    }
    Test-Case 'remote-config: non-ASCII content written as BOM-less UTF-8 matches' {
        Reset-Fakes
        $d = Join-Path (New-Scratch) 'cfg.txt'; [IO.File]::WriteAllText($d, $jp, [Text.UTF8Encoding]::new($false))
        Set-Remote 'app-settings/x/cfg.txt' $jp
        (Test-ToolInstalled (New-RemoteConfigTool $d)) -eq $true
    }
    Test-Case 'remote-config: not installed when the content differs' {
        Reset-Fakes
        $d = Join-Path (New-Scratch) 'cfg.txt'; Set-Content -LiteralPath $d -Value 'local' -NoNewline
        Set-Remote 'app-settings/x/cfg.txt' 'remote'
        (Test-ToolInstalled (New-RemoteConfigTool $d)) -eq $false
    }
    Test-Case 'remote-config: StripCommentLines removes the remote header before comparing' {
        Reset-Fakes
        $d = Join-Path (New-Scratch) 'cfg.txt'; Set-Content -LiteralPath $d -Value "body1`nbody2" -NoNewline
        Set-Remote 'app-settings/x/cfg.txt' "# managed by dotfiles`nbody1`nbody2"
        (Test-ToolInstalled (New-RemoteConfigTool $d -Strip 1)) -eq $true -and (Test-ToolInstalled (New-RemoteConfigTool $d)) -eq $false
    }
    Test-Case 'remote-config: keeps the existing file (installed) with a warning when the download fails' {
        Reset-Fakes
        $d = Join-Path (New-Scratch) 'cfg.txt'; Set-Content -LiteralPath $d -Value 'local' -NoNewline
        $script:webFail = $true
        $r = Get-InstalledResult (New-RemoteConfigTool $d)
        $r.Value -eq $true -and $r.Count -eq 1 -and $r.Warnings.Count -eq 1 -and $r.Warnings[0] -like 'cfg: remote config could not be checked*'
    }
    Test-Case 'remote-config: keeps the existing file (installed) with a warning when the remote content is empty' {
        Reset-Fakes
        $d = Join-Path (New-Scratch) 'cfg.txt'; Set-Content -LiteralPath $d -Value 'local' -NoNewline
        Set-Remote 'app-settings/x/cfg.txt' "  `n"
        $r = Get-InstalledResult (New-RemoteConfigTool $d)
        $r.Value -eq $true -and $r.Warnings.Count -eq 1
    }
    Test-Case 'remote-config: JSON that differs only in formatting counts as installed' {
        Reset-Fakes
        $d = Join-Path (New-Scratch) 'cfg.json'; Set-Content -LiteralPath $d -Value '{"a":1,"b":[1,2]}' -NoNewline
        Set-Remote 'app-settings/x/cfg.json' "{`n  `"a`": 1,`n  `"b`": [ 1, 2 ]`n}"
        (Test-ToolInstalled (New-RemoteConfigTool $d -RepoPath 'app-settings/x/cfg.json')) -eq $true
    }
    Test-Case 'remote-config: JSON with different values is not installed' {
        Reset-Fakes
        $d = Join-Path (New-Scratch) 'cfg.json'; Set-Content -LiteralPath $d -Value '{"a":1}' -NoNewline
        Set-Remote 'app-settings/x/cfg.json' '{ "a": 2 }'
        (Test-ToolInstalled (New-RemoteConfigTool $d -RepoPath 'app-settings/x/cfg.json')) -eq $false
    }
    Test-Case 'remote-config: JSON string values are compared case-sensitively' {
        Reset-Fakes
        $d = Join-Path (New-Scratch) 'cfg.json'; Set-Content -LiteralPath $d -Value '{"a":"Value"}' -NoNewline
        Set-Remote 'app-settings/x/cfg.json' '{ "a": "value" }'
        (Test-ToolInstalled (New-RemoteConfigTool $d -RepoPath 'app-settings/x/cfg.json')) -eq $false
    }
    Test-Case 'remote-config: a local file that is not valid JSON is not installed' {
        Reset-Fakes
        $d = Join-Path (New-Scratch) 'cfg.json'; Set-Content -LiteralPath $d -Value '{ broken' -NoNewline
        Set-Remote 'app-settings/x/cfg.json' '{ "a": 1 }'
        (Test-ToolInstalled (New-RemoteConfigTool $d -RepoPath 'app-settings/x/cfg.json')) -eq $false
    }
    Test-Case 'remote-config: formatting-only differences in a non-JSON Dest are real differences' {
        Reset-Fakes
        $d = Join-Path (New-Scratch) 'cfg.toml'; Set-Content -LiteralPath $d -Value 'a=1' -NoNewline
        Set-Remote 'app-settings/x/cfg.toml' 'a = 1'
        (Test-ToolInstalled (New-RemoteConfigTool $d -RepoPath 'app-settings/x/cfg.toml')) -eq $false
    }

    # --- winget / msstore (default branch) ------------------------------------------------
    Test-Case 'winget: installed when the Cmd is on PATH, without calling winget' {
        Reset-Fakes; Set-CmdAvailable -Present starship
        (Test-ToolInstalled @{ Backend = 'winget'; Id = 'Starship.Starship'; Cmd = 'starship' }) -eq $true -and $script:wingetCalls.Count -eq 0
    }
    Test-Case 'winget: falls back to `winget list` when the Cmd is not on PATH and trusts exit code 0' {
        Reset-Fakes; Set-CmdAvailable -Absent starship
        (Test-ToolInstalled @{ Backend = 'winget'; Id = 'Starship.Starship'; Cmd = 'starship' }) -eq $true -and
        $script:wingetCalls.Count -eq 1 -and ($script:wingetCalls[0] -join ' ') -ceq 'list --id Starship.Starship --exact --accept-source-agreements'
    }
    Test-Case 'winget: not installed when `winget list` exits non-zero' {
        Reset-Fakes; Set-CmdAvailable -Absent starship; $script:wingetExit = 1
        (Test-ToolInstalled @{ Backend = 'winget'; Id = 'Starship.Starship'; Cmd = 'starship' }) -eq $false
    }
    Test-Case 'winget: entries without a Cmd are checked through winget only' {
        Reset-Fakes
        (Test-ToolInstalled @{ Backend = 'winget'; Id = 'Microsoft.PowerToys' }) -eq $true -and
        $script:wingetCalls.Count -eq 1 -and ($script:wingetCalls[0] -join ' ') -like 'list --id Microsoft.PowerToys *'
    }
    Test-Case 'winget: entries without a Cmd are not installed when winget exits non-zero' {
        Reset-Fakes; $script:wingetExit = 1
        (Test-ToolInstalled @{ Backend = 'winget'; Id = 'Microsoft.PowerToys' }) -eq $false
    }
    Test-Case 'msstore: uses the same winget list check by Id' {
        Reset-Fakes
        (Test-ToolInstalled @{ Backend = 'msstore'; Id = '9PM860492SZD' }) -eq $true -and ($script:wingetCalls[0] -join ' ') -like 'list --id 9PM860492SZD *'
    }
    Test-Case 'msstore: not installed when winget list exits non-zero' {
        Reset-Fakes; $script:wingetExit = 1
        (Test-ToolInstalled @{ Backend = 'msstore'; Id = '9PM860492SZD' }) -eq $false
    }
    Test-Case 'Test-ToolInstalled always returns a [bool] for every backend' {
        Reset-Fakes; Set-CmdAvailable -Absent starship
        $cases = @(
            @{ Backend = 'winget'; Id = 'a.b'; Cmd = 'starship' }
            @{ Backend = 'script'; Path = (Join-Path (New-Scratch) 'none.exe') }
            @{ Backend = 'remote-config'; Dest = (Join-Path (New-Scratch) 'none.txt'); RepoPath = 'x' }
        )
        @($cases | Where-Object { (Test-ToolInstalled $_) -isnot [bool] }).Count -eq 0
    }

    # =====================================================================================
    # Show-DevEnv
    # =====================================================================================
    function Get-DevEnvLines { @(Show-DevEnv | Out-String -Width 300 -Stream | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ }) }
    Test-Case 'Show-DevEnv lists every catalog tool with its Backend, Id and install status' {
        $script:DevTools = @(
            @{ Name = 'Alpha'; Backend = 'winget'; Id = 'Pub.Alpha' }
            @{ Name = 'Beta'; Backend = 'pip'; Id = 'beta-pkg' }
        )
        function Test-ToolInstalled { param($Tool) $Tool.Name -eq 'Alpha' }
        try { $lines = Get-DevEnvLines } finally { ${function:Test-ToolInstalled} = $origTestToolInstalled; $script:DevTools = $origCatalog }
        $header = $lines | Where-Object { $_ -match '^Tool\s+Backend\s+Id\s+Installed$' }
        $alpha = $lines | Where-Object { $_ -match '^Alpha\s+winget\s+Pub\.Alpha\s+OK$' }
        $beta = $lines | Where-Object { $_ -match '^Beta\s+pip\s+beta-pkg\s+-$' }
        @($header).Count -eq 1 -and @($alpha).Count -eq 1 -and @($beta).Count -eq 1
    }
    Test-Case 'Show-DevEnv reports one row per tool, in catalog order' {
        $script:DevTools = @(
            @{ Name = 'One'; Backend = 'winget'; Id = 'a.One' }
            @{ Name = 'Two'; Backend = 'winget'; Id = 'a.Two' }
            @{ Name = 'Three'; Backend = 'winget'; Id = 'a.Three' }
        )
        function Test-ToolInstalled { param($Tool) $true }
        try { $lines = Get-DevEnvLines } finally { ${function:Test-ToolInstalled} = $origTestToolInstalled; $script:DevTools = $origCatalog }
        $rows = @($lines | Where-Object { $_ -match '^(One|Two|Three)\s' })
        $rows.Count -eq 3 -and ($rows | ForEach-Object { ($_ -split '\s+')[0] }) -join ',' -ceq 'One,Two,Three'
    }
    Test-Case 'Show-DevEnv leaves Id blank for entries that have none (remote-config)' {
        $script:DevTools = @(@{ Name = 'Cfg'; Backend = 'remote-config'; RepoPath = 'x'; Dest = 'y' })
        function Test-ToolInstalled { param($Tool) $false }
        try { $lines = Get-DevEnvLines } finally { ${function:Test-ToolInstalled} = $origTestToolInstalled; $script:DevTools = $origCatalog }
        @($lines | Where-Object { $_ -match '^Cfg\s+remote-config\s+-$' }).Count -eq 1
    }
    Test-Case 'Show-DevEnv prints nothing for an empty catalog' {
        $script:DevTools = @()
        try { $lines = Get-DevEnvLines } finally { $script:DevTools = $origCatalog }
        $lines.Count -eq 0
    }
    Test-Case 'Show-DevEnv uses the real detection: a script tool is OK only when its file exists' {
        $d = New-Scratch
        Set-Content -LiteralPath (Join-Path $d 'here.exe') -Value 'x'
        $script:DevTools = @(
            @{ Name = 'Here'; Backend = 'script'; Id = 'https://example.invalid/i.ps1'; Path = (Join-Path $d 'here.exe') }
            @{ Name = 'Gone'; Backend = 'script'; Id = 'https://example.invalid/i.ps1'; Path = (Join-Path $d 'gone.exe') }
        )
        try { $lines = Get-DevEnvLines } finally { $script:DevTools = $origCatalog }
        @($lines | Where-Object { $_ -match '^Here\s+script\s+\S+\s+OK$' }).Count -eq 1 -and
        @($lines | Where-Object { $_ -match '^Gone\s+script\s+\S+\s+-$' }).Count -eq 1
    }

    # =====================================================================================
    # Sync-DevToolSkills (SymbolicLink creation is faked; everything else is real, in a temp dir)
    # =====================================================================================
    $script:linkCalls = @(); $script:linkFails = $false
    function New-Item {
        [CmdletBinding()]
        param($Path, $ItemType, $Target, $Value, $Name, [switch]$Force)
        if ($ItemType -eq 'SymbolicLink') {
            $script:linkCalls += [pscustomobject]@{ Path = $Path; Target = $Target }
            if ($script:linkFails) { throw 'A required privilege is not held by the client.' }
            Microsoft.PowerShell.Management\New-Item -ItemType Directory -Path $Path | Out-Null
            return
        }
        Microsoft.PowerShell.Management\New-Item @PSBoundParameters
    }
    function New-SkillsFixture {
        param([string[]]$Skills = @(), [string[]]$NoManifest = @())
        $base = New-Scratch
        $agents = Join-Path $base 'agents-skills'
        $claude = Join-Path $base 'claude-skills'
        New-Item -ItemType Directory -Path $agents | Out-Null
        foreach ($s in $Skills) {
            New-Item -ItemType Directory -Path (Join-Path $agents $s) | Out-Null
            Set-Content -LiteralPath (Join-Path $agents "$s\SKILL.md") -Value "skill $s"
            Set-Content -LiteralPath (Join-Path $agents "$s\extra.txt") -Value "extra $s"
        }
        foreach ($s in $NoManifest) {
            New-Item -ItemType Directory -Path (Join-Path $agents $s) | Out-Null
            Set-Content -LiteralPath (Join-Path $agents "$s\readme.txt") -Value 'no skill file'
        }
        @{ Agents = $agents; Claude = $claude }
    }
    function Reset-Links { $script:linkCalls = @(); $script:linkFails = $false }

    Test-Case 'Sync skills: does nothing when the agents skills directory does not exist' {
        Reset-Links
        $base = New-Scratch
        $claude = Join-Path $base 'claude-skills'
        Sync-DevToolSkills -AgentsSkillsDir (Join-Path $base 'absent') -ClaudeSkillsDir $claude
        $script:linkCalls.Count -eq 0 -and -not (Test-Path -LiteralPath $claude)
    }
    Test-Case 'Sync skills: does nothing when the agents skills directory is empty' {
        Reset-Links
        $f = New-SkillsFixture
        Sync-DevToolSkills -AgentsSkillsDir $f.Agents -ClaudeSkillsDir $f.Claude
        $script:linkCalls.Count -eq 0 -and -not (Test-Path -LiteralPath $f.Claude)
    }
    Test-Case 'Sync skills: moves a skill (with all its files) into the Claude skills directory' {
        Reset-Links
        $f = New-SkillsFixture -Skills 'alpha'
        Sync-DevToolSkills -AgentsSkillsDir $f.Agents -ClaudeSkillsDir $f.Claude 6>$null
        (Get-Content -LiteralPath (Join-Path $f.Claude 'alpha\SKILL.md')) -ceq 'skill alpha' -and
        (Get-Content -LiteralPath (Join-Path $f.Claude 'alpha\extra.txt')) -ceq 'extra alpha'
    }
    Test-Case 'Sync skills: leaves a symbolic link at the original location pointing to the moved skill' {
        Reset-Links
        $f = New-SkillsFixture -Skills 'alpha'
        Sync-DevToolSkills -AgentsSkillsDir $f.Agents -ClaudeSkillsDir $f.Claude 6>$null
        $script:linkCalls.Count -eq 1 -and $script:linkCalls[0].Path -ceq (Join-Path $f.Agents 'alpha') -and
        $script:linkCalls[0].Target -ceq (Join-Path $f.Claude 'alpha')
    }
    Test-Case 'Sync skills: reports each linked skill' {
        Reset-Links
        $f = New-SkillsFixture -Skills 'alpha'
        $o = Invoke-Captured { Sync-DevToolSkills -AgentsSkillsDir $f.Agents -ClaudeSkillsDir $f.Claude }
        $o.Host.Count -eq 1 -and $o.Host[0] -ceq 'Linked skill: alpha' -and $o.Result.Count -eq 0
    }
    Test-Case 'Sync skills: creates the Claude skills directory when it does not exist' {
        Reset-Links
        $f = New-SkillsFixture -Skills 'alpha'
        $before = Test-Path -LiteralPath $f.Claude
        Sync-DevToolSkills -AgentsSkillsDir $f.Agents -ClaudeSkillsDir $f.Claude 6>$null
        -not $before -and (Test-Path -LiteralPath $f.Claude -PathType Container)
    }
    Test-Case 'Sync skills: processes several skills' {
        Reset-Links
        $f = New-SkillsFixture -Skills 'a', 'b', 'c'
        Sync-DevToolSkills -AgentsSkillsDir $f.Agents -ClaudeSkillsDir $f.Claude 6>$null
        $script:linkCalls.Count -eq 3 -and @('a', 'b', 'c' | Where-Object { Test-Path -LiteralPath (Join-Path $f.Claude "$_\SKILL.md") }).Count -eq 3
    }
    Test-Case 'Sync skills: ignores directories without SKILL.md' {
        Reset-Links
        $f = New-SkillsFixture -NoManifest 'notaskill'
        Sync-DevToolSkills -AgentsSkillsDir $f.Agents -ClaudeSkillsDir $f.Claude 6>$null
        $script:linkCalls.Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $f.Agents 'notaskill\readme.txt')) -and -not (Test-Path -LiteralPath $f.Claude)
    }
    Test-Case 'Sync skills: ignores loose files in the agents skills directory' {
        Reset-Links
        $f = New-SkillsFixture
        Set-Content -LiteralPath (Join-Path $f.Agents 'SKILL.md') -Value 'stray'
        Sync-DevToolSkills -AgentsSkillsDir $f.Agents -ClaudeSkillsDir $f.Claude 6>$null
        $script:linkCalls.Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $f.Agents 'SKILL.md'))
    }
    Test-Case 'Sync skills: does not overwrite a skill that already exists in the Claude skills directory' {
        Reset-Links
        $f = New-SkillsFixture -Skills 'alpha'
        New-Item -ItemType Directory -Path (Join-Path $f.Claude 'alpha') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $f.Claude 'alpha\SKILL.md') -Value 'existing claude copy'
        Sync-DevToolSkills -AgentsSkillsDir $f.Agents -ClaudeSkillsDir $f.Claude 6>$null
        $script:linkCalls.Count -eq 0 -and
        (Get-Content -LiteralPath (Join-Path $f.Claude 'alpha\SKILL.md')) -ceq 'existing claude copy' -and
        (Get-Content -LiteralPath (Join-Path $f.Agents 'alpha\SKILL.md')) -ceq 'skill alpha'
    }
    Test-Case 'Sync skills: a conflicting file at the destination also blocks the move' {
        Reset-Links
        $f = New-SkillsFixture -Skills 'alpha'
        New-Item -ItemType Directory -Path $f.Claude -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $f.Claude 'alpha') -Value 'a file named alpha'
        Sync-DevToolSkills -AgentsSkillsDir $f.Agents -ClaudeSkillsDir $f.Claude 6>$null
        $script:linkCalls.Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $f.Agents 'alpha\SKILL.md'))
    }
    Test-Case 'Sync skills: skips a skill that is already a link (junction) and leaves its target alone' {
        Reset-Links
        $f = New-SkillsFixture
        $realDir = Join-Path (New-Scratch) 'real-skill'
        New-Item -ItemType Directory -Path $realDir | Out-Null
        Set-Content -LiteralPath (Join-Path $realDir 'SKILL.md') -Value 'linked skill'
        $junction = Join-Path $f.Agents 'linked'
        New-Item -ItemType Junction -Path $junction -Target $realDir | Out-Null
        try {
            Sync-DevToolSkills -AgentsSkillsDir $f.Agents -ClaudeSkillsDir $f.Claude 6>$null
            $script:linkCalls.Count -eq 0 -and -not (Test-Path -LiteralPath $f.Claude) -and (Test-Path -LiteralPath (Join-Path $realDir 'SKILL.md'))
        }
        finally { [IO.Directory]::Delete($junction) }
    }
    Test-Case 'Sync skills: moves only unlinked skills when linked, unlinked and non-skill directories are mixed' {
        Reset-Links
        $f = New-SkillsFixture -Skills 'good' -NoManifest 'plain'
        Sync-DevToolSkills -AgentsSkillsDir $f.Agents -ClaudeSkillsDir $f.Claude 6>$null
        $script:linkCalls.Count -eq 1 -and $script:linkCalls[0].Path -ceq (Join-Path $f.Agents 'good') -and
        -not (Test-Path -LiteralPath (Join-Path $f.Claude 'plain'))
    }
    Test-Case 'Sync skills: rolls the skill back and rethrows when the link cannot be created' {
        Reset-Links; $script:linkFails = $true
        $f = New-SkillsFixture -Skills 'alpha'
        $msg = $null
        try { Sync-DevToolSkills -AgentsSkillsDir $f.Agents -ClaudeSkillsDir $f.Claude 6>$null } catch { $msg = $_.Exception.Message }
        $script:linkFails = $false
        $msg -like '*privilege*' -and
        (Get-Content -LiteralPath (Join-Path $f.Agents 'alpha\SKILL.md')) -ceq 'skill alpha' -and
        (Get-Content -LiteralPath (Join-Path $f.Agents 'alpha\extra.txt')) -ceq 'extra alpha' -and
        -not (Test-Path -LiteralPath (Join-Path $f.Claude 'alpha'))
    }
    Test-Case 'Sync skills: stops at the first failed link and leaves every skill in place' {
        Reset-Links; $script:linkFails = $true
        $f = New-SkillsFixture -Skills 'a', 'b'
        try { Sync-DevToolSkills -AgentsSkillsDir $f.Agents -ClaudeSkillsDir $f.Claude 6>$null } catch {}
        $script:linkFails = $false
        $script:linkCalls.Count -eq 1 -and
        (Test-Path -LiteralPath (Join-Path $f.Agents 'a\SKILL.md')) -and (Test-Path -LiteralPath (Join-Path $f.Agents 'b\SKILL.md'))
    }
    Test-Case 'Sync skills: defaults point at USERPROFILE\.agents\skills and USERPROFILE\.claude\skills' {
        $ast = (Get-Command Sync-DevToolSkills).ScriptBlock.Ast
        $defaults = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] }, $true)
        $text = ($defaults | ForEach-Object { $_.DefaultValue.Extent.Text }) -join '|'
        $text -like "*'.agents\skills'*" -and $text -like "*'.claude\skills'*" -and $text -like '*$env:USERPROFILE*'
    }
    Remove-Item Function:\New-Item

    # =====================================================================================
    # Disable-CodexStatusline
    # =====================================================================================
    function New-CodexFixture {
        param([switch]$Wrapper, [string]$Content = 'wrapper script')
        $env:LOCALAPPDATA = New-Scratch
        $dir = Join-Path $env:LOCALAPPDATA 'CodexStatusline'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $path = Join-Path $dir 'codex-wt.ps1'
        if ($Wrapper) { Set-Content -LiteralPath $path -Value $Content -NoNewline }
        $path
    }
    Test-Case 'Disable-CodexStatusline renames the wrapper to .disabled and keeps its content' {
        $w = New-CodexFixture -Wrapper
        Disable-CodexStatusline 6>$null
        -not (Test-Path -LiteralPath $w) -and (Get-Content -LiteralPath "$w.disabled" -Raw) -ceq 'wrapper script'
    }
    Test-Case 'Disable-CodexStatusline announces the new .disabled path' {
        $w = New-CodexFixture -Wrapper
        $o = Invoke-Captured { Disable-CodexStatusline }
        $o.Host.Count -eq 1 -and $o.Host[0].EndsWith("$w.disabled") -and $o.Result.Count -eq 0
    }
    Test-Case 'Disable-CodexStatusline does nothing and prints nothing when the wrapper is absent' {
        $w = New-CodexFixture
        $o = Invoke-Captured { Disable-CodexStatusline }
        $o.Host.Count -eq 0 -and $o.Result.Count -eq 0 -and -not (Test-Path -LiteralPath "$w.disabled")
    }
    Test-Case 'Disable-CodexStatusline does nothing when the CodexStatusline directory does not exist' {
        $env:LOCALAPPDATA = New-Scratch
        $o = Invoke-Captured { Disable-CodexStatusline }
        $o.Host.Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'CodexStatusline'))
    }
    Test-Case 'Disable-CodexStatusline replaces an older .disabled backup' {
        $w = New-CodexFixture -Wrapper -Content 'new wrapper'
        Set-Content -LiteralPath "$w.disabled" -Value 'old disabled' -NoNewline
        Disable-CodexStatusline 6>$null
        (Get-Content -LiteralPath "$w.disabled" -Raw) -ceq 'new wrapper' -and -not (Test-Path -LiteralPath $w)
    }
    Test-Case 'Disable-CodexStatusline is idempotent: a second run leaves the .disabled file untouched' {
        $w = New-CodexFixture -Wrapper
        Disable-CodexStatusline 6>$null
        $o = Invoke-Captured { Disable-CodexStatusline }
        $o.Host.Count -eq 0 -and (Get-Content -LiteralPath "$w.disabled" -Raw) -ceq 'wrapper script'
    }
    Test-Case 'Disable-CodexStatusline ignores a directory named codex-wt.ps1' {
        $w = New-CodexFixture
        New-Item -ItemType Directory -Path $w | Out-Null
        $o = Invoke-Captured { Disable-CodexStatusline }
        $o.Host.Count -eq 0 -and (Test-Path -LiteralPath $w -PathType Container) -and -not (Test-Path -LiteralPath "$w.disabled")
    }
}
finally {
    $env:PATH = $originalPath
    $env:LOCALAPPDATA = $originalLocalAppData
    if ($global:_dotfilesProfileIdleSubscriptionId) {
        Unregister-Event -SubscriptionId $global:_dotfilesProfileIdleSubscriptionId -ErrorAction Ignore
    }
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}

Complete-Tests
