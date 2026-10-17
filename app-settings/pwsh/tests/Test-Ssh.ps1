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
}
finally {
    $env:PATH = $originalPath
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Complete-Tests
