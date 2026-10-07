# Run with: pwsh -NoProfile -File app-settings/pwsh/tests/Test-Integrations.ps1
# Covers profile.d/integrations.ps1, psreadline.ps1 and help.ps1. External tools are faked
# with functions defined after the profile loads; nothing real (starship, zoxide, fzf, ...) runs.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$originalPath = $env:PATH
$originalAppData = $env:APPDATA
$originalTerm = $env:TERM
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('dotfiles-integrations-test-' + [guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'TestHarness.ps1')

$integrationsPath = Join-Path $root 'profile.d\integrations.ps1'
$psreadlinePath = Join-Path $root 'profile.d\psreadline.ps1'

function Get-ScriptAst {
    param([string]$Path)
    $tokens = $null; $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
}

# The -Action script block of the PowerShell.OnIdle subscription in integrations.ps1.
function Get-IdleAction {
    $ast = Get-ScriptAst $integrationsPath
    $cmd = $ast.Find({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Register-EngineEvent'
        }, $true)
    $elements = @($cmd.CommandElements)
    for ($i = 0; $i -lt $elements.Count; $i++) {
        if ($elements[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $elements[$i].ParameterName -eq 'Action') {
            return $elements[$i + 1].ScriptBlock.GetScriptBlock()
        }
    }
}

# The body of psreadline.ps1's `if ($host.Name -eq 'ConsoleHost' ...)` guard, as a script block.
# Running it directly exercises the registration logic without depending on the host.
function Get-PSReadLineBody {
    $ast = Get-ScriptAst $psreadlinePath
    $guard = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $false)
    $text = $guard.Clauses[0].Item2.Extent.Text
    [scriptblock]::Create($text.Substring(1, $text.Length - 2))
}

# One row per command name documented in $script:ProfileHelp, split like Invoke-CommandPalette does.
function Get-CatalogNames {
    foreach ($section in $script:ProfileHelp.Keys) {
        foreach ($item in $script:ProfileHelp[$section]) {
            $names = ($item.Cmd -split '[,/](?![^\[<]*[\]>])') | ForEach-Object { ($_ -replace '[\[<].*', '').Trim() } | Where-Object { $_ }
            foreach ($name in $names) {
                [pscustomobject]@{ Section = $section; Item = $item; Name = ($name -split '\s+')[0] }
            }
        }
    }
}

# Show-ProfileHelp output split into section headers and command rows (Write-Host -> information stream).
function Get-HelpView {
    param([string]$Filter)
    $records = @(Show-ProfileHelp -Filter $Filter 6>&1 | ForEach-Object { "$_" })
    $sections = @(); $items = @(); $current = $null
    foreach ($r in $records) {
        if ($r -match '^\[(.+)\]$') { $current = $Matches[1]; $sections += $current }
        elseif ($r -match '^  \S') { $items += [pscustomobject]@{ Section = $current; Cmd = $r.Trim() } }
    }
    [pscustomobject]@{ Records = $records; Sections = $sections; Items = $items }
}

try {
    New-Item -ItemType Directory -Path $scratch | Out-Null
    $env:PATH = ''
    . (Join-Path $root 'Microsoft.PowerShell_profile.ps1')

    # --- Fakes (defined after load, so they shadow the profile's helpers and real commands) -----
    function Reset-Fake {
        $script:calls = [System.Collections.Generic.List[string]]::new()
        $script:initRequests = @(); $script:initLoaded = @(); $script:initThrow = @()
        $script:imports = @(); $script:importThrow = @(); $script:modulesAvailable = @()
        $script:psfzfOptions = @(); $script:keyHandlers = @(); $script:options = @()
        $global:_dotfilesProfileDeferredDone = $false
        $script:_cmdCache['fzf'] = $false
    }
    function Get-InitCache {
        param([string]$Name, [string]$Exe, [scriptblock]$Generator)
        $script:initRequests += [pscustomobject]@{ Name = $Name; Exe = $Exe; Generator = $Generator.ToString().Trim() }
        if ($script:initThrow -contains $Name) { throw "init failed: $Name" }
        $file = Join-Path $scratch "$Name.init.ps1"
        Set-Content -LiteralPath $file -Value "`$script:initLoaded += '$Name'"
        $file
    }
    function Get-Module {
        param([switch]$ListAvailable, [string]$Name)
        if ($script:modulesAvailable -contains $Name) { [pscustomobject]@{ Name = $Name } }
    }
    function Import-Module {
        param([string]$Name)
        $script:calls.Add("Import-Module $Name")
        if ($script:importThrow -contains $Name) { throw "import failed: $Name" }
        $script:imports += $Name
    }
    function Set-PsFzfOption {
        param($PSReadlineChordProvider, $PSReadlineChordSetLocation)
        $script:calls.Add('Set-PsFzfOption')
        $script:psfzfOptions += [pscustomobject]@{ Provider = $PSReadlineChordProvider; SetLocation = $PSReadlineChordSetLocation }
    }
    function Set-PSReadLineKeyHandler {
        param([string[]]$Key, $Function, [scriptblock]$ScriptBlock, $BriefDescription)
        $script:calls.Add("Set-PSReadLineKeyHandler $($Key -join ',')")
        $script:keyHandlers += [pscustomobject]@{ Key = $Key; Function = $Function; ScriptBlock = $ScriptBlock; Brief = $BriefDescription }
    }
    function Set-PSReadLineOption {
        param($PredictionSource, $PredictionViewStyle, $EditMode, [switch]$HistorySearchCursorMovesToEnd, [switch]$HistoryNoDuplicates, $MaximumHistoryCount)
        $bound = @{}
        foreach ($k in $PSBoundParameters.Keys) { $bound[$k] = $PSBoundParameters[$k] }
        $script:options += $bound
    }
    function Get-PsrlHandler { param([string]$Key) @($script:keyHandlers | Where-Object { $_.Key -contains $Key }) }
    function Get-WarningText { param($Stream) @($Stream | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message }) }

    # fzf fake: records stdin and arguments, answers from a queue of canned outputs.
    function fzf {
        $script:fzfInputs += , @($input)
        $script:fzfArgs = @($args)
        if ($script:fzfQueue.Count -gt 0) { $script:fzfQueue.Dequeue() }
    }
    function Reset-Fzf {
        $script:fzfInputs = @(); $script:fzfArgs = @()
        $script:fzfQueue = [System.Collections.Generic.Queue[object]]::new()
    }

    Reset-Fake
    Reset-Fzf

    # ======================= integrations.ps1: starship (synchronous, guarded) ===================
    Test-Case 'Starship init is not requested when starship is absent' {
        Reset-Fake
        $script:_cmdCache['starship'] = $false
        . $integrationsPath
        $script:initRequests.Count -eq 0 -and $script:initLoaded.Count -eq 0
    }
    Test-Case 'Starship init is requested from Get-InitCache with Name/Exe starship when present' {
        Reset-Fake
        $script:_cmdCache['starship'] = $true
        . $integrationsPath
        $script:_cmdCache['starship'] = $false
        $req = @($script:initRequests | Where-Object { $_.Name -eq 'starship' })
        $req.Count -eq 1 -and $req[0].Exe -eq 'starship'
    }
    Test-Case 'Starship generator uses --print-full-init so the cache holds the full script' {
        Reset-Fake
        $script:_cmdCache['starship'] = $true
        . $integrationsPath
        $script:_cmdCache['starship'] = $false
        $script:initRequests[0].Generator -eq 'starship init powershell --print-full-init'
    }
    Test-Case 'Starship init file returned by Get-InitCache is dot-sourced' {
        Reset-Fake
        $script:_cmdCache['starship'] = $true
        . $integrationsPath
        $script:_cmdCache['starship'] = $false
        $script:initLoaded -contains 'starship'
    }
    Test-Case 'TERM=dumb is removed before starship init when starship is present' {
        Reset-Fake
        $script:_cmdCache['starship'] = $true
        $env:TERM = 'dumb'
        try { . $integrationsPath; $removed = -not (Test-Path Env:TERM) }
        finally { $script:_cmdCache['starship'] = $false; if ($null -eq $originalTerm) { Remove-Item Env:TERM -ErrorAction Ignore } else { $env:TERM = $originalTerm } }
        $removed
    }
    Test-Case 'A non-dumb TERM is preserved when starship is present' {
        Reset-Fake
        $script:_cmdCache['starship'] = $true
        $env:TERM = 'xterm-256color'
        try { . $integrationsPath; $kept = $env:TERM -eq 'xterm-256color' }
        finally { $script:_cmdCache['starship'] = $false; if ($null -eq $originalTerm) { Remove-Item Env:TERM -ErrorAction Ignore } else { $env:TERM = $originalTerm } }
        $kept
    }
    Test-Case 'TERM=dumb is left alone when starship is absent' {
        Reset-Fake
        $script:_cmdCache['starship'] = $false
        $env:TERM = 'dumb'
        try { . $integrationsPath; $kept = $env:TERM -eq 'dumb' }
        finally { if ($null -eq $originalTerm) { Remove-Item Env:TERM -ErrorAction Ignore } else { $env:TERM = $originalTerm } }
        $kept
    }

    # ======================= integrations.ps1: OnIdle subscription ===============================
    Test-Case 'Profile tracks a single PowerShell.OnIdle subscription by its global id' {
        $sub = @(Get-EventSubscriber -SubscriptionId $global:_dotfilesProfileIdleSubscriptionId -ErrorAction Ignore)
        $sub.Count -eq 1 -and $sub[0].SourceIdentifier -eq 'PowerShell.OnIdle'
    }
    Test-Case 'Re-sourcing integrations replaces the OnIdle subscription instead of leaking one' {
        $before = @(Get-EventSubscriber -SourceIdentifier PowerShell.OnIdle).Count
        $oldId = $global:_dotfilesProfileIdleSubscriptionId
        . $integrationsPath
        $after = @(Get-EventSubscriber -SourceIdentifier PowerShell.OnIdle).Count
        $before -eq $after -and $global:_dotfilesProfileIdleSubscriptionId -ne $oldId -and
        $null -eq (Get-EventSubscriber -SubscriptionId $oldId -ErrorAction Ignore)
    }
    Test-Case 'Sourcing integrations resets the deferred-done flag so deferred init runs again' {
        $global:_dotfilesProfileDeferredDone = $true
        . $integrationsPath
        $global:_dotfilesProfileDeferredDone -eq $false
    }

    # ======================= integrations.ps1: deferred (OnIdle) action ==========================
    $idleAction = Get-IdleAction

    Test-Case 'Idle action was found in integrations.ps1' {
        $idleAction -is [scriptblock]
    }
    Test-Case 'Deferred init does nothing but mark itself done when no tools or modules are present' {
        Reset-Fake
        & $idleAction
        $script:initRequests.Count -eq 0 -and $script:imports.Count -eq 0 -and
        $script:keyHandlers.Count -eq 0 -and $global:_dotfilesProfileDeferredDone -eq $true
    }
    Test-Case 'Deferred init requests the zoxide init cache with Name/Exe zoxide when zoxide exists' {
        Reset-Fake
        function zoxide { }
        & $idleAction
        $req = @($script:initRequests | Where-Object { $_.Name -eq 'zoxide' })
        $req.Count -eq 1 -and $req[0].Exe -eq 'zoxide' -and $req[0].Generator -eq 'zoxide init --hook pwd powershell'
    }
    Test-Case 'Deferred init dot-sources the zoxide init file' {
        Reset-Fake
        function zoxide { }
        & $idleAction
        $script:initLoaded -contains 'zoxide'
    }
    Test-Case 'Deferred init requests the gh completion cache with Name/Exe gh when gh exists' {
        Reset-Fake
        function gh { }
        & $idleAction
        $req = @($script:initRequests | Where-Object { $_.Name -eq 'gh' })
        $req.Count -eq 1 -and $req[0].Exe -eq 'gh' -and $req[0].Generator -eq 'gh completion -s powershell' -and
        $script:initLoaded -contains 'gh'
    }
    Test-Case 'Deferred init does not request zoxide or gh caches when those commands are absent' {
        Reset-Fake
        & $idleAction
        @($script:initRequests | Where-Object { $_.Name -in 'zoxide', 'gh' }).Count -eq 0
    }
    Test-Case 'Deferred init runs only once per session' {
        Reset-Fake
        function zoxide { }
        & $idleAction
        & $idleAction
        @($script:initRequests | Where-Object { $_.Name -eq 'zoxide' }).Count -eq 1
    }
    Test-Case 'A failing zoxide init is swallowed and gh completion is still set up' {
        Reset-Fake
        function zoxide { }
        function gh { }
        $script:initThrow = @('zoxide')
        & $idleAction
        $script:initLoaded -notcontains 'zoxide' -and $script:initLoaded -contains 'gh'
    }
    Test-Case 'PSFzf is imported and its chords are set to Ctrl+t / Alt+c when the module is available' {
        Reset-Fake
        $script:modulesAvailable = @('PSFzf')
        & $idleAction
        $script:imports -contains 'PSFzf' -and $script:psfzfOptions.Count -eq 1 -and
        $script:psfzfOptions[0].Provider -eq 'Ctrl+t' -and $script:psfzfOptions[0].SetLocation -eq 'Alt+c'
    }
    Test-Case 'Ctrl+r is re-asserted after PSFzf is configured when fzf exists' {
        Reset-Fake
        $script:modulesAvailable = @('PSFzf')
        function fzf { }
        & $idleAction
        $order = @($script:calls)
        $h = @(Get-PsrlHandler 'Ctrl+r')
        $h.Count -eq 1 -and $null -ne $h[0].ScriptBlock -and
        $order.IndexOf('Import-Module PSFzf') -lt $order.IndexOf('Set-PsFzfOption') -and
        $order.IndexOf('Set-PsFzfOption') -lt $order.IndexOf('Set-PSReadLineKeyHandler Ctrl+r')
    }
    Test-Case 'The re-asserted Ctrl+r handler runs the fzf history search' {
        Reset-Fake
        $script:modulesAvailable = @('PSFzf')
        function fzf { }
        & $idleAction
        # fzf "exists" for Get-Command above, but Test-Cmd (cache) says no -> Invoke-FzfHistory warns.
        $script:_cmdCache['fzf'] = $false
        $warnings = Get-WarningText (& (Get-PsrlHandler 'Ctrl+r')[0].ScriptBlock 3>&1)
        $warnings -contains 'History search needs fzf'
    }
    Test-Case 'Ctrl+r is not re-bound when PSFzf is available but fzf is absent' {
        Reset-Fake
        $script:modulesAvailable = @('PSFzf')
        # The suite-wide fzf fake would make Get-Command find fzf; hide it for this case.
        function Get-Command { [CmdletBinding()] param($Name) }
        & $idleAction
        $script:imports -contains 'PSFzf' -and $script:keyHandlers.Count -eq 0
    }
    Test-Case 'A PSFzf import failure is swallowed and Terminal-Icons still loads' {
        Reset-Fake
        $script:modulesAvailable = @('PSFzf', 'Terminal-Icons')
        $script:importThrow = @('PSFzf')
        & $idleAction
        $script:psfzfOptions.Count -eq 0 -and $script:imports -contains 'Terminal-Icons'
    }
    Test-Case 'Terminal-Icons is imported when available and skipped when absent' {
        Reset-Fake
        $script:modulesAvailable = @('Terminal-Icons')
        & $idleAction
        $present = $script:imports -contains 'Terminal-Icons' -and $script:imports -notcontains 'PSFzf'
        Reset-Fake
        & $idleAction
        $present -and $script:imports.Count -eq 0
    }

    # ======================= integrations.ps1: wrapper functions =================================
    $catFile = Join-Path $scratch 'cat.txt'
    Set-Content -LiteralPath $catFile -Value @('first line', 'second line')

    Test-Case 'cat falls back to Get-Content when bat is absent' {
        $script:_cmdCache['bat'] = $false
        $out = @(cat $catFile)
        $out.Count -eq 2 -and $out[0] -ceq 'first line' -and $out[1] -ceq 'second line'
    }
    Test-Case 'sudo forwards all arguments to gsudo when gsudo exists' {
        function gsudo { $script:gsudoArgs = @($args) }
        $script:_cmdCache['gsudo'] = $true
        sudo whoami /all
        ($script:gsudoArgs -join '|') -eq 'whoami|/all'
    }
    Test-Case 'sudo warns and does not run anything when gsudo is absent' {
        $script:gsudoArgs = $null
        function gsudo { $script:gsudoArgs = @($args) }
        $script:_cmdCache['gsudo'] = $false
        $warnings = Get-WarningText (sudo whoami 3>&1)
        $warnings -contains 'sudo needs gsudo' -and $null -eq $script:gsudoArgs
    }
    Test-Case 'Update-SessionPath is an alias of refreshenv' {
        (Get-Alias Update-SessionPath).Definition -eq 'refreshenv' -and (Get-Command refreshenv).CommandType -eq 'Function'
    }

    $script:clipboard = @()
    function Set-Clipboard { param([Parameter(ValueFromPipeline)]$Value) process { $script:clipboard += $Value } }
    function Get-Clipboard { 'clipboard text' }

    Test-Case 'clip writes piped input to the clipboard' {
        $script:clipboard = @()
        'alpha', 'beta' | clip
        ($script:clipboard -join '|') -eq 'alpha|beta'
    }
    Test-Case 'paste returns the clipboard contents' {
        (paste) -ceq 'clipboard text'
    }

    function Invoke-RestMethod {
        param($Uri, $TimeoutSec)
        $script:restArgs = @{ Uri = $Uri; TimeoutSec = $TimeoutSec }
        [pscustomobject]@{ ip = '203.0.113.7' }
    }
    Test-Case 'myip returns the ip field from api.ipify.org with a 5 second timeout' {
        $ip = myip
        $ip -ceq '203.0.113.7' -and $script:restArgs.Uri -eq 'https://api.ipify.org?format=json' -and $script:restArgs.TimeoutSec -eq 5
    }

    $script:conns = @(); $script:procNames = @{}; $script:stoppedIds = @(); $script:stopForce = @()
    function Get-NetTCPConnection { [CmdletBinding()] param([int]$LocalPort) $script:netPort = $LocalPort; $script:conns }
    function Get-Process { [CmdletBinding()] param([int]$Id) if ($script:procNames.ContainsKey($Id)) { [pscustomobject]@{ ProcessName = $script:procNames[$Id] } } }
    function Stop-Process { [CmdletBinding()] param([int]$Id, [switch]$Force) $script:stoppedIds += $Id; $script:stopForce += $Force.IsPresent }

    Test-Case 'port reports address, port, state, owning pid and process name for the requested port' {
        $script:conns = @([pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = 8080; State = 'Listen'; OwningProcess = 4242 })
        $script:procNames = @{ 4242 = 'node' }
        $r = @(port 8080)
        $r.Count -eq 1 -and $script:netPort -eq 8080 -and
        (($r[0].PSObject.Properties.Name) -join ',') -eq 'LocalAddress,LocalPort,State,OwningProcess,Process' -and
        $r[0].LocalAddress -eq '0.0.0.0' -and $r[0].State -eq 'Listen' -and $r[0].OwningProcess -eq 4242 -and $r[0].Process -eq 'node'
    }
    Test-Case 'port leaves Process empty when the owning process cannot be resolved' {
        $script:conns = @([pscustomobject]@{ LocalAddress = '::'; LocalPort = 9; State = 'Listen'; OwningProcess = 1 })
        $script:procNames = @{}
        $r = @(port 9)
        $r.Count -eq 1 -and $null -eq $r[0].Process
    }
    Test-Case 'port prints nothing when no connection is listening' {
        $script:conns = @()
        @(port 8080).Count -eq 0
    }
    Test-Case 'port rejects a non-numeric port' {
        $threw = $false
        try { port 'abc' } catch { $threw = $true }
        $threw
    }
    Test-Case 'killport force-stops each distinct owning pid once and reports it' {
        $script:conns = @(
            [pscustomobject]@{ OwningProcess = 20 }, [pscustomobject]@{ OwningProcess = 10 }, [pscustomobject]@{ OwningProcess = 20 })
        $script:stoppedIds = @(); $script:stopForce = @()
        $messages = @(killport 3000 6>&1 | ForEach-Object { "$_" })
        ($script:stoppedIds -join ',') -eq '10,20' -and (@($script:stopForce | Where-Object { -not $_ }).Count -eq 0) -and
        ($messages -join '|') -eq 'Killed PID 10 on port 3000|Killed PID 20 on port 3000'
    }
    Test-Case 'killport warns and stops nothing when nothing listens on the port' {
        $script:conns = @()
        $script:stoppedIds = @()
        $warnings = Get-WarningText (killport 3000 3>&1 6>$null)
        $warnings -contains 'Nothing listening on port 3000' -and $script:stoppedIds.Count -eq 0
    }

    # ======================= integrations.ps1: native argument completers ========================
    function dotnet { $script:dotnetArgs = @($args); 'build'; 'bin' }
    function winget { $script:wingetArgs = @($args); 'install'; 'search' }

    Test-Case 'dotnet completer returns the candidates printed by `dotnet complete`' {
        $c = TabExpansion2 'dotnet bu' 9
        (($c.CompletionMatches | ForEach-Object CompletionText) -join ',') -eq 'build,bin' -and
        @($c.CompletionMatches | Where-Object { $_.ResultType -ne 'ParameterValue' }).Count -eq 0
    }
    Test-Case 'dotnet completer passes the cursor position and the command line to dotnet complete' {
        $null = TabExpansion2 'dotnet bu' 9
        ($script:dotnetArgs -join '|') -eq 'complete|--position|9|dotnet bu'
    }
    Test-Case 'winget completer returns the candidates printed by `winget complete`' {
        $c = TabExpansion2 'winget ins' 10
        (($c.CompletionMatches | ForEach-Object CompletionText) -join ',') -eq 'install,search'
    }
    Test-Case 'winget completer passes word, command line and position to winget complete' {
        $null = TabExpansion2 'winget ins' 10
        ($script:wingetArgs -join '|') -ceq 'complete|--word=ins|--commandline|winget ins|--position|10'
    }
    Test-Case 'winget completer doubles embedded double quotes in the word and command line' {
        $null = TabExpansion2 'winget search "a' 16
        $script:wingetArgs[1] -ceq '--word=""a""' -and $script:wingetArgs[3] -ceq 'winget search ""a'
    }

    # ======================= psreadline.ps1: guard and key/option registration ===================
    $psrlBody = Get-PSReadLineBody

    Test-Case 'psreadline.ps1 registers handlers only on an interactive ConsoleHost' {
        Reset-Fake
        . $psreadlinePath
        $interactive = $host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected
        ($script:keyHandlers.Count -gt 0) -eq $interactive -and ($script:options.Count -gt 0) -eq $interactive
    }
    Test-Case 'PSReadLine module is imported before any option is set' {
        Reset-Fake
        & $psrlBody
        $script:calls[0] -eq 'Import-Module PSReadLine' -and $script:options.Count -gt 0
    }
    Test-Case 'History prediction is enabled with a ListView' {
        Reset-Fake
        & $psrlBody
        $o = $script:options | Where-Object { $_.ContainsKey('PredictionSource') }
        $v = $script:options | Where-Object { $_.ContainsKey('PredictionViewStyle') }
        @($o).Count -eq 1 -and $o.PredictionSource -eq 'History' -and @($v).Count -eq 1 -and $v.PredictionViewStyle -eq 'ListView'
    }
    Test-Case 'Edit mode is Windows' {
        Reset-Fake
        & $psrlBody
        $m = @($script:options | Where-Object { $_.ContainsKey('EditMode') })
        $m.Count -eq 1 -and $m[0].EditMode -eq 'Windows'
    }
    Test-Case 'History options: cursor to end on search, no duplicates, 10000 entries' {
        Reset-Fake
        & $psrlBody
        $all = @{}
        foreach ($o in $script:options) { foreach ($k in $o.Keys) { $all[$k] = $o[$k] } }
        $all['HistorySearchCursorMovesToEnd'].IsPresent -and $all['HistoryNoDuplicates'].IsPresent -and $all['MaximumHistoryCount'] -eq 10000
    }
    Test-Case 'Simple keys are bound to the expected PSReadLine functions' {
        Reset-Fake
        & $psrlBody
        $expected = [ordered]@{
            'UpArrow' = 'HistorySearchBackward'; 'DownArrow' = 'HistorySearchForward'; 'Ctrl+d' = 'DeleteCharOrExit'
            'Tab'     = 'MenuComplete'; 'Alt+a' = 'SelectCommandArgument'
        }
        $bad = foreach ($k in $expected.Keys) {
            $h = @(Get-PsrlHandler $k)
            if ($h.Count -ne 1 -or $h[0].Function -ne $expected[$k]) { $k }
        }
        if ($bad) { throw "Wrong binding: $($bad -join ', ')" }
        $true
    }
    Test-Case 'Opening brackets ( { [ share one InsertPairedBraces script handler' {
        Reset-Fake
        & $psrlBody
        $h = @($script:keyHandlers | Where-Object { $_.Brief -eq 'InsertPairedBraces' })
        $h.Count -eq 1 -and (($h[0].Key) -join '') -ceq '({[' -and $null -ne $h[0].ScriptBlock
    }
    Test-Case 'Closing brackets ) ] } share one SmartCloseBraces script handler' {
        Reset-Fake
        & $psrlBody
        $h = @($script:keyHandlers | Where-Object { $_.Brief -eq 'SmartCloseBraces' })
        $h.Count -eq 1 -and (($h[0].Key) -join '') -ceq ')]}' -and $null -ne $h[0].ScriptBlock
    }
    Test-Case 'Double and single quotes share one SmartInsertQuote script handler' {
        Reset-Fake
        & $psrlBody
        $h = @($script:keyHandlers | Where-Object { $_.Brief -eq 'SmartInsertQuote' })
        $h.Count -eq 1 -and (($h[0].Key) -join '') -ceq "`"'" -and $null -ne $h[0].ScriptBlock
    }
    Test-Case 'No key is bound more than once' {
        Reset-Fake
        & $psrlBody
        $dupes = @($script:keyHandlers | ForEach-Object { $_.Key } | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
        if ($dupes) { throw "Bound twice: $($dupes -join ', ')" }
        $true
    }
    Test-Case 'Ctrl+r and Ctrl+g are registered last, in that order (so PSFzf cannot override Ctrl+r)' {
        Reset-Fake
        & $psrlBody
        $n = $script:keyHandlers.Count
        $script:keyHandlers[$n - 2].Key -contains 'Ctrl+r' -and $script:keyHandlers[$n - 1].Key -contains 'Ctrl+g'
    }
    Test-Case 'Ctrl+r handler runs the fzf history search' {
        Reset-Fake
        & $psrlBody
        $warnings = Get-WarningText (& (Get-PsrlHandler 'Ctrl+r')[0].ScriptBlock 3>&1)
        $warnings -contains 'History search needs fzf'
    }
    Test-Case 'Ctrl+g handler runs the command palette' {
        Reset-Fake
        & $psrlBody
        $warnings = Get-WarningText (& (Get-PsrlHandler 'Ctrl+g')[0].ScriptBlock 3>&1)
        $warnings -contains 'Invoke-CommandPalette needs fzf'
    }

    # ======================= psreadline.ps1: Invoke-FzfHistory ===================================
    $historyDir = Join-Path $scratch 'Microsoft\Windows\PowerShell\PSReadLine'
    $historyFile = Join-Path $historyDir 'ConsoleHost_history.txt'
    New-Item -ItemType Directory -Path $historyDir -Force | Out-Null
    $env:APPDATA = $scratch
    function Set-History { param([string[]]$Lines) Set-Content -LiteralPath $historyFile -Value $Lines }

    Test-Case 'Invoke-FzfHistory warns and never calls fzf when fzf is absent' {
        Reset-Fake; Reset-Fzf
        Set-History 'a'
        $warnings = Get-WarningText (Invoke-FzfHistory 3>&1)
        $warnings -contains 'History search needs fzf' -and $script:fzfInputs.Count -eq 0
    }
    Test-Case 'Invoke-FzfHistory returns quietly without calling fzf when there is no history file' {
        Reset-Fake; Reset-Fzf
        $script:_cmdCache['fzf'] = $true
        Remove-Item -LiteralPath $historyFile -ErrorAction Ignore
        $out = @(Invoke-FzfHistory)
        $out.Count -eq 0 -and $script:fzfInputs.Count -eq 0
    }
    Test-Case 'Invoke-FzfHistory feeds fzf the history without blanks or duplicates, in file order' {
        Reset-Fake; Reset-Fzf
        $script:_cmdCache['fzf'] = $true
        Set-History 'git status', 'ls', 'git status', '', 'cd ..'
        Invoke-FzfHistory
        $script:fzfInputs.Count -eq 1 -and ($script:fzfInputs[0] -join '|') -ceq 'git status|ls|cd ..'
    }
    Test-Case 'Invoke-FzfHistory calls fzf with history scheme, newest first, and the del expect key' {
        Reset-Fake; Reset-Fzf
        $script:_cmdCache['fzf'] = $true
        Set-History 'a'
        Invoke-FzfHistory
        ($script:fzfArgs -join '|') -ceq '--scheme=history|--no-sort|--tac|--prompt|history> |--expect|del'
    }
    Test-Case 'Cancelling fzf leaves the history file untouched' {
        Reset-Fake; Reset-Fzf
        $script:_cmdCache['fzf'] = $true
        Set-History 'a', 'b'
        Invoke-FzfHistory
        $script:fzfInputs.Count -eq 1 -and ((Get-Content -LiteralPath $historyFile) -join '|') -ceq 'a|b'
    }
    Test-Case 'Pressing del removes every copy of the selected entry from the history file' {
        Reset-Fake; Reset-Fzf
        $script:_cmdCache['fzf'] = $true
        Set-History 'a', 'b', 'a', 'c'
        $script:fzfQueue.Enqueue(@('del', 'a'))
        Invoke-FzfHistory
        ((Get-Content -LiteralPath $historyFile) -join '|') -ceq 'b|c'
    }
    Test-Case 'After del the picker re-opens with the deleted entry gone' {
        Reset-Fake; Reset-Fzf
        $script:_cmdCache['fzf'] = $true
        Set-History 'a', 'b', 'c'
        $script:fzfQueue.Enqueue(@('del', 'b'))
        Invoke-FzfHistory
        $script:fzfInputs.Count -eq 2 -and ($script:fzfInputs[0] -join '|') -ceq 'a|b|c' -and ($script:fzfInputs[1] -join '|') -ceq 'a|c'
    }
    Test-Case 'Pressing del on an empty selection keeps the history file and ends the loop' {
        Reset-Fake; Reset-Fzf
        $script:_cmdCache['fzf'] = $true
        Set-History 'a', 'b'
        $script:fzfQueue.Enqueue(@('del', ''))
        Invoke-FzfHistory
        $script:fzfInputs.Count -eq 1 -and ((Get-Content -LiteralPath $historyFile) -join '|') -ceq 'a|b'
    }

    # ======================= psreadline.ps1: Invoke-CommandPalette ===============================
    function Get-PaletteRows {
        Reset-Fzf
        $script:_cmdCache['fzf'] = $true
        Invoke-CommandPalette
        @($script:fzfInputs[0])
    }

    Test-Case 'Invoke-CommandPalette warns and never calls fzf when fzf is absent' {
        Reset-Fzf
        $script:_cmdCache['fzf'] = $false
        $warnings = Get-WarningText (Invoke-CommandPalette 3>&1)
        $warnings -contains 'Invoke-CommandPalette needs fzf' -and $script:fzfInputs.Count -eq 0
    }
    Test-Case 'Command palette offers one row per documented command name' {
        $rows = Get-PaletteRows
        $rows.Count -eq @(Get-CatalogNames).Count -and $rows.Count -gt 0
    }
    Test-Case 'Command palette rows are name<TAB>description<TAB>[section]' {
        $rows = Get-PaletteRows
        $gp = @($rows | Where-Object { $_ -like "gp`t*" })
        $desc = ($script:ProfileHelp['Git / GitHub'] | Where-Object { $_.Cmd -eq 'gp / gpf' }).Desc
        $gp.Count -eq 1 -and $gp[0] -ceq "gp`t$desc`t[Git / GitHub]"
    }
    Test-Case "Combined entries 'gp / gpf' and 'gsta/gstp/gstl' are split into separate rows" {
        $names = @(Get-PaletteRows | ForEach-Object { ($_ -split "`t")[0] })
        $missing = @('gp', 'gpf', 'gsta', 'gstp', 'gstl', '..', '...', '....') | Where-Object { $names -notcontains $_ }
        $missing.Count -eq 0
    }
    Test-Case 'Argument placeholders like <path> and [-Yes] are stripped from palette names' {
        $names = @(Get-PaletteRows | ForEach-Object { ($_ -split "`t")[0] })
        $names -contains 'mkcd' -and $names -contains 'Install-DevTools' -and $names -contains 'size' -and
        @($names | Where-Object { $_ -match '[<>\[\]\s]' }).Count -eq 0
    }
    Test-Case 'Every palette row has exactly three tab-separated fields tagged with a catalog section' {
        $sections = @($script:ProfileHelp.Keys | ForEach-Object { "[$_]" })
        $bad = @(Get-PaletteRows | Where-Object { ($_ -split "`t").Count -ne 3 -or $sections -notcontains ($_ -split "`t")[2] })
        $bad.Count -eq 0
    }
    Test-Case 'Command palette calls fzf with tab delimiter, name/desc/section columns and the cmd> prompt' {
        $null = Get-PaletteRows
        (($script:fzfArgs | ForEach-Object { $_ -join ',' }) -join '|') -ceq "--delimiter|`t|--with-nth|1,2,3|--prompt|cmd> "
    }
    Test-Case 'Cancelling the command palette produces no output' {
        Reset-Fzf
        $script:_cmdCache['fzf'] = $true
        @(Invoke-CommandPalette).Count -eq 0
    }

    # ======================= help.ps1: catalog vs reality ========================================
    # z / zi come from `zoxide init`, which is deferred to OnIdle and absent here by design.
    $zoxideProvided = @('z', 'zi')

    Test-Case 'Every catalog entry has a non-empty Cmd and Desc' {
        $bad = @(Get-CatalogNames | Where-Object { [string]::IsNullOrWhiteSpace($_.Item.Cmd) -or [string]::IsNullOrWhiteSpace($_.Item.Desc) -or [string]::IsNullOrWhiteSpace($_.Name) })
        $bad.Count -eq 0
    }
    Test-Case 'Every documented command resolves to an existing command, alias or function' {
        $missing = @(Get-CatalogNames | Where-Object { $_.Name -notin $zoxideProvided -and -not (Get-Command $_.Name -ErrorAction Ignore) } | ForEach-Object { "$($_.Name) [$($_.Section)]" })
        if ($missing) { throw "Documented but undefined: $($missing -join ', ')" }
        $true
    }
    Test-Case 'Commands exempted because zoxide provides them are documented as optional' {
        $item = $script:ProfileHelp['Tools & system'] | Where-Object { $_.Cmd -eq 'z / zi' }
        $names = @(Get-CatalogNames | ForEach-Object Name)
        @($zoxideProvided | Where-Object { $names -notcontains $_ }).Count -eq 0 -and $item.Desc -like '*あれば*'
    }
    Test-Case 'No command name is documented twice' {
        $dupes = @(Get-CatalogNames | Group-Object { $_.Name.ToLowerInvariant() } | Where-Object Count -gt 1 | ForEach-Object Name)
        if ($dupes) { throw "Duplicated: $($dupes -join ', ')" }
        $true
    }
    Test-Case 'Documented flags such as [-Force], (-Check ...) and (-Ref/-Force) are real parameters' {
        $problems = foreach ($row in (Get-CatalogNames | Group-Object { $_.Item.Cmd } | Where-Object Count -eq 1 | ForEach-Object { $_.Group[0] })) {
            $cmd = Get-Command $row.Name -ErrorAction Ignore
            if (-not $cmd) { continue }
            foreach ($m in [regex]::Matches("$($row.Item.Cmd) $($row.Item.Desc)", '(?:\[-|[\(/]-)([A-Za-z]+)')) {
                if (-not $cmd.Parameters.ContainsKey($m.Groups[1].Value)) { "$($row.Name) -$($m.Groups[1].Value)" }
            }
        }
        if ($problems) { throw "Unknown parameters: $($problems -join ', ')" }
        $true
    }
    Test-Case "The 'Aliases' section's descriptions match each alias's real target" {
        $bad = foreach ($item in $script:ProfileHelp['Aliases']) {
            $alias = Get-Alias $item.Cmd -ErrorAction Ignore
            if (-not $alias -or $alias.Definition -ne $item.Desc) { $item.Cmd }
        }
        if ($bad) { throw "Alias target differs from docs: $($bad -join ', ')" }
        $true
    }
    Test-Case 'The tip line only advertises phelp, Ctrl+g and Ctrl+r, and both chords are bound' {
        Reset-Fake
        & $psrlBody
        $tip = (Get-HelpView).Records[-1]
        $tip -like '*phelp*' -and $tip -like '*Ctrl+g*' -and $tip -like '*Ctrl+r*' -and
        @(Get-PsrlHandler 'Ctrl+g').Count -eq 1 -and @(Get-PsrlHandler 'Ctrl+r').Count -eq 1
    }

    # ======================= help.ps1: Show-ProfileHelp output ===================================
    Test-Case 'Unfiltered help lists every section in catalog order' {
        (Get-HelpView).Sections -join '|' -ceq (@($script:ProfileHelp.Keys) -join '|')
    }
    Test-Case 'Unfiltered help lists every catalog command in catalog order' {
        $expected = foreach ($s in $script:ProfileHelp.Keys) { foreach ($i in $script:ProfileHelp[$s]) { $i.Cmd } }
        ((Get-HelpView).Items.Cmd -join '|') -ceq ($expected -join '|')
    }
    Test-Case 'Help prints each description next to its command' {
        $text = (Get-HelpView).Records -join "`n"
        $missing = foreach ($s in $script:ProfileHelp.Keys) { foreach ($i in $script:ProfileHelp[$s]) { if ($text -notlike "*$($i.Desc)*") { $i.Cmd } } }
        -not $missing
    }
    Test-Case 'A section-name filter narrows output to that section only' {
        $v = Get-HelpView 'Codex'
        $v.Sections.Count -eq 1 -and $v.Sections[0] -eq 'Codex' -and $v.Items.Count -eq $script:ProfileHelp['Codex'].Count
    }
    Test-Case 'A filter matches descriptions and drops sections with no matching entry' {
        $v = Get-HelpView 'zoxide'
        $v.Sections.Count -eq 1 -and $v.Sections[0] -eq 'Tools & system' -and $v.Items.Count -eq 1 -and $v.Items[0].Cmd -eq 'z / zi'
    }
    Test-Case 'A filter matches command names case-insensitively' {
        $v = Get-HelpView 'KILLPORT'
        $v.Items.Count -eq 1 -and $v.Items[0].Cmd -eq 'killport <n>'
    }
    Test-Case "Filter 'git' keeps only entries whose cmd, description or section contains it" {
        $v = Get-HelpView 'git'
        $bad = foreach ($row in $v.Items) {
            $item = $script:ProfileHelp[$row.Section] | Where-Object { $_.Cmd -eq $row.Cmd }
            if (-not ($item.Cmd -like '*git*' -or $item.Desc -like '*git*' -or $row.Section -like '*git*')) { $row.Cmd }
        }
        $v.Sections -contains 'Git / GitHub' -and $v.Sections -notcontains 'Codex' -and -not $bad
    }
    Test-Case 'A section-name match shows every entry of that section' {
        $v = Get-HelpView 'Git / GitHub'
        @($v.Items | Where-Object Section -eq 'Git / GitHub').Count -eq $script:ProfileHelp['Git / GitHub'].Count
    }
    Test-Case 'An unknown keyword prints no sections or commands, only the tip line' {
        $v = Get-HelpView 'no-such-keyword-zzz'
        $v.Sections.Count -eq 0 -and $v.Items.Count -eq 0 -and $v.Records[-1] -like 'tip:*'
    }
    Test-Case 'The phelp alias accepts the same filter as Show-ProfileHelp' {
        $direct = (Show-ProfileHelp 'Codex' 6>&1 | ForEach-Object { "$_" }) -join "`n"
        $viaAlias = (phelp 'Codex' 6>&1 | ForEach-Object { "$_" }) -join "`n"
        $direct -ceq $viaAlias -and $direct -like '*[[]Codex]*'
    }
}
finally {
    $env:PATH = $originalPath
    $env:APPDATA = $originalAppData
    if ($null -eq $originalTerm) { Remove-Item Env:TERM -ErrorAction Ignore } else { $env:TERM = $originalTerm }
    if ($global:_dotfilesProfileIdleSubscriptionId) {
        Unregister-Event -SubscriptionId $global:_dotfilesProfileIdleSubscriptionId -ErrorAction Ignore
    }
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}

Complete-Tests
