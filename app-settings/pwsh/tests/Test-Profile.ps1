# Run with: pwsh -NoProfile -File app-settings/pwsh/tests/Test-Profile.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('dotfiles-profile-test-' + [guid]::NewGuid().ToString('N'))
$originalPath = $env:PATH
. (Join-Path $PSScriptRoot 'TestHarness.ps1')

function Initialize-UpdateFixture {
    $dir = Join-Path $scratch ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dir 'profile.d') | Out-Null
    $script:PROFILE = [pscustomobject]@{ CurrentUserCurrentHost = Join-Path $dir 'Microsoft.PowerShell_profile.ps1' }
    Set-Content -LiteralPath $script:PROFILE.CurrentUserCurrentHost -Value '# old profile' -NoNewline
    Set-Content -LiteralPath (Join-Path $dir 'profile.d\manifest.txt') -Value '# old manifest' -NoNewline
    Set-Content -LiteralPath (Join-Path $dir 'profile.d\devtools.ps1') -Value '# old tools' -NoNewline
    $script:remote = @{
        'Microsoft.PowerShell_profile.ps1' = '$script:UpdatedProfileLoaded = $true'
        'manifest.txt'                     = "# order`ndevtools.ps1`n"
        'devtools.ps1'                     = '# new tools'
    }
    $script:UpdatedProfileLoaded = $false
    $script:fetchFailure = $false
    $script:promptCount = 0
    $script:answer = 'y'
    $dir
}

function Get-BackupCount {
    param([string]$Dir)
    @(Get-ChildItem -LiteralPath $Dir -Recurse -Filter '*.backup.*').Count
}

