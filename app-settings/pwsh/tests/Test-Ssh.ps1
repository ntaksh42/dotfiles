# Run with: pwsh -NoProfile -File app-settings/pwsh/tests/Test-Ssh.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$originalPath = $env:PATH
. (Join-Path $PSScriptRoot 'TestHarness.ps1')

$tmp = Join-Path ([IO.Path]::GetTempPath()) "dotfiles-ssh-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tmp | Out-Null

try {
    $env:PATH = ''
    . (Join-Path $root 'Microsoft.PowerShell_profile.ps1')
    Set-Variable -Name HOME -Value $tmp -Force -Option AllScope

    # --- Enable-SshServer ---------------------------------------------------------------
    function Test-IsAdministrator { $false }
    function Get-WindowsCapability { throw 'must not be called without admin' }

    Test-Case 'Enable-SshServer refuses to run without admin and changes nothing' {
        try { Enable-SshServer; $false } catch { "$_" -like '*管理者*' }
    }

    # Admin path with every system cmdlet faked; records changes in $script:calls, warnings in $script:warnings.
    function Invoke-FakeEnableSshServer {
        param([switch]$SetPrivate, [string]$RuleProfile = 'Any')
        function Test-IsAdministrator { $true }
        function Get-WindowsCapability { [pscustomobject]@{ Name = 'OpenSSH.Server~~~~0.0.1.0'; State = 'Installed' } }
        function Set-Service {}
        function Start-Service {}
        function Get-Command {}
        function Test-Path { $false }
        function Get-NetFirewallRule { [pscustomobject]@{ Profile = $RuleProfile } }
        function Enable-NetFirewallRule {}
        function Set-NetFirewallRule { param($Name, $Profile) $script:calls += "rule=$($Profile -join ',')" }
        function Get-NetFirewallProfile { [pscustomobject]@{ Name = 'Domain'; AllowLocalFirewallRules = 'False' } }
        function Get-NetIPAddress {}
        function Get-NetConnectionProfile {
            [pscustomobject]@{ Name = 'Cafe'; InterfaceAlias = 'Wi-Fi'; InterfaceIndex = 5; NetworkCategory = 'Public' }
            [pscustomobject]@{ Name = 'corp.example'; InterfaceAlias = 'Ethernet'; InterfaceIndex = 7; NetworkCategory = 'DomainAuthenticated' }
        }
        function Set-NetConnectionProfile { param($InterfaceIndex, $NetworkCategory) $script:calls += "$InterfaceIndex=$NetworkCategory" }
        $script:calls = @()
        $w = Enable-SshServer -SetPrivate:$SetPrivate 3>&1 6>$null | Where-Object { $_ -is [Management.Automation.WarningRecord] }
        $script:warnings = $w.Message -join "`n"
    }

    Test-Case 'Enable-SshServer only warns about Public networks by default' {
        Invoke-FakeEnableSshServer
        $script:calls.Count -eq 0 -and $script:warnings -like "*'Cafe'*-SetPrivate*"
    }
    Test-Case 'Enable-SshServer -SetPrivate switches only Public networks to Private' {
        Invoke-FakeEnableSshServer -SetPrivate
        $script:calls.Count -eq 1 -and $script:calls[0] -eq '5=Private'
    }
    Test-Case 'Enable-SshServer adds Domain to an sshd rule that lacks it, keeping Public' {
        Invoke-FakeEnableSshServer -RuleProfile 'Private, Public'
        $script:calls -contains 'rule=Domain,Private,Public'
    }
    Test-Case 'Enable-SshServer warns when GPO ignores local firewall rules' {
        Invoke-FakeEnableSshServer
        $script:warnings -like '*ローカルのファイアウォール規則が無効*'
    }

    # --- Add-SshHost with ssh / ssh-keygen faked -----------------------------------------
    $script:sshCalls = @()
    function ssh-keygen {
        $f = $args[$args.IndexOf('-f') + 1]
        Set-Content -LiteralPath $f -Value 'PRIVATE'
        Set-Content -LiteralPath "$f.pub" -Value 'ssh-ed25519 AAAATEST test'
        $global:LASTEXITCODE = 0
    }
    function ssh { $script:sshCalls += , @($args); $global:LASTEXITCODE = 0 }

    $config = Join-Path $tmp '.ssh\config'

    Test-Case 'Add-SshHost creates a key, registers it remotely and writes a config entry' {
        Add-SshHost -HostName 192.168.3.20 -User aksh0 -Alias desktop 6>$null
        $text = Get-Content -LiteralPath $config -Raw
        (Test-Path (Join-Path $tmp '.ssh\id_ed25519.pub')) -and
        $text -match 'Host desktop' -and $text -match 'HostName 192\.168\.3\.20' -and $text -match 'User aksh0' -and
        $text -notmatch 'Port' -and
        $script:sshCalls.Count -eq 2 -and $script:sshCalls[1] -contains 'desktop'
    }
    Test-Case 'Add-SshHost sends the public key to the host inside the encoded command' {
        $enc = ($script:sshCalls[0] | Where-Object { $_ -like 'powershell -NoProfile -EncodedCommand *' }) -replace '^.*EncodedCommand ', ''
        [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($enc)) -like '*ssh-ed25519 AAAATEST test*'
    }
    Test-Case 'Add-SshHost does not duplicate an existing Host entry or regenerate the key' {
        $script:sshCalls = @()
        Set-Content -LiteralPath (Join-Path $tmp '.ssh\id_ed25519') -Value 'KEEP'
        Add-SshHost -HostName 192.168.3.20 -User aksh0 -Alias desktop 3>$null 6>$null
        $count = ([regex]::Matches((Get-Content -LiteralPath $config -Raw), 'Host desktop')).Count
        $count -eq 1 -and (Get-Content -LiteralPath (Join-Path $tmp '.ssh\id_ed25519') -Raw).Trim() -eq 'KEEP'
    }
    Test-Case 'Add-SshHost writes Port only when it is not 22' {
        Add-SshHost -HostName h2 -User u -Port 2222 6>$null
        (Get-Content -LiteralPath $config -Raw) -match '(?s)Host h2\s+HostName h2\s+User u\s+Port 2222'
    }

    # --- Invoke-SshAll with a fake ssh on PATH (parallel runspaces cannot see the ssh function) ---
    $bin = Join-Path $tmp 'bin'
    New-Item -ItemType Directory -Path $bin | Out-Null
    Set-Content -LiteralPath (Join-Path $bin 'ssh.ps1') -Value @'
if ($args -contains 'bad') { 'connection refused'; exit 255 }
"$($args -join ' ')"; exit 0
'@
    $env:PATH = $bin
    $hostsFile = Join-Path $tmp '.ssh\hosts.txt'
    Set-Content -LiteralPath $hostsFile -Value @('# lab PCs', '', '  pc1  ', 'bad')

    Test-Case 'Invoke-SshAll runs the command on each listed host, skipping comments and blanks' {
        $r = Invoke-SshAll 'hostname' | Sort-Object Host
        $r.Count -eq 2 -and
        $r[0].Host -eq 'bad' -and $r[0].ExitCode -eq 255 -and $r[0].Output -eq 'connection refused' -and
        $r[1].Host -eq 'pc1' -and $r[1].ExitCode -eq 0 -and $r[1].Output -eq '-o BatchMode=yes -o ConnectTimeout=10 pc1 hostname'
    }
    Test-Case 'Invoke-SshAll reports a missing host list' {
        try { Invoke-SshAll 'hostname' -Path (Join-Path $tmp 'none.txt'); $false } catch { "$_" -like '*ホスト一覧がありません*' }
    }
}
finally {
    $env:PATH = $originalPath
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Complete-Tests
