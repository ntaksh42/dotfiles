# Run with: pwsh -NoProfile -File app-settings/pwsh/tests/Test-InstallDevTools.ps1
# Install-DevTools / Update-DevTools with every external command, the network and the
# catalog faked. Nothing here touches the registry or the real tool installers.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('dotfiles-installdevtools-test-' + [guid]::NewGuid().ToString('N'))
$originalPath = $env:PATH
$originalTemp = $env:TEMP
$originalLocalAppData = $env:LOCALAPPDATA
. (Join-Path $PSScriptRoot 'TestHarness.ps1')

try {
    New-Item -ItemType Directory -Path $scratch | Out-Null
    $env:PATH = ''
    . (Join-Path $root 'Microsoft.PowerShell_profile.ps1')
    $originalCatalog = $script:DevTools

    # --- Fakes (defined after the profile so they shadow the real commands) --------------
    # Script installers are real files executed by Install-DevTools, so the fake download
    # writes this body. It records how it was called and does what the test's spec says.
    $script:installerBody = @'
param([switch]$Silent, [switch]$FromRelease, [string]$Version)
$h = $global:InstallerHarness
$bound = ($PSBoundParameters.Keys | Sort-Object | ForEach-Object { "$_=$($PSBoundParameters[$_])" }) -join ','
$h.Calls.Add("$($h.Uri)|$bound")
if ($h.CreateFile) { Set-Content -LiteralPath $h.CreateFile -Value 'exe' }
if ($h.Hook) { & $h.Hook }
if ($h.Throw) { throw $h.Throw }
'@

    function Add-Event { param([string]$Text) $script:events.Add($Text) }
    function Get-FakeExit {
        param($Argv)
        foreach ($k in @($script:failIds.Keys)) { if ($Argv -contains $k) { return [int]$script:failIds[$k] } }
        0
    }

    # Command existence is decided by $script:cmdPresent (name -> bool); anything else is real.
    function Get-Command {
        [CmdletBinding()]
        param([Parameter(Position = 0)][string]$Name)
        if ($Name -and $script:cmdPresent.ContainsKey($Name)) {
            if ($script:cmdPresent[$Name]) { return [pscustomobject]@{ Name = $Name } }
            return
        }
        Microsoft.PowerShell.Core\Get-Command @PSBoundParameters
    }
    function winget {
        $line = 'winget ' + ($args -join ' ')
        $script:wingetCalls.Add($line); Add-Event $line
        $global:LASTEXITCODE = Get-FakeExit $args
        if ($args[0] -eq 'install' -and $args -contains 'Python.Python.3.12' -and $global:LASTEXITCODE -eq 0 -and $script:pythonAppearsAfterInstall) {
            $script:cmdPresent['python'] = $true; $script:cmdPresent['pip'] = $true
        }
    }
    function pip {
        $line = 'pip ' + ($args -join ' ')
        $script:pipCalls.Add($line); Add-Event $line
        $global:LASTEXITCODE = Get-FakeExit $args
    }
    function python {
        $line = 'python ' + ($args -join ' ')
        $script:pythonCalls.Add($line); Add-Event $line
        $global:LASTEXITCODE = Get-FakeExit $args
    }
    function git {
        $line = 'git ' + ($args -join ' ')
        $script:gitCalls.Add($line); Add-Event $line
        $global:LASTEXITCODE = 0
    }
    function claude {
        $line = 'claude ' + ($args -join ' ')
        $script:claudeCalls.Add($line); Add-Event $line
        $global:LASTEXITCODE = Get-FakeExit $args
        if ($args[0] -eq 'plugin' -and $args[1] -eq 'marketplace' -and $args[2] -eq 'list') {
            return (ConvertTo-Json -InputObject @($script:marketplaces | ForEach-Object { @{ name = $_ } }) -Compress)
        }
        if ($args[2] -eq 'add' -and $global:LASTEXITCODE -eq 0) { $script:marketplaces += $script:marketplaceNameFor[$args[3]] }
    }
    function refreshenv { $script:refreshCount++; Add-Event 'refreshenv' }
    function Install-Module {
        [CmdletBinding()]
        param([string]$Name, [string]$Scope, [switch]$Force, [switch]$AcceptLicense)
        $line = "Install-Module $Name Scope=$Scope Force=$Force AcceptLicense=$AcceptLicense"
        $script:moduleInstalls.Add($line); Add-Event $line
        if ($script:failIds.ContainsKey($Name)) { throw "Install-Module failed for $Name" }
    }
    function Update-Module {
        [CmdletBinding()]
        param([string]$Name)
        $script:moduleUpdates.Add($Name); Add-Event "Update-Module $Name"
        if ($script:failIds.ContainsKey($Name)) { Write-Error "Update-Module failed for $Name" }
    }
    function Get-Module {
        [CmdletBinding()]
        param([string]$Name, [switch]$ListAvailable)
        if ($script:modules -contains $Name) { [pscustomobject]@{ Name = $Name } }
    }
    function Get-Process {
        [CmdletBinding()]
        param([string]$Name)
        if ($script:running -contains $Name) { [pscustomobject]@{ Name = $Name } }
    }
    function Read-Host {
        param($Prompt)
        $script:prompts.Add($Prompt); Add-Event "prompt: $Prompt"
        if ($script:answers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }
        $script:answers.Dequeue()
    }
    function Format-Table { param([switch]$AutoSize) $script:summary = @($input) }
    function Invoke-WebRequest {
        param($Uri, $OutFile, [switch]$UseBasicParsing, $TimeoutSec)
        $script:downloads.Add([pscustomobject]@{ Uri = $Uri; OutFile = $OutFile })
        if ($script:failIds.ContainsKey($Uri)) { throw "download failed: $Uri" }
        $spec = $script:installerSpec[$Uri]
        if (-not $spec) { $spec = @{} }
        $h = $global:InstallerHarness
        $h.Uri = $Uri; $h.CreateFile = $spec.CreateFile; $h.Throw = $spec.Throw; $h.Hook = $spec.Hook
        Set-Content -LiteralPath $OutFile -Value $script:installerBody
    }
    function Disable-CodexStatusline { $script:codexCount++ }
    function Sync-DevToolSkills { $script:syncCount++; Add-Event 'sync' }
    function Test-ToolInstalled {
        param($Tool)
        $script:detectCalls.Add($Tool.Name)
        $script:installedNames -contains $Tool.Name
    }
    function Get-DevToolLatestVersion { param($Tool) $script:latestCalls.Add($Tool.Name); $script:latest[$Tool.Name] }
    function Get-DevToolInstalledVersion { param($Tool) $script:installedVersion[$Tool.Name] }
    function Test-DevToolRemoteFilesUpToDate { param($Tool) $script:remoteUpToDate[$Tool.Name] }
    function Get-DotfilesRemoteConfig {
        param($Tool)
        if (-not $script:remoteContent.ContainsKey($Tool.RepoPath)) { throw "fetch failed: $($Tool.RepoPath)" }
        $script:remoteContent[$Tool.RepoPath]
    }
    function Show-DotfilesRemoteConfigDiff {
        param($Tool, $RemoteContent)
        $script:diffs.Add([pscustomobject]@{ Tool = $Tool.Name; Remote = $RemoteContent }); Add-Event "diff: $($Tool.Name)"
        "DIFFLINE for $($Tool.Name)"
    }

    function Reset-Fake {
        $script:work = Join-Path $scratch ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:work 'tmp'), (Join-Path $script:work 'lad') -Force | Out-Null
        $env:TEMP = Join-Path $script:work 'tmp'
        $env:LOCALAPPDATA = Join-Path $script:work 'lad'
        $script:DevTools = @()
        $script:_cmdCache.Clear()
        $script:cmdPresent = @{ claude = $false; python = $false; pip = $false; git = $false }
        $script:pythonAppearsAfterInstall = $false
        foreach ($n in 'events', 'wingetCalls', 'pipCalls', 'pythonCalls', 'gitCalls', 'claudeCalls', 'moduleInstalls',
            'moduleUpdates', 'prompts', 'detectCalls', 'latestCalls', 'installerCalls') {
            Set-Variable -Scope Script -Name $n -Value ([System.Collections.Generic.List[string]]::new())
        }
        $script:diffs = [System.Collections.Generic.List[object]]::new()
        $script:downloads = [System.Collections.Generic.List[object]]::new()
        $script:answers = [System.Collections.Generic.Queue[string]]::new()
        $script:failIds = @{}
        $script:marketplaces = @()
        $script:marketplaceNameFor = @{ 'owner/repo' = 'mods' }   # the name "marketplace add <source>" registers
        $script:modules = @()
        $script:running = @()
        $script:installedNames = @()
        $script:installerSpec = @{}
        $script:latest = @{}
        $script:installedVersion = @{}
        $script:remoteUpToDate = @{}
        $script:remoteContent = @{}
        $script:refreshCount = 0
        $script:syncCount = 0
        $script:codexCount = 0
        $script:summary = @()
        $script:log = ''
        $global:LASTEXITCODE = 0
        $global:InstallerHarness = @{ Calls = $script:installerCalls }
    }
    function Set-Answers { param([string[]]$Values) foreach ($v in $Values) { $script:answers.Enqueue($v) } }
    function Set-Present { param([string[]]$Names) foreach ($n in $Names) { $script:cmdPresent[$n] = $true } }

    # Runs Install-DevTools and keeps its summary rows ($script:summary) and its host and
    # warning output ($script:log); both are inspected by the cases.
    function Invoke-Install {
        param([switch]$Force, [switch]$Yes)
        $records = @(Install-DevTools -Force:$Force -Yes:$Yes *>&1)
        $script:log = (@($records | ForEach-Object {
                    if ($_ -is [System.Management.Automation.WarningRecord]) { "WARNING: $($_.Message)" }
                    elseif ($_ -is [System.Management.Automation.InformationRecord]) { [string]$_.MessageData }
                    else { [string]$_ }
                }) -join "`n")
    }
    function Get-Row { param([string]$Name) @($script:summary | Where-Object { $_.Tool -eq $Name })[0] }
    function New-Tool {
        param([string]$Name, [string]$Backend, [hashtable]$More = @{})
        $t = @{ Name = $Name; Backend = $Backend; Id = "id.$Name" }
        foreach ($k in $More.Keys) { $t[$k] = $More[$k] }
        $t
    }
    function New-ScriptTool {
        param([string]$Name, [hashtable]$More = @{})
        $m = @{ Id = "https://fake/$Name.ps1"; Path = (Join-Path $script:work "bin\$Name.exe") }
        foreach ($k in $More.Keys) { $m[$k] = $More[$k] }
        New-Tool $Name 'script' $m
    }
    function Get-Calls { param($List) ($List -join ' || ') }

    # ======================================================================================
    # Control flow: nothing to do, confirmation, -Force / -Yes
    # ======================================================================================
    Test-Case 'Everything installed: reports so, runs no installer, asks nothing, and does not refreshenv' {
        Reset-Fake
        $script:DevTools = @((New-Tool 'A' 'winget'), (New-Tool 'B' 'psmodule'))
        $script:installedNames = @('A', 'B')
        Invoke-Install
        $script:log.Contains('All dev tools already installed.') -and
        $script:wingetCalls.Count -eq 0 -and $script:moduleInstalls.Count -eq 0 -and
        $script:prompts.Count -eq 0 -and $script:refreshCount -eq 0 -and $script:summary.Count -eq 0
    }
    Test-Case 'Everything installed: skill sync and the Codex statusline switch-off still run once' {
        Reset-Fake
        $script:DevTools = @((New-Tool 'A' 'winget'))
        $script:installedNames = @('A')
        Invoke-Install
        $script:syncCount -eq 1 -and $script:codexCount -eq 1
    }
    Test-Case 'Each tool is detected exactly once per run' {
        Reset-Fake
        $script:DevTools = @((New-Tool 'A' 'winget'), (New-Tool 'B' 'winget'), (New-Tool 'C' 'winget'))
        $script:installedNames = @('A')
        Invoke-Install -Yes
        $script:detectCalls.Count -eq 3 -and @($script:detectCalls | Select-Object -Unique).Count -eq 3
    }
    Test-Case 'Interactive: asks "Proceed? (y/N)" once, and "n" aborts without installing, syncing or refreshing' {
        Reset-Fake
        $script:DevTools = @((New-Tool 'A' 'winget'))
        Set-Answers 'n'
        Invoke-Install
        $script:prompts.Count -eq 1 -and $script:prompts[0] -ceq 'Proceed? (y/N)' -and
        $script:log.Contains('Aborted.') -and
        $script:wingetCalls.Count -eq 0 -and $script:syncCount -eq 0 -and $script:refreshCount -eq 0 -and
        $script:summary.Count -eq 0 -and $script:codexCount -eq 1
    }
    Test-Case 'Interactive: empty and non-affirmative answers abort' {
        $aborted = 0
        foreach ($answer in '', 'N', 'yeah', 'ye', 'no') {
            Reset-Fake
            $script:DevTools = @((New-Tool 'A' 'winget'))
            Set-Answers $answer
            Invoke-Install
            if ($script:log.Contains('Aborted.') -and $script:wingetCalls.Count -eq 0) { $aborted++ }
        }
        $aborted -eq 5
    }
    Test-Case 'Interactive: y, Y, yes and YES proceed with the install' {
        $installed = 0
        foreach ($answer in 'y', 'Y', 'yes', 'YES') {
            Reset-Fake
            $script:DevTools = @((New-Tool 'A' 'winget'))
            Set-Answers $answer
            Invoke-Install
            if ($script:wingetCalls.Count -eq 1 -and $script:summary.Count -eq 1) { $installed++ }
        }
        $installed -eq 4
    }
    Test-Case '-Force skips the Proceed prompt and installs' {
        Reset-Fake
        $script:DevTools = @((New-Tool 'A' 'winget'))
        Invoke-Install -Force
        $script:prompts.Count -eq 0 -and $script:wingetCalls.Count -eq 1
    }
    Test-Case '-Yes implies -Force: no prompt at all, including the delta question' {
        Reset-Fake
        $script:DevTools = @((New-Tool 'A' 'winget'), (New-Tool 'delta' 'winget' @{ PostInstall = 'delta' }))
        Invoke-Install -Yes
        $script:prompts.Count -eq 0 -and $script:wingetCalls.Count -eq 2 -and $script:gitCalls.Count -eq 3
    }
    Test-Case 'The pending list names each missing tool with backend, id and install action, and omits installed ones' {
        Reset-Fake
        $script:DevTools = @((New-Tool 'Have' 'winget'), (New-Tool 'Need' 'pip' @{ Cmd = 'x' }))
        $script:installedNames = @('Have')
        Set-Present 'pip'
        Set-Answers 'n'
        Invoke-Install
        $script:log.Contains('  - Need [pip] id.Need (install)') -and -not $script:log.Contains('Have')
    }
    Test-Case 'Skill sync runs before the first installer and refreshenv after the last one' {
        Reset-Fake
        $script:DevTools = @((New-Tool 'A' 'winget'), (New-Tool 'B' 'winget'))
        Invoke-Install -Yes
        $e = @($script:events)
        $e[0] -ceq 'sync' -and $e[-1] -ceq 'refreshenv' -and $script:refreshCount -eq 1 -and $script:syncCount -eq 1
    }
    Test-Case 'Tools are installed in catalog order and each is announced' {
        Reset-Fake
        $script:DevTools = @((New-Tool 'Z' 'winget'), (New-Tool 'A' 'winget'), (New-Tool 'M' 'winget'))
        Invoke-Install -Yes
        $order = @($script:wingetCalls | ForEach-Object { ($_ -split ' ')[3] })
        ($order -join ',') -ceq 'id.Z,id.A,id.M' -and $script:log.Contains('Installing Z...') -and $script:log.Contains('Installing M...')
    }
    Test-Case 'Summary lists every attempted tool with Install action and OK; installed tools are absent' {
        Reset-Fake
        $script:DevTools = @((New-Tool 'A' 'winget'), (New-Tool 'B' 'winget'), (New-Tool 'Have' 'winget'))
        $script:installedNames = @('Have')
        Invoke-Install -Yes
        $script:summary.Count -eq 2 -and
        (Get-Row 'A').Result -ceq 'OK' -and (Get-Row 'A').Action -ceq 'Installing' -and
        (Get-Row 'B').Result -ceq 'OK' -and $null -eq (Get-Row 'Have')
    }
    Test-Case 'An installed tool is skipped and a missing one is installed in the same run' {
        Reset-Fake
        $script:DevTools = @((New-Tool 'Have' 'winget'), (New-Tool 'Need' 'winget'))
        $script:installedNames = @('Have')
        Invoke-Install -Yes
        $script:wingetCalls.Count -eq 1 -and $script:wingetCalls[0].Contains('id.Need') -and -not (Get-Calls $script:wingetCalls).Contains('id.Have')
    }

    # ======================================================================================
    # winget / msstore
    # ======================================================================================
    Test-Case 'winget backend installs with --exact and the winget source' {
        Reset-Fake
        $script:DevTools = @((New-Tool 'A' 'winget'))
        Invoke-Install -Yes
        $script:wingetCalls.Count -eq 1 -and
        $script:wingetCalls[0] -ceq 'winget install --id id.A --exact --source winget --accept-package-agreements --accept-source-agreements'
    }
    Test-Case 'msstore backend installs from the msstore source without --exact' {
        Reset-Fake
        $script:DevTools = @((New-Tool 'Store' 'msstore'))
        Invoke-Install -Yes
        $script:wingetCalls.Count -eq 1 -and
        $script:wingetCalls[0] -ceq 'winget install --id id.Store --source msstore --accept-package-agreements --accept-source-agreements'
    }
    Test-Case 'A failing winget install is FAILED with the exit code, and the next tools still install' {
        Reset-Fake
        $script:DevTools = @((New-Tool 'A' 'winget'), (New-Tool 'Bad' 'winget'), (New-Tool 'C' 'winget'))
        $script:failIds['id.Bad'] = 1603
        Invoke-Install -Yes
        $script:wingetCalls.Count -eq 3 -and
        (Get-Row 'A').Result -ceq 'OK' -and (Get-Row 'Bad').Result -ceq 'FAILED' -and (Get-Row 'C').Result -ceq 'OK' -and
        $script:log.Contains('WARNING:   Failed: winget install id.Bad failed with exit code 1603.')
    }
    Test-Case 'A failing msstore install is FAILED and does not stop a later winget tool' {
        Reset-Fake
        $script:DevTools = @((New-Tool 'Store' 'msstore'), (New-Tool 'A' 'winget'))
        $script:failIds['id.Store'] = 1
        Invoke-Install -Yes
        (Get-Row 'Store').Result -ceq 'FAILED' -and (Get-Row 'A').Result -ceq 'OK'
    }
    Test-Case 'refreshenv still runs once when every install failed' {
        Reset-Fake
        $script:DevTools = @((New-Tool 'A' 'winget'), (New-Tool 'B' 'winget'))
        $script:failIds['id.A'] = 1; $script:failIds['id.B'] = 1
        Invoke-Install -Yes
        $script:refreshCount -eq 1 -and (Get-Row 'A').Result -ceq 'FAILED' -and (Get-Row 'B').Result -ceq 'FAILED'
    }

    # ======================================================================================
    # RequiredCommand
    # ======================================================================================
    Test-Case 'Missing RequiredCommand: tool is skipped with a warning, nothing is launched, others proceed' {
        Reset-Fake
        $script:DevTools = @((New-Tool 'NeedsCli' 'winget' @{ RequiredCommand = 'claude' }), (New-Tool 'Plain' 'winget'))
        Invoke-Install -Yes
        $script:wingetCalls.Count -eq 1 -and $script:wingetCalls[0].Contains('id.Plain') -and
        $null -eq (Get-Row 'NeedsCli') -and
        $script:log.Contains("WARNING: NeedsCli: 'claude' not found; skipping.")
    }
    Test-Case 'Missing RequiredCommand: the skipped tool is not listed in the pending list' {
        Reset-Fake
        $script:DevTools = @((New-Tool 'NeedsCli' 'winget' @{ RequiredCommand = 'claude' }), (New-Tool 'Plain' 'winget'))
        Set-Answers 'n'
        Invoke-Install
        $script:log.Contains('Plain [winget]') -and -not $script:log.Contains('NeedsCli [winget]')
    }
    Test-Case 'Present RequiredCommand: the tool installs normally' {
        Reset-Fake
        Set-Present 'claude'
        $script:DevTools = @((New-Tool 'NeedsCli' 'winget' @{ RequiredCommand = 'claude' }))
        Invoke-Install -Yes
        $script:wingetCalls.Count -eq 1 -and (Get-Row 'NeedsCli').Result -ceq 'OK'
    }
    Test-Case 'Missing RequiredCommand on every pending tool ends with the already-installed message and no prompt' {
        Reset-Fake
        $script:DevTools = @((New-Tool 'NeedsCli' 'winget' @{ RequiredCommand = 'claude' }))
        Invoke-Install
        $script:log.Contains('All dev tools already installed.') -and $script:prompts.Count -eq 0 -and
        $script:wingetCalls.Count -eq 0 -and $script:syncCount -eq 1
    }

    # ======================================================================================
    # pip
    # ======================================================================================
    Test-Case 'pip backend uses "pip install --user" when pip is on PATH' {
        Reset-Fake
        Set-Present 'pip', 'python'
        $script:DevTools = @((New-Tool 'gita' 'pip'))
        Invoke-Install -Yes
        $script:pipCalls.Count -eq 1 -and $script:pipCalls[0] -ceq 'pip install --user id.gita' -and
        $script:pythonCalls.Count -eq 0 -and $script:wingetCalls.Count -eq 0
    }
    Test-Case 'pip backend falls back to "python -m pip install --user" when only python exists' {
        Reset-Fake
        Set-Present 'python'
        $script:DevTools = @((New-Tool 'gita' 'pip'))
        Invoke-Install -Yes
        $script:pythonCalls.Count -eq 1 -and $script:pythonCalls[0] -ceq 'python -m pip install --user id.gita' -and
        $script:pipCalls.Count -eq 0 -and (Get-Row 'gita').Result -ceq 'OK'
    }
    Test-Case 'pip backend installs Python via winget first when neither python nor pip exists' {
        Reset-Fake
        $script:pythonAppearsAfterInstall = $true
        $script:DevTools = @((New-Tool 'gita' 'pip'))
        Invoke-Install -Yes
        $script:wingetCalls.Count -eq 1 -and
        $script:wingetCalls[0] -ceq 'winget install --id Python.Python.3.12 --exact --source winget --accept-package-agreements --accept-source-agreements' -and
        $script:pipCalls.Count -eq 1 -and (Get-Row 'gita').Result -ceq 'OK' -and
        @($script:events).IndexOf($script:wingetCalls[0]) -lt @($script:events).IndexOf('pip install --user id.gita')
    }
    Test-Case 'pip backend: refreshenv runs after the Python install (and once more at the end)' {
        Reset-Fake
        $script:pythonAppearsAfterInstall = $true
        $script:DevTools = @((New-Tool 'gita' 'pip'))
        Invoke-Install -Yes
        $script:refreshCount -eq 2
    }
    Test-Case 'pip backend: Python is installed once even when several pip tools are pending' {
        Reset-Fake
        $script:pythonAppearsAfterInstall = $true
        $script:DevTools = @((New-Tool 'p1' 'pip'), (New-Tool 'p2' 'pip'))
        Invoke-Install -Yes
        @($script:wingetCalls | Where-Object { $_.Contains('Python.Python.3.12') }).Count -eq 1 -and $script:pipCalls.Count -eq 2
    }
    Test-Case 'pip backend: a failed Python install makes the tool FAILED and pip is never called' {
        Reset-Fake
        $script:pythonAppearsAfterInstall = $true
        $script:failIds['Python.Python.3.12'] = 1
        $script:DevTools = @((New-Tool 'gita' 'pip'), (New-Tool 'A' 'winget'))
        Invoke-Install -Yes
        (Get-Row 'gita').Result -ceq 'FAILED' -and $script:pipCalls.Count -eq 0 -and $script:pythonCalls.Count -eq 0 -and
        (Get-Row 'A').Result -ceq 'OK'
    }
    Test-Case 'pip backend: Python installed but still not on PATH is FAILED with a PATH warning' {
        Reset-Fake
        $script:pythonAppearsAfterInstall = $false
        $script:DevTools = @((New-Tool 'gita' 'pip'))
        Invoke-Install -Yes
        (Get-Row 'gita').Result -ceq 'FAILED' -and $script:pipCalls.Count -eq 0 -and
        $script:log.Contains('python/pip is still not on PATH') -and
        $script:log.Contains('Python/pip not found and could not be installed')
    }
    Test-Case 'pip backend: a non-zero pip exit is FAILED and names the command' {
        Reset-Fake
        Set-Present 'pip'
        $script:failIds['id.gita'] = 1
        $script:DevTools = @((New-Tool 'gita' 'pip'), (New-Tool 'A' 'winget'))
        Invoke-Install -Yes
        (Get-Row 'gita').Result -ceq 'FAILED' -and (Get-Row 'A').Result -ceq 'OK' -and
        $script:log.Contains('pip install id.gita failed with exit code 1.')
    }
    Test-Case 'pip backend: a non-zero "python -m pip" exit is FAILED and names that command' {
        Reset-Fake
        Set-Present 'python'
        $script:failIds['id.gita'] = 2
        $script:DevTools = @((New-Tool 'gita' 'pip'))
        Invoke-Install -Yes
        (Get-Row 'gita').Result -ceq 'FAILED' -and $script:log.Contains('python -m pip install id.gita failed with exit code 2.')
    }

    # ======================================================================================
    # psmodule
    # ======================================================================================
    Test-Case 'psmodule backend calls Install-Module with CurrentUser scope, -Force and -AcceptLicense' {
        Reset-Fake
        $script:DevTools = @((New-Tool 'PSFzf' 'psmodule' @{ Id = 'PSFzf' }))
        Invoke-Install -Yes
        $script:moduleInstalls.Count -eq 1 -and
        $script:moduleInstalls[0] -ceq 'Install-Module PSFzf Scope=CurrentUser Force=True AcceptLicense=True' -and
        (Get-Row 'PSFzf').Result -ceq 'OK'
    }
    Test-Case 'psmodule backend: an installed module is not reinstalled' {
        Reset-Fake
        $script:DevTools = @((New-Tool 'Have' 'psmodule' @{ Id = 'Have' }), (New-Tool 'Need' 'psmodule' @{ Id = 'Need' }))
        $script:installedNames = @('Have')
        Invoke-Install -Yes
        $script:moduleInstalls.Count -eq 1 -and $script:moduleInstalls[0].StartsWith('Install-Module Need ')
    }
    Test-Case 'psmodule backend: a throwing Install-Module is FAILED and the next module still installs' {
        Reset-Fake
        $script:failIds['Bad'] = 1
        $script:DevTools = @((New-Tool 'Bad' 'psmodule' @{ Id = 'Bad' }), (New-Tool 'Good' 'psmodule' @{ Id = 'Good' }))
        Invoke-Install -Yes
        (Get-Row 'Bad').Result -ceq 'FAILED' -and (Get-Row 'Good').Result -ceq 'OK' -and
        $script:log.Contains('Install-Module failed for Bad') -and $script:moduleInstalls.Count -eq 2
    }

    # ======================================================================================
    # claude-plugin
    # ======================================================================================
    $plugin = { param($n) New-Tool $n 'claude-plugin' @{ Id = "$n@mods"; Marketplace = 'mods'; MarketplaceSource = 'owner/repo'; RequiredCommand = 'claude' } }

    Test-Case 'claude-plugin: unknown marketplace is added from MarketplaceSource, then the plugin is installed' {
        Reset-Fake
        Set-Present 'claude'
        $script:DevTools = @((& $plugin 'p1'))
        Invoke-Install -Yes
        ($script:claudeCalls -join '|') -ceq 'claude plugin marketplace list --json|claude plugin marketplace add owner/repo|claude plugin install p1@mods' -and
        (Get-Row 'p1').Result -ceq 'OK'
    }
    Test-Case 'claude-plugin: a marketplace that is already registered is not added again' {
        Reset-Fake
        Set-Present 'claude'
        $script:marketplaces = @('mods')
        $script:DevTools = @((& $plugin 'p1'))
        Invoke-Install -Yes
        ($script:claudeCalls -join '|') -ceq 'claude plugin marketplace list --json|claude plugin install p1@mods'
    }
    Test-Case 'claude-plugin: a marketplace with a different name is not mistaken for the wanted one' {
        Reset-Fake
        Set-Present 'claude'
        $script:marketplaces = @('other')
        $script:DevTools = @((& $plugin 'p1'))
        Invoke-Install -Yes
        $script:claudeCalls.Contains('claude plugin marketplace add owner/repo')
    }
    Test-Case 'claude-plugin: two plugins from one marketplace add it only once' {
        Reset-Fake
        Set-Present 'claude'
        $script:DevTools = @((& $plugin 'p1'), (& $plugin 'p2'))
        Invoke-Install -Yes
        @($script:claudeCalls | Where-Object { $_ -like '*marketplace add*' }).Count -eq 1 -and
        $script:claudeCalls.Contains('claude plugin install p1@mods') -and $script:claudeCalls.Contains('claude plugin install p2@mods')
    }
    Test-Case 'claude-plugin: a failed marketplace add is FAILED and the plugin install is not attempted' {
        Reset-Fake
        Set-Present 'claude'
        $script:failIds['add'] = 1
        $script:DevTools = @((& $plugin 'p1'), (New-Tool 'A' 'winget'))
        Invoke-Install -Yes
        (Get-Row 'p1').Result -ceq 'FAILED' -and -not $script:claudeCalls.Contains('claude plugin install p1@mods') -and
        $script:log.Contains('claude plugin marketplace add owner/repo failed with exit code 1.') -and
        (Get-Row 'A').Result -ceq 'OK'
    }
    Test-Case 'claude-plugin: a failed plugin install is FAILED and later plugins are still tried' {
        Reset-Fake
        Set-Present 'claude'
        $script:failIds['p1@mods'] = 1
        $script:DevTools = @((& $plugin 'p1'), (& $plugin 'p2'))
        Invoke-Install -Yes
        (Get-Row 'p1').Result -ceq 'FAILED' -and (Get-Row 'p2').Result -ceq 'OK' -and
        $script:log.Contains('claude plugin install p1@mods failed with exit code 1.')
    }
    Test-Case 'claude-plugin: without claude on PATH the plugin is skipped and claude is never invoked' {
        Reset-Fake
        $script:DevTools = @((& $plugin 'p1'))
        Invoke-Install -Yes
        $script:claudeCalls.Count -eq 0 -and $null -eq (Get-Row 'p1') -and $script:log.Contains("p1: 'claude' not found; skipping.")
    }
    Test-Case 'claude-plugin: an installed plugin is skipped without any claude call' {
        Reset-Fake
        Set-Present 'claude'
        $script:DevTools = @((& $plugin 'p1'))
        $script:installedNames = @('p1')
        Invoke-Install -Yes
        $script:claudeCalls.Count -eq 0
    }

    # ======================================================================================
    # script backend: install
    # ======================================================================================
    Test-Case 'script backend downloads Id to a sanitized installer name under TEMP and runs it without arguments' {
        Reset-Fake
        $script:DevTools = @((New-ScriptTool 'My Tool'))
        Invoke-Install -Yes
        $script:downloads.Count -eq 1 -and $script:downloads[0].Uri -ceq 'https://fake/My Tool.ps1' -and
        $script:downloads[0].OutFile -ceq (Join-Path $env:TEMP 'My-Tool-install.ps1') -and
        ($script:installerCalls -join '|') -ceq 'https://fake/My Tool.ps1|' -and (Get-Row 'My Tool').Result -ceq 'OK'
    }
    Test-Case 'script backend passes Args as named parameters' {
        Reset-Fake
        $script:DevTools = @((New-ScriptTool 'S1' @{ Args = @{ Silent = $true } }))
        Invoke-Install -Yes
        ($script:installerCalls -join '|') -ceq 'https://fake/S1.ps1|Silent=True' -and (Get-Row 'S1').Result -ceq 'OK'
    }
    Test-Case 'script backend: a throwing installer is FAILED with its message and the next tool still installs' {
        Reset-Fake
        $script:installerSpec['https://fake/Bad.ps1'] = @{ Throw = 'boom from installer' }
        $script:DevTools = @((New-ScriptTool 'Bad'), (New-Tool 'A' 'winget'))
        Invoke-Install -Yes
        (Get-Row 'Bad').Result -ceq 'FAILED' -and (Get-Row 'A').Result -ceq 'OK' -and
        $script:log.Contains('WARNING:   Failed: boom from installer')
    }
    Test-Case 'script backend: a failed download is FAILED and the installer never runs' {
        Reset-Fake
        $script:failIds['https://fake/Bad.ps1'] = 1
        $script:DevTools = @((New-ScriptTool 'Bad'))
        Invoke-Install -Yes
        (Get-Row 'Bad').Result -ceq 'FAILED' -and $script:installerCalls.Count -eq 0 -and $script:log.Contains('download failed')
    }
    Test-Case 'script backend: an installed script tool is not downloaded again (InstallOnly)' {
        Reset-Fake
        $script:DevTools = @((New-ScriptTool 'Once' @{ InstallOnly = $true }))
        $script:installedNames = @('Once')
        Invoke-Install -Yes
        $script:downloads.Count -eq 0 -and $script:latestCalls.Count -eq 0
    }

    # --- reboot-required exit code ---------------------------------------------------------
    Test-Case 'Reboot code: matching exit code is reported as RESTART REQUIRED with a warning' {
        Reset-Fake
        $script:installerSpec['https://fake/Rb.ps1'] = @{ Throw = 'msiexec failed with exit code 3010.' }
        $script:DevTools = @((New-ScriptTool 'Rb' @{ RebootRequiredExitCode = 3010 }))
        Invoke-Install -Yes
        (Get-Row 'Rb').Result -ceq 'RESTART REQUIRED' -and
        $script:log.Contains('Windows must be restarted before using Rb')
    }
    Test-Case 'Reboot code: a different exit code is still FAILED' {
        Reset-Fake
        $script:installerSpec['https://fake/Rb.ps1'] = @{ Throw = 'msiexec failed with exit code 1603.' }
        $script:DevTools = @((New-ScriptTool 'Rb' @{ RebootRequiredExitCode = 3010 }))
        Invoke-Install -Yes
        (Get-Row 'Rb').Result -ceq 'FAILED' -and -not $script:log.Contains('must be restarted')
    }
    Test-Case 'Reboot code: exit code 3010 is FAILED when the tool declares no RebootRequiredExitCode' {
        Reset-Fake
        $script:installerSpec['https://fake/Rb.ps1'] = @{ Throw = 'msiexec failed with exit code 3010.' }
        $script:DevTools = @((New-ScriptTool 'Rb'))
        Invoke-Install -Yes
        (Get-Row 'Rb').Result -ceq 'FAILED'
    }
    Test-Case 'Reboot code: a restart-pending install does not stop later tools' {
        Reset-Fake
        $script:installerSpec['https://fake/Rb.ps1'] = @{ Throw = 'x failed with exit code 3010' }
        $script:DevTools = @((New-ScriptTool 'Rb' @{ RebootRequiredExitCode = 3010 }), (New-Tool 'A' 'winget'))
        Invoke-Install -Yes
        (Get-Row 'A').Result -ceq 'OK' -and $script:wingetCalls.Count -eq 1
    }

    # --- RequiredCommand after a script install ------------------------------------------
    Test-Case 'script backend: RequiredCommand that disappears after the installer is FAILED with an MCP message' {
        Reset-Fake
        Set-Present 'claude'
        $present = $script:cmdPresent   # the hook runs inside the downloaded script, so capture the table
        $script:installerSpec['https://fake/Mcp.ps1'] = @{ Hook = { $present['claude'] = $false }.GetNewClosure() }
        $script:DevTools = @((New-ScriptTool 'Mcp' @{ RequiredCommand = 'claude' }))
        Invoke-Install -Yes
        $script:installerCalls.Count -eq 1 -and (Get-Row 'Mcp').Result -ceq 'FAILED' -and
        $script:log.Contains("Mcp requires 'claude' to register its MCP server.")
    }
    Test-Case 'script backend: RequiredCommand still present after the installer is OK' {
        Reset-Fake
        Set-Present 'claude'
        $script:DevTools = @((New-ScriptTool 'Mcp' @{ RequiredCommand = 'claude' }))
        Invoke-Install -Yes
        (Get-Row 'Mcp').Result -ceq 'OK'
    }

    # --- Windows-Operation-Cli: release tag handed to the installer -----------------------
    Test-Case 'Windows-Operation-Cli fresh install passes the latest release tag as -Version, keeping its other Args' {
        Reset-Fake
        Set-Present 'claude'
        $script:latest['Windows-Operation-Cli'] = 'v2.3.4'
        $script:DevTools = @((New-ScriptTool 'Windows-Operation-Cli' @{ Args = @{ FromRelease = $true }; RequiredCommand = 'claude'; Repo = 'o/woc' }))
        Invoke-Install -Yes
        ($script:installerCalls -join '|') -ceq 'https://fake/Windows-Operation-Cli.ps1|FromRelease=True,Version=v2.3.4'
    }
    Test-Case 'Windows-Operation-Cli does not mutate the catalog Args hashtable' {
        Reset-Fake
        Set-Present 'claude'
        $script:latest['Windows-Operation-Cli'] = 'v2.3.4'
        $script:DevTools = @((New-ScriptTool 'Windows-Operation-Cli' @{ Args = @{ FromRelease = $true }; RequiredCommand = 'claude'; Repo = 'o/woc' }))
        Invoke-Install -Yes
        -not $script:DevTools[0].Args.ContainsKey('Version') -and $script:DevTools[0].Args.Count -eq 1
    }
    Test-Case 'Windows-Operation-Cli: an unresolvable latest tag is FAILED and the installer is not executed' {
        Reset-Fake
        Set-Present 'claude'
        $script:DevTools = @((New-ScriptTool 'Windows-Operation-Cli' @{ Args = @{ FromRelease = $true }; RequiredCommand = 'claude'; Repo = 'o/woc' }))
        Invoke-Install -Yes
        (Get-Row 'Windows-Operation-Cli').Result -ceq 'FAILED' -and $script:installerCalls.Count -eq 0 -and
        $script:log.Contains('Windows-Operation-Cli release could not be checked.')
    }

    # --- version marker ---------------------------------------------------------------------
    Test-Case 'Version marker: a Repo tool without VersionSource records "<tag>\n<hash of installed file>"' {
        Reset-Fake
        $path = Join-Path $script:work 'bin\Mk.exe'
        $script:installerSpec['https://fake/Mk.ps1'] = @{ CreateFile = $path }
        $script:latest['Mk'] = 'v1.2.0'
        $script:DevTools = @((New-ScriptTool 'Mk' @{ Repo = 'o/mk'; Path = $path }))
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        Invoke-Install -Yes
        $marker = Join-Path $env:LOCALAPPDATA 'dotfiles\devtools\Mk.version'
        $lines = @((Get-Content -LiteralPath $marker))
        (Get-Row 'Mk').Result -ceq 'OK' -and $lines.Count -eq 2 -and $lines[0] -ceq 'v1.2.0' -and
        $lines[1] -ceq (Get-FileHash -LiteralPath $path).Hash
    }
    Test-Case 'Version marker: not written for a VersionSource tool or a tool without Repo' {
        Reset-Fake
        $script:latest['Vs'] = 'v1.0.0'
        $script:DevTools = @((New-ScriptTool 'Vs' @{ Repo = 'o/vs'; VersionSource = 'command' }), (New-ScriptTool 'NoRepo'))
        Invoke-Install -Yes
        -not (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'dotfiles\devtools')) -and
        (Get-Row 'Vs').Result -ceq 'OK' -and (Get-Row 'NoRepo').Result -ceq 'OK'
    }
    Test-Case 'Version marker: the latest tag is looked up only once for a fresh install' {
        Reset-Fake
        $path = Join-Path $script:work 'bin\Mk.exe'
        $script:installerSpec['https://fake/Mk.ps1'] = @{ CreateFile = $path }
        $script:latest['Mk'] = 'v1.2.0'
        $script:DevTools = @((New-ScriptTool 'Mk' @{ Repo = 'o/mk'; Path = $path }))
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        Invoke-Install -Yes
        $script:latestCalls.Count -eq 1
    }

    # ======================================================================================
    # script backend: update detection
    # ======================================================================================
    Test-Case 'Update: installed Repo tool older than latest is listed with the update action' {
        Reset-Fake
        $script:installedNames = @('Up'); $script:installedVersion['Up'] = '1.0.0'; $script:latest['Up'] = 'v1.1.0'
        $script:DevTools = @((New-ScriptTool 'Up' @{ Repo = 'o/up'; VersionSource = 'command' }))
        Set-Answers 'n'
        Invoke-Install
        $script:log.Contains('  - Up [script] https://fake/Up.ps1 (update)') -and $script:downloads.Count -eq 0
    }
    Test-Case 'Update: installed Repo tool older than latest is re-run with action Updating' {
        Reset-Fake
        $path = Join-Path $script:work 'bin\Up.exe'
        $script:installerSpec['https://fake/Up.ps1'] = @{ CreateFile = $path }
        $script:installedNames = @('Up'); $script:installedVersion['Up'] = '1.0.0'; $script:latest['Up'] = 'v1.1.0'
        $script:DevTools = @((New-ScriptTool 'Up' @{ Repo = 'o/up'; VersionSource = 'command'; Path = $path }))
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        Invoke-Install -Yes
        $script:installerCalls.Count -eq 1 -and (Get-Row 'Up').Action -ceq 'Updating' -and $script:log.Contains('Updating Up...')
    }
    Test-Case 'Update: the latest tag fetched during detection is reused, not fetched again' {
        Reset-Fake
        $path = Join-Path $script:work 'bin\Up.exe'
        $script:installerSpec['https://fake/Up.ps1'] = @{ CreateFile = $path }
        $script:installedNames = @('Up'); $script:installedVersion['Up'] = '1.0.0'; $script:latest['Up'] = 'v1.1.0'
        $script:DevTools = @((New-ScriptTool 'Up' @{ Repo = 'o/up'; Path = $path }))
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        Invoke-Install -Yes
        $script:latestCalls.Count -eq 1 -and
        ((Get-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'dotfiles\devtools\Up.version'))[0]) -ceq 'v1.1.0'
    }
    Test-Case 'Update: an installed tool already at the latest version is skipped (also 1.2.3 vs v1.2.3.0)' {
        Reset-Fake
        $script:installedNames = @('Cur'); $script:installedVersion['Cur'] = '1.2.3'; $script:latest['Cur'] = 'v1.2.3.0'
        $script:DevTools = @((New-ScriptTool 'Cur' @{ Repo = 'o/cur'; VersionSource = 'command' }))
        Invoke-Install -Yes
        $script:downloads.Count -eq 0 -and $script:log.Contains('All dev tools already installed.')
    }
    Test-Case 'Update: an installed tool newer than the latest release is left alone' {
        Reset-Fake
        $script:installedNames = @('New'); $script:installedVersion['New'] = '2.0.0'; $script:latest['New'] = 'v1.9.0'
        $script:DevTools = @((New-ScriptTool 'New' @{ Repo = 'o/new'; VersionSource = 'command' }))
        Invoke-Install -Yes
        $script:downloads.Count -eq 0
    }
    Test-Case 'Update: when the latest version cannot be checked the tool is skipped with a warning' {
        Reset-Fake
        $script:installedNames = @('Off'); $script:installedVersion['Off'] = '1.0.0'
        $script:DevTools = @((New-ScriptTool 'Off' @{ Repo = 'o/off'; VersionSource = 'command' }))
        Invoke-Install -Yes
        $script:downloads.Count -eq 0 -and $script:log.Contains('WARNING: Off: latest version could not be checked; skipping update.')
    }
    Test-Case 'Update: an installed tool whose version is unknown (null) is updated' {
        Reset-Fake
        $script:installedNames = @('Unk'); $script:latest['Unk'] = 'v1.0.0'
        $script:DevTools = @((New-ScriptTool 'Unk' @{ Repo = 'o/unk'; VersionSource = 'command' }))
        Invoke-Install -Yes
        $script:downloads.Count -eq 1
    }
    Test-Case 'Update: RemoteFiles tool with stale files is updated' {
        Reset-Fake
        $script:installedNames = @('Rf'); $script:remoteUpToDate['Rf'] = $false
        $script:DevTools = @((New-ScriptTool 'Rf' @{ RemoteFiles = @('a/x.ps1') }))
        Invoke-Install -Yes
        $script:downloads.Count -eq 1 -and (Get-Row 'Rf').Action -ceq 'Updating'
    }
    Test-Case 'Update: RemoteFiles tool whose files are current is skipped' {
        Reset-Fake
        $script:installedNames = @('Rf'); $script:remoteUpToDate['Rf'] = $true
        $script:DevTools = @((New-ScriptTool 'Rf' @{ RemoteFiles = @('a/x.ps1') }))
        Invoke-Install -Yes
        $script:downloads.Count -eq 0
    }
    Test-Case 'Update: RemoteFiles tool whose files cannot be checked is skipped with a warning' {
        Reset-Fake
        $script:installedNames = @('Rf'); $script:remoteUpToDate['Rf'] = $null
        $script:DevTools = @((New-ScriptTool 'Rf' @{ RemoteFiles = @('a/x.ps1') }))
        Invoke-Install -Yes
        $script:downloads.Count -eq 0 -and $script:log.Contains('WARNING: Rf: remote files could not be checked; skipping update.')
    }
    Test-Case 'Update: Windows-Operation-Cli is not updated while its process is running' {
        Reset-Fake
        Set-Present 'claude'
        $script:running = @('windows-operation-cli')
        $script:installedNames = @('Windows-Operation-Cli'); $script:installedVersion['Windows-Operation-Cli'] = '1.0.0'
        $script:latest['Windows-Operation-Cli'] = 'v2.0.0'
        $script:DevTools = @((New-ScriptTool 'Windows-Operation-Cli' @{ Args = @{ FromRelease = $true }; RequiredCommand = 'claude'; Repo = 'o/woc' }))
        Invoke-Install -Yes
        $script:downloads.Count -eq 0 -and $script:log.Contains('WARNING: Windows-Operation-Cli is running; close it before updating.')
    }
    Test-Case 'Update: Windows-Operation-Cli is updated, with the new tag, when its process is not running' {
        Reset-Fake
        Set-Present 'claude'
        $path = Join-Path $script:work 'bin\woc.exe'
        $script:installerSpec['https://fake/Windows-Operation-Cli.ps1'] = @{ CreateFile = $path }
        $script:installedNames = @('Windows-Operation-Cli'); $script:installedVersion['Windows-Operation-Cli'] = '1.0.0'
        $script:latest['Windows-Operation-Cli'] = 'v2.0.0'
        $script:DevTools = @((New-ScriptTool 'Windows-Operation-Cli' @{ Args = @{ FromRelease = $true }; RequiredCommand = 'claude'; Repo = 'o/woc'; Path = $path }))
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        Invoke-Install -Yes
        ($script:installerCalls -join '|') -ceq 'https://fake/Windows-Operation-Cli.ps1|FromRelease=True,Version=v2.0.0' -and
        $script:latestCalls.Count -eq 1
    }
    Test-Case 'Update: a Repo tool is not version-checked when it is missing (it is simply installed)' {
        Reset-Fake
        $path = Join-Path $script:work 'bin\Mk.exe'
        $script:installerSpec['https://fake/Mk.ps1'] = @{ CreateFile = $path }
        $script:installedVersion['Mk'] = '9.9.9'; $script:latest['Mk'] = 'v1.0.0'
        $script:DevTools = @((New-ScriptTool 'Mk' @{ Repo = 'o/mk'; VersionSource = 'command'; Path = $path }))
        Invoke-Install -Yes
        $script:downloads.Count -eq 1 -and (Get-Row 'Mk').Action -ceq 'Installing'
    }
    Test-Case 'Update: only script backends are version-checked; installed winget tools never trigger a latest lookup' {
        Reset-Fake
        $script:installedNames = @('A')
        $script:DevTools = @((New-Tool 'A' 'winget' @{ Repo = 'o/a' }))
        Invoke-Install -Yes
        $script:latestCalls.Count -eq 0 -and $script:wingetCalls.Count -eq 0
    }

    # ======================================================================================
    # remote-config
    # ======================================================================================
    $cfg = { param($n, $ext) New-Tool $n 'remote-config' @{ RepoPath = "cfg/$n$ext"; Dest = (Join-Path $script:work "dest\$n$ext") } }
    $writeDest = { param($t, $text) New-Item -ItemType Directory -Path (Split-Path -Parent $t.Dest) -Force | Out-Null; [IO.File]::WriteAllText($t.Dest, $text) }
    $backups = { param($t) @(Get-ChildItem -LiteralPath (Split-Path -Parent $t.Dest) -Filter '*.backup.*' -ErrorAction Ignore) }

    Test-Case 'remote-config: a missing Dest is created (with its folder) from the fetched content, no prompt, diff or backup' {
        Reset-Fake
        $t = & $cfg 'c1' '.toml'
        $script:DevTools = @($t)
        $script:remoteContent[$t.RepoPath] = "a = 1`nb = 2"
        Invoke-Install -Yes
        [IO.File]::ReadAllText($t.Dest) -ceq "a = 1`nb = 2" -and $script:prompts.Count -eq 0 -and
        $script:diffs.Count -eq 0 -and (& $backups $t).Count -eq 0 -and (Get-Row 'c1').Result -ceq 'OK'
    }
    Test-Case 'remote-config: content is written without a trailing newline' {
        Reset-Fake
        $t = & $cfg 'c1' '.toml'
        $script:DevTools = @($t)
        $script:remoteContent[$t.RepoPath] = 'x = 1'
        Invoke-Install -Yes
        [IO.File]::ReadAllText($t.Dest) -ceq 'x = 1'
    }
    Test-Case 'remote-config: existing Dest with -Yes is overwritten without a prompt, after showing the diff' {
        Reset-Fake
        $t = & $cfg 'c1' '.toml'
        $script:DevTools = @($t)
        & $writeDest $t 'old = 1'
        $script:remoteContent[$t.RepoPath] = 'new = 2'
        Invoke-Install -Yes
        [IO.File]::ReadAllText($t.Dest) -ceq 'new = 2' -and $script:prompts.Count -eq 0 -and
        $script:diffs.Count -eq 1 -and $script:diffs[0].Remote -ceq 'new = 2' -and $script:log.Contains('DIFFLINE for c1')
    }
    Test-Case 'remote-config: overwrite keeps a timestamped backup of the previous content' {
        Reset-Fake
        $t = & $cfg 'c1' '.toml'
        $script:DevTools = @($t)
        & $writeDest $t 'old = 1'
        $script:remoteContent[$t.RepoPath] = 'new = 2'
        Invoke-Install -Yes
        $b = & $backups $t
        $b.Count -eq 1 -and $b[0].Name -cmatch '^c1\.toml\.backup\.\d{8}-\d{6}$' -and [IO.File]::ReadAllText($b[0].FullName) -ceq 'old = 1' -and
        $script:log.Contains($b[0].FullName)
    }
    Test-Case 'remote-config: interactive "y" overwrites; the prompt names the Dest and comes after the diff' {
        Reset-Fake
        $t = & $cfg 'c1' '.toml'
        $script:DevTools = @($t)
        & $writeDest $t 'old = 1'
        $script:remoteContent[$t.RepoPath] = 'new = 2'
        Set-Answers 'y', 'y'
        Invoke-Install
        $overwritePrompt = $script:prompts[1]
        $e = @($script:events)
        [IO.File]::ReadAllText($t.Dest) -ceq 'new = 2' -and $script:prompts.Count -eq 2 -and
        $overwritePrompt.Contains($t.Dest) -and $e.IndexOf('diff: c1') -ge 0 -and $e.IndexOf('diff: c1') -lt $e.IndexOf("prompt: $overwritePrompt")
    }
    Test-Case 'remote-config: interactive "n" keeps the existing file, makes no backup, and does not fail the tool' {
        Reset-Fake
        $t = & $cfg 'c1' '.toml'
        $script:DevTools = @($t)
        & $writeDest $t 'old = 1'
        $script:remoteContent[$t.RepoPath] = 'new = 2'
        Set-Answers 'y', 'n'
        Invoke-Install
        [IO.File]::ReadAllText($t.Dest) -ceq 'old = 1' -and (& $backups $t).Count -eq 0 -and (Get-Row 'c1').Result -ceq 'OK'
    }
    Test-Case 'remote-config: an overwrite answer other than y/yes is treated as no' {
        Reset-Fake
        $t = & $cfg 'c1' '.toml'
        $script:DevTools = @($t)
        & $writeDest $t 'old = 1'
        $script:remoteContent[$t.RepoPath] = 'new = 2'
        Set-Answers 'y', ''
        Invoke-Install
        [IO.File]::ReadAllText($t.Dest) -ceq 'old = 1'
    }
    Test-Case 'remote-config: -Force skips the Proceed prompt but still asks before overwriting (answer n keeps the file)' {
        Reset-Fake
        $t = & $cfg 'c1' '.toml'
        $script:DevTools = @($t)
        & $writeDest $t 'old = 1'
        $script:remoteContent[$t.RepoPath] = 'new = 2'
        Set-Answers 'n'
        Invoke-Install -Force
        $script:prompts.Count -eq 1 -and $script:prompts[0].Contains($t.Dest) -and [IO.File]::ReadAllText($t.Dest) -ceq 'old = 1' -and
        (& $backups $t).Count -eq 0
    }
    Test-Case 'remote-config: -Force with answer y overwrites after the single overwrite prompt' {
        Reset-Fake
        $t = & $cfg 'c1' '.toml'
        $script:DevTools = @($t)
        & $writeDest $t 'old = 1'
        $script:remoteContent[$t.RepoPath] = 'new = 2'
        Set-Answers 'y'
        Invoke-Install -Force
        $script:prompts.Count -eq 1 -and [IO.File]::ReadAllText($t.Dest) -ceq 'new = 2' -and (& $backups $t).Count -eq 1
    }
    Test-Case 'remote-config: declining one file does not stop the next config from being written' {
        Reset-Fake
        $t1 = & $cfg 'c1' '.toml'; $t2 = & $cfg 'c2' '.toml'
        $script:DevTools = @($t1, $t2)
        & $writeDest $t1 'old = 1'
        $script:remoteContent[$t1.RepoPath] = 'new = 1'; $script:remoteContent[$t2.RepoPath] = 'new = 2'
        Set-Answers 'y', 'n'
        Invoke-Install
        [IO.File]::ReadAllText($t1.Dest) -ceq 'old = 1' -and [IO.File]::ReadAllText($t2.Dest) -ceq 'new = 2'
    }
    Test-Case 'remote-config: invalid JSON for a .json Dest is FAILED, the existing file is untouched, no prompt or backup' {
        Reset-Fake
        $t = & $cfg 'c1' '.json'
        $script:DevTools = @($t)
        & $writeDest $t '{"live": true}'
        $script:remoteContent[$t.RepoPath] = '{"broken": '
        Invoke-Install -Yes
        (Get-Row 'c1').Result -ceq 'FAILED' -and [IO.File]::ReadAllText($t.Dest) -ceq '{"live": true}' -and
        $script:prompts.Count -eq 0 -and $script:diffs.Count -eq 0 -and (& $backups $t).Count -eq 0 -and
        $script:log.Contains('c1.json') -and $script:log.Contains('Failed:')
    }
    Test-Case 'remote-config: invalid JSON does not create a missing .json Dest' {
        Reset-Fake
        $t = & $cfg 'c1' '.json'
        $script:DevTools = @($t)
        $script:remoteContent[$t.RepoPath] = 'not json'
        Invoke-Install -Yes
        (Get-Row 'c1').Result -ceq 'FAILED' -and -not (Test-Path -LiteralPath $t.Dest)
    }
    Test-Case 'remote-config: valid JSON for a .json Dest is written' {
        Reset-Fake
        $t = & $cfg 'c1' '.json'
        $script:DevTools = @($t)
        $script:remoteContent[$t.RepoPath] = '{"ok": 1}'
        Invoke-Install -Yes
        [IO.File]::ReadAllText($t.Dest) -ceq '{"ok": 1}' -and (Get-Row 'c1').Result -ceq 'OK'
    }
    Test-Case 'remote-config: a non-JSON Dest is not JSON-validated' {
        Reset-Fake
        $t = & $cfg 'c1' '.toml'
        $script:DevTools = @($t)
        $script:remoteContent[$t.RepoPath] = '{"broken": '
        Invoke-Install -Yes
        (Get-Row 'c1').Result -ceq 'OK' -and [IO.File]::ReadAllText($t.Dest) -ceq '{"broken": '
    }
    Test-Case 'remote-config: a fetch failure is FAILED, leaves the Dest alone, and the next config still installs' {
        Reset-Fake
        $t1 = & $cfg 'c1' '.toml'; $t2 = & $cfg 'c2' '.toml'
        $script:DevTools = @($t1, $t2)
        & $writeDest $t1 'old = 1'
        $script:remoteContent[$t2.RepoPath] = 'new = 2'
        Invoke-Install -Yes
        (Get-Row 'c1').Result -ceq 'FAILED' -and [IO.File]::ReadAllText($t1.Dest) -ceq 'old = 1' -and
        (Get-Row 'c2').Result -ceq 'OK' -and $script:log.Contains('fetch failed: cfg/c1.toml')
    }
    Test-Case 'remote-config: a config that is already up to date is not touched' {
        Reset-Fake
        $t = & $cfg 'c1' '.toml'
        $script:DevTools = @($t)
        & $writeDest $t 'same'
        $script:installedNames = @('c1')
        Invoke-Install -Yes
        $script:diffs.Count -eq 0 -and (& $backups $t).Count -eq 0 -and $script:log.Contains('All dev tools already installed.')
    }

    # ======================================================================================
    # Post-install hook: delta
    # ======================================================================================
    $delta = { New-Tool 'delta' 'winget' @{ PostInstall = 'delta' } }

    Test-Case 'delta post-install: answering y configures git pager, diffFilter and navigate' {
        Reset-Fake
        $script:DevTools = @((& $delta))
        Set-Answers 'y', 'y'
        Invoke-Install
        $script:prompts[1] -ceq 'Configure git to use delta as pager? (y/N)' -and
        ($script:gitCalls -join '|') -ceq 'git config --global core.pager delta|git config --global interactive.diffFilter delta --color-only|git config --global delta.navigate true'
    }
    Test-Case 'delta post-install: answering n leaves git untouched' {
        Reset-Fake
        $script:DevTools = @((& $delta))
        Set-Answers 'y', 'n'
        Invoke-Install
        $script:prompts.Count -eq 2 -and $script:gitCalls.Count -eq 0 -and (Get-Row 'delta').Result -ceq 'OK'
    }
    Test-Case 'delta post-install: -Force configures git without asking' {
        Reset-Fake
        $script:DevTools = @((& $delta))
        Invoke-Install -Force
        $script:prompts.Count -eq 0 -and $script:gitCalls.Count -eq 3
    }
    Test-Case 'delta post-install: is not offered when the delta install failed' {
        Reset-Fake
        $script:failIds['id.delta'] = 1
        $script:DevTools = @((& $delta))
        Set-Answers 'y'
        Invoke-Install
        $script:prompts.Count -eq 1 -and $script:gitCalls.Count -eq 0 -and (Get-Row 'delta').Result -ceq 'FAILED'
    }
    Test-Case 'delta post-install: is not offered when delta is already installed' {
        Reset-Fake
        $script:DevTools = @((& $delta))
        $script:installedNames = @('delta')
        Invoke-Install
        $script:prompts.Count -eq 0 -and $script:gitCalls.Count -eq 0
    }
    Test-Case 'delta post-install: runs right after delta, before the next tool installs' {
        Reset-Fake
        $script:DevTools = @((& $delta), (New-Tool 'After' 'winget'))
        Invoke-Install -Yes
        $e = @($script:events)
        $e.IndexOf('git config --global core.pager delta') -gt $e.IndexOf('winget install --id id.delta --exact --source winget --accept-package-agreements --accept-source-agreements') -and
        $e.IndexOf('git config --global delta.navigate true') -lt $e.IndexOf('winget install --id id.After --exact --source winget --accept-package-agreements --accept-source-agreements')
    }
    Test-Case 'delta post-install: tools without PostInstall never touch git' {
        Reset-Fake
        $script:DevTools = @((New-Tool 'A' 'winget'), (New-Tool 'B' 'psmodule' @{ Id = 'B' }))
        Invoke-Install -Yes
        $script:gitCalls.Count -eq 0
    }

    # ======================================================================================
    # Update-DevTools
    # ======================================================================================
    Test-Case 'Update-DevTools runs a single "winget upgrade --all" accepting both agreements' {
        Reset-Fake
        $script:DevTools = @((New-Tool 'A' 'winget'))
        $null = Update-DevTools *>&1
        $script:wingetCalls.Count -eq 1 -and
        $script:wingetCalls[0] -ceq 'winget upgrade --all --accept-package-agreements --accept-source-agreements'
    }
    Test-Case 'Update-DevTools updates only the psmodule tools that are installed' {
        Reset-Fake
        $script:DevTools = @(
            (New-Tool 'Have' 'psmodule' @{ Id = 'HaveMod' }),
            (New-Tool 'Missing' 'psmodule' @{ Id = 'MissingMod' }),
            (New-Tool 'W' 'winget' @{ Id = 'WingetThing' }))
        $script:modules = @('HaveMod', 'WingetThing', 'Unrelated')
        $null = Update-DevTools *>&1
        ($script:moduleUpdates -join ',') -ceq 'HaveMod'
    }
    Test-Case 'Update-DevTools does not install missing modules' {
        Reset-Fake
        $script:DevTools = @((New-Tool 'Missing' 'psmodule' @{ Id = 'MissingMod' }))
        $null = Update-DevTools *>&1
        $script:moduleInstalls.Count -eq 0 -and $script:moduleUpdates.Count -eq 0
    }
    Test-Case 'Update-DevTools: one module failing to update does not stop the others' {
        Reset-Fake
        $script:failIds['ModA'] = 1
        $script:DevTools = @((New-Tool 'A' 'psmodule' @{ Id = 'ModA' }), (New-Tool 'B' 'psmodule' @{ Id = 'ModB' }))
        $script:modules = @('ModA', 'ModB')
        $null = Update-DevTools *>&1
        ($script:moduleUpdates -join ',') -ceq 'ModA,ModB'
    }
    Test-Case 'Update-DevTools without psmodule tools still upgrades winget and updates no module' {
        Reset-Fake
        $script:DevTools = @((New-Tool 'A' 'winget'), (New-Tool 'P' 'pip'))
        $script:modules = @('ModA')
        $null = Update-DevTools *>&1
        $script:wingetCalls.Count -eq 1 -and $script:moduleUpdates.Count -eq 0
    }
    Test-Case 'Update-DevTools upgrades winget before updating modules' {
        Reset-Fake
        $script:DevTools = @((New-Tool 'A' 'psmodule' @{ Id = 'ModA' }))
        $script:modules = @('ModA')
        $null = Update-DevTools *>&1
        $e = @($script:events)
        $e.Count -eq 2 -and $e[0].StartsWith('winget upgrade') -and $e[1] -ceq 'Update-Module ModA'
    }
}
finally {
    $env:PATH = $originalPath
    $env:TEMP = $originalTemp
    $env:LOCALAPPDATA = $originalLocalAppData
    if ($originalCatalog) { $script:DevTools = $originalCatalog }
    Remove-Variable -Name InstallerHarness -Scope Global -ErrorAction Ignore
    if ($global:_dotfilesProfileIdleSubscriptionId) {
        Unregister-Event -SubscriptionId $global:_dotfilesProfileIdleSubscriptionId -ErrorAction Ignore
    }
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction Ignore
}

Complete-Tests