try {
    New-Item -ItemType Directory -Path $scratch | Out-Null
    # Load the actual profile without invoking installed external tools.
    $env:PATH = ''
    . (Join-Path $root 'Microsoft.PowerShell_profile.ps1')

    Test-Case 'Git/bat shortcuts resolve to functions rather than built-in aliases' {
        @('gl', 'gp', 'gcm', 'cat' | Where-Object { (Get-Command $_).CommandType -ne 'Function' }).Count -eq 0
    }
    Test-Case 'Split profile loads environment commands and help' {
        (Get-Command Install-DevTools).CommandType -eq 'Function' -and
        (Get-Command Set-WindowsSettings).CommandType -eq 'Function' -and
        (Get-Command Update-Profile).CommandType -eq 'Function' -and
        (Get-Command phelp).ResolvedCommandName -eq 'Show-ProfileHelp'
    }
    Test-Case 'manifest lists exactly the profile.d scripts, each once' {
        $listed = @(Read-DotfilesManifest (Get-Content -LiteralPath (Join-Path $root 'profile.d\manifest.txt') -Raw))
        $actual = @(Get-ChildItem -LiteralPath (Join-Path $root 'profile.d') -Filter '*.ps1' | ForEach-Object Name)
        $listed.Count -eq @($listed | Select-Object -Unique).Count -and
        $null -eq (Compare-Object ($listed | Sort-Object) ($actual | Sort-Object))
    }
    Test-Case 'Compatibility DevTools.ps1 stub stays fetchable and defines nothing' {
        # 分割前の Update-Profile は DevTools.ps1 を取得するため、無いと旧ローダーの環境が移行できない。
        $stub = Join-Path $root 'DevTools.ps1'
        $tokens = $null; $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($stub, [ref]$tokens, [ref]$parseErrors)
        $parseErrors.Count -eq 0 -and $ast.EndBlock.Statements.Count -eq 0
    }
    Test-Case 'Manifest rejects names that escape profile.d' {
        $threw = $false
        try { $null = @(Read-DotfilesManifest "ok.ps1`n..\evil.ps1") } catch { $threw = $true }
        $threw
    }
    Test-Case 'Loader without profile.d keeps the recovery updater available' {
        $dir = Join-Path $scratch 'loader-only'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $loaderOnly = Join-Path $dir 'Microsoft.PowerShell_profile.ps1'
        Copy-Item -LiteralPath (Join-Path $root 'Microsoft.PowerShell_profile.ps1') -Destination $loaderOnly
        $output = & (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive -Command {
            param($Path)
            $env:PATH = ''
            $WarningPreference = 'SilentlyContinue'
            . $Path
            if ((Get-Command Update-Profile).CommandType -ne 'Function') { exit 1 }
            'RECOVERY_READY'
        } -args $loaderOnly
        $LASTEXITCODE -eq 0 -and $output -contains 'RECOVERY_READY'
    }
    Test-Case 'Installed loader without profile.d fetches and loads it on startup' {
        $dir = Join-Path $scratch 'auto-fetch'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $installed = Join-Path $dir 'Microsoft.PowerShell_profile.ps1'
        Copy-Item -LiteralPath (Join-Path $root 'Microsoft.PowerShell_profile.ps1') -Destination $installed
        $output = & (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive -Command {
            param($Path, $Root)
            $env:PATH = ''
            $PROFILE = [pscustomobject]@{ CurrentUserCurrentHost = $Path }
            function Invoke-WebRequest {
                param($Uri, [switch]$UseBasicParsing, $TimeoutSec)
                $leaf = ($Uri -split '/')[-1]
                $file = if ($leaf -eq 'Microsoft.PowerShell_profile.ps1') { Join-Path $Root $leaf } else { Join-Path $Root "profile.d\$leaf" }
                [pscustomobject]@{ Content = Get-Content -LiteralPath $file -Raw }
            }
            . $Path 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { 'WARNING' }
            if ((Get-Command Install-DevTools).CommandType -eq 'Function') { 'DEVTOOLS_LOADED' }
        } -args $installed, $root
        $output -contains 'DEVTOOLS_LOADED' -and $output -notcontains 'WARNING' -and
        (Test-Path -LiteralPath (Join-Path $dir 'profile.d\manifest.txt'))
    }

    function git {
        $script:gitArgs = @($args)
        $global:LASTEXITCODE = 0
        if ($args[0] -eq 'branch') { 'origin/HEAD'; 'origin/topic' }
        if ($args[0] -eq 'rev-parse') { $global:LASTEXITCODE = 1 }
    }
    function fzf {
        $script:choices = @($input)
        'origin/topic'
    }
    function bat { $script:batArgs = @($args) }
    $script:_cmdCache['fzf'] = $true
    $script:_cmdCache['bat'] = $true

    Test-Case 'Git log/push/commit shortcuts forward arguments' {
        gl --all
        $logOk = ($script:gitArgs -join '|') -eq 'log|--oneline|--graph|--decorate|-20|--all'
        gp origin topic
        $pushOk = ($script:gitArgs -join '|') -eq 'push|origin|topic'
        gcm 'message with spaces'
        $logOk -and $pushOk -and ($script:gitArgs -join '|') -eq 'commit|-m|message with spaces'
    }
    Test-Case 'cat invokes bat with the supplied file name' {
        cat 'file with spaces.txt'
        ($script:batArgs -join '|') -eq 'file with spaces.txt'
    }
    Test-Case 'gco still forwards explicit checkout arguments' {
        gco -b topic
        ($script:gitArgs -join '|') -eq 'checkout|-b|topic'
    }
    Test-Case 'gco picker excludes remote HEAD and creates a tracking branch' {
        gco
        $script:choices -notcontains 'origin/HEAD' -and
        ($script:gitArgs -join '|') -eq 'checkout|-b|topic|--track|origin/topic'
    }

    function Invoke-WebRequest {
        param($Uri, [switch]$UseBasicParsing, $TimeoutSec)
        if ($script:fetchFailure -and $Uri.EndsWith('Microsoft.PowerShell_profile.ps1')) { throw 'Simulated download failure' }
        [pscustomobject]@{ Content = $script:remote[($Uri -split '/')[-1]] }
    }
    function Read-Host { param($Prompt) $script:promptCount++; $script:answer }
    function Show-DotfilesRemoteConfigDiff { param($Tool, $RemoteContent) }

    Test-Case 'Update downloads every file, backs them up, and reloads' {
        $dir = Initialize-UpdateFixture
        Update-Profile -Force
        $script:UpdatedProfileLoaded -and (Get-BackupCount $dir) -eq 3 -and
        (Get-Content -LiteralPath $script:PROFILE.CurrentUserCurrentHost -Raw) -ceq $script:remote['Microsoft.PowerShell_profile.ps1'] -and
        (Get-Content -LiteralPath (Join-Path $dir 'profile.d\devtools.ps1') -Raw) -ceq $script:remote['devtools.ps1']
    }
    Test-Case 'Failed download leaves every installed file unchanged' {
        $dir = Initialize-UpdateFixture
        $script:fetchFailure = $true
        $threw = $false
        try { Update-Profile -Force } catch { $threw = $true }
        $threw -and (Get-Content -LiteralPath $script:PROFILE.CurrentUserCurrentHost -Raw) -eq '# old profile' -and
        (Get-Content -LiteralPath (Join-Path $dir 'profile.d\devtools.ps1') -Raw) -eq '# old tools' -and
        (Get-BackupCount $dir) -eq 0
    }
    Test-Case 'Invalid downloaded PowerShell leaves every installed file unchanged' {
        $dir = Initialize-UpdateFixture
        $script:remote['devtools.ps1'] = 'function Broken {'
        $threw = $false
        try { Update-Profile -Force } catch { $threw = $true }
        $threw -and (Get-Content -LiteralPath (Join-Path $dir 'profile.d\devtools.ps1') -Raw) -eq '# old tools' -and
        (Get-Content -LiteralPath $script:PROFILE.CurrentUserCurrentHost -Raw) -eq '# old profile' -and
        (Get-BackupCount $dir) -eq 0
    }
    Test-Case 'Remote manifest with a path-escaping name is rejected before any write' {
        $dir = Initialize-UpdateFixture
        $script:remote['manifest.txt'] = "devtools.ps1`n..\evil.ps1"
        $threw = $false
        try { Update-Profile -Force } catch { $threw = $true }
        $threw -and (Get-Content -LiteralPath $script:PROFILE.CurrentUserCurrentHost -Raw) -eq '# old profile' -and
        (Get-BackupCount $dir) -eq 0
    }
    Test-Case 'Declining the update leaves every installed file unchanged' {
        $dir = Initialize-UpdateFixture
        $script:answer = 'n'
        Update-Profile
        $script:promptCount -eq 1 -and
        (Get-Content -LiteralPath (Join-Path $dir 'profile.d\devtools.ps1') -Raw) -eq '# old tools' -and
        (Get-Content -LiteralPath $script:PROFILE.CurrentUserCurrentHost -Raw) -eq '# old profile'
    }
    Test-Case 'Missing profile.d file can be installed without replacing unchanged files' {
        $dir = Initialize-UpdateFixture
        Remove-Item -LiteralPath (Join-Path $dir 'profile.d\devtools.ps1')
        Set-Content -LiteralPath $script:PROFILE.CurrentUserCurrentHost -Value $script:remote['Microsoft.PowerShell_profile.ps1'] -NoNewline
        Set-Content -LiteralPath (Join-Path $dir 'profile.d\manifest.txt') -Value $script:remote['manifest.txt'] -NoNewline
        Update-Profile -Force
        (Get-Content -LiteralPath (Join-Path $dir 'profile.d\devtools.ps1') -Raw) -ceq $script:remote['devtools.ps1'] -and
        (Get-BackupCount $dir) -eq 0
    }
    Test-Case 'Unchanged files are not rewritten, backed up, or reloaded' {
        $dir = Initialize-UpdateFixture
        Set-Content -LiteralPath $script:PROFILE.CurrentUserCurrentHost -Value $script:remote['Microsoft.PowerShell_profile.ps1'] -NoNewline
        foreach ($name in 'manifest.txt', 'devtools.ps1') {
            Set-Content -LiteralPath (Join-Path $dir "profile.d\$name") -Value $script:remote[$name] -NoNewline
        }
        Update-Profile
        -not $script:UpdatedProfileLoaded -and $script:promptCount -eq 0 -and (Get-BackupCount $dir) -eq 0
    }

    function Invoke-RestMethod {
        param($Uri, $Headers)
        $repo = ($Uri -split '/')[5]
        $assets = if ($repo -eq 'DevDeck') { 'DevDeck_0.2.20_x64-setup.exe', 'DevDeck_0.2.20_x64_en-US.msi' } else { 'rdpmanager-0.4.13.msi' }
        [pscustomobject]@{
            tag_name = if ($repo -eq 'DevDeck') { 'v0.2.20' } else { 'v0.4.13' }
            assets   = @($assets | ForEach-Object { [pscustomobject]@{ name = $_; browser_download_url = "https://example.invalid/$_" } })
        }
    }
    function Invoke-WebRequest { param($Uri, $OutFile, [switch]$UseBasicParsing) Set-Content -LiteralPath $OutFile -Value 'stub' }
    function Start-Process {
        param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru)
        $script:started += , @($FilePath, ($ArgumentList -join ' '))
        [pscustomobject]@{ ExitCode = $script:installerExit }
    }
    function Get-ExtraToolUninstallEntry {
        param($Tool)
        if ($script:installedVersions.ContainsKey($Tool.Name)) { [pscustomobject]@{ DisplayVersion = $script:installedVersions[$Tool.Name] } }
    }
    function Initialize-ExtraToolFixture { $script:started = @(); $script:installerExit = 0; $script:installedVersions = @{} }

    Test-Case 'Install-ExtraTools is separate from the Install-DevTools catalog' {
        $script:DevTools.Name -notcontains 'DevDeck' -and $script:DevTools.Name -notcontains 'RdpManager' -and
        @($script:ExtraTools.Name) -contains 'DevDeck' -and @($script:ExtraTools.Name) -contains 'RdpManager'
    }
    Test-Case 'Install-ExtraTools updates an outdated DevDeck silently with the NSIS setup' {
        Initialize-ExtraToolFixture
        $script:installedVersions['DevDeck'] = '0.2.19'
        Install-ExtraTools -Name DevDeck -Yes | Out-Null
        $script:started.Count -eq 1 -and $script:started[0][0] -like '*DevDeck_0.2.20_x64-setup.exe' -and $script:started[0][1] -eq '/S'
    }
    Test-Case 'Install-ExtraTools skips a tool that is already current' {
        Initialize-ExtraToolFixture
        $script:installedVersions['DevDeck'] = '0.2.20'
        Install-ExtraTools -Name DevDeck -Yes | Out-Null
        $script:started.Count -eq 0
    }
    Test-Case 'Install-ExtraTools installs a missing RdpManager through msiexec' {
        Initialize-ExtraToolFixture
        Install-ExtraTools -Name RdpManager -Yes | Out-Null
        $script:started.Count -eq 1 -and $script:started[0][0] -eq 'msiexec.exe' -and
        $script:started[0][1] -like '/i "*rdpmanager-0.4.13.msi" /passive'
    }
    Test-Case 'Install-ExtraTools without -Name handles every extra tool' {
        Initialize-ExtraToolFixture
        Install-ExtraTools -Yes | Out-Null
        $script:started.Count -eq @($script:ExtraTools).Count
    }
    Test-Case 'Install-ExtraTools declining the prompt installs nothing' {
        Initialize-ExtraToolFixture
        $script:answer = 'n'
        Install-ExtraTools -Name DevDeck | Out-Null
        $script:started.Count -eq 0
    }
    Test-Case 'Install-ExtraTools rejects an unknown tool name' {
        Initialize-ExtraToolFixture
        $threw = $false
        try { Install-ExtraTools -Name Nope -Yes } catch { $threw = $true }
        $threw -and $script:started.Count -eq 0
    }
}
finally {
    $env:PATH = $originalPath
    if ($global:_dotfilesProfileIdleSubscriptionId) {
        Unregister-Event -SubscriptionId $global:_dotfilesProfileIdleSubscriptionId -ErrorAction Ignore
    }
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}

Complete-Tests
