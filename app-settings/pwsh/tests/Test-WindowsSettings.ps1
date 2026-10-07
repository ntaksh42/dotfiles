# Run with: pwsh -NoProfile -File app-settings/pwsh/tests/Test-WindowsSettings.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$originalPath = $env:PATH
. (Join-Path $PSScriptRoot 'TestHarness.ps1')

$testKey = "HKCU:\Software\dotfiles-test-$([guid]::NewGuid().ToString('N'))"

try {
    $env:PATH = ''
    . (Join-Path $root 'Microsoft.PowerShell_profile.ps1')

    # --- Get-WindowsSettingValue against a real, throwaway HKCU key -------------------
    New-Item -Path "$testKey\Sub" -Force | Out-Null
    Set-ItemProperty -LiteralPath $testKey -Name 'Num' -Value 7 -Type DWord
    Set-ItemProperty -LiteralPath "$testKey\Sub" -Name '(default)' -Value 'dflt' -Type String

    Test-Case 'Get-WindowsSettingValue reads an existing value' {
        (Get-WindowsSettingValue $testKey 'Num') -eq 7
    }
    Test-Case 'Get-WindowsSettingValue returns $null for a missing value or key' {
        $null -eq (Get-WindowsSettingValue $testKey 'Nope') -and
        $null -eq (Get-WindowsSettingValue "$testKey\Missing" 'Num')
    }
    Test-Case 'Get-WindowsSettingValue reads the key default value for (default)' {
        (Get-WindowsSettingValue "$testKey\Sub" '(default)') -ceq 'dflt'
    }

    # --- Set-WindowsSettings with the registry and side effects faked -----------------
    $script:regValues = @{}   # "<path>|<name>" -> value
    $script:keys = @()        # keys that "exist"
    $script:writes = @()
    $script:created = @()
    $script:stopped = @()
    $script:admin = $true

    function Get-WindowsSettingValue($Path, $Name) { $script:regValues["$Path|$Name"] }
    function Test-IsAdministrator { $script:admin }
    function Test-Path { param($Path, $LiteralPath, $PathType) $script:keys -contains $LiteralPath }
    function New-Item { param($Path, $ItemType, [switch]$Force) $script:created += $Path; $script:keys += $Path }
    function Set-ItemProperty {
        param($LiteralPath, $Name, $Value, $Type)
        $script:writes += [pscustomobject]@{ Path = $LiteralPath; Name = $Name; Value = $Value; Type = $Type }
        $script:regValues["$LiteralPath|$Name"] = $Value
    }
    function Stop-Process { param($Name, [switch]$Force) $script:stopped += $Name }
    function Reset-Fake { $script:regValues = @{}; $script:keys = @(); $script:writes = @(); $script:created = @(); $script:stopped = @(); $script:admin = $true }

    # How many settings the catalog has: every one differs from an empty registry.
    Reset-Fake
    $total = @(Set-WindowsSettings -Check *>&1 | Out-String -Stream | Where-Object { $_ -like 'DIFF *' }).Count

    Test-Case 'Check on an empty registry reports every setting as a difference and writes nothing' {
        Reset-Fake
        $result = Set-WindowsSettings -Check 6>$null
        $total -gt 0 -and $result -eq $false -and $script:writes.Count -eq 0 -and $script:stopped.Count -eq 0
    }
    Test-Case 'Apply writes every setting once, then Check reports no differences' {
        Reset-Fake
        Set-WindowsSettings 6>$null
        $written = $script:writes.Count
        $script:writes = @()
        $clean = Set-WindowsSettings -Check 6>$null
        $written -eq $total -and $clean -eq $true
    }
    Test-Case 'Apply is idempotent: a second run writes nothing and does not restart Explorer' {
        Reset-Fake
        Set-WindowsSettings 6>$null
        $script:writes = @(); $script:stopped = @()
        Set-WindowsSettings 6>$null
        $script:writes.Count -eq 0 -and $script:stopped.Count -eq 0
    }
    Test-Case 'Explorer is restarted once after Explorer-group changes' {
        Reset-Fake
        Set-WindowsSettings 6>$null
        $script:stopped.Count -eq 1 -and $script:stopped[0] -eq 'explorer'
    }
    Test-Case '-NoRestartExplorer applies without restarting Explorer' {
        Reset-Fake
        Set-WindowsSettings -NoRestartExplorer 6>$null
        $script:writes.Count -eq $total -and $script:stopped.Count -eq 0
    }
    Test-Case '-WhatIf neither writes nor restarts Explorer' {
        Reset-Fake
        Set-WindowsSettings -WhatIf 6>$null
        $script:writes.Count -eq 0 -and $script:stopped.Count -eq 0 -and $script:created.Count -eq 0
    }
    Test-Case '-Group limits the settings touched and skips the Explorer restart when none are Explorer' {
        Reset-Fake
        Set-WindowsSettings -Group Appearance 6>$null
        $script:writes.Count -eq 2 -and
        @($script:writes | Where-Object { $_.Path -notlike '*\Themes\Personalize' }).Count -eq 0 -and
        $script:stopped.Count -eq 0
    }
    Test-Case 'Non-admin run skips HKLM settings with a warning and still applies HKCU ones' {
        Reset-Fake
        $script:admin = $false
        $warnings = @(Set-WindowsSettings -NoRestartExplorer 3>&1 6>$null | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        $hklm = @($script:writes | Where-Object { $_.Path -like 'HKLM:*' })
        $hklm.Count -eq 0 -and $warnings.Count -gt 0 -and $script:writes.Count -gt 0 -and
        $script:writes.Count + $warnings.Count -eq $total
    }
    Test-Case 'Only differing values are rewritten' {
        Reset-Fake
        Set-WindowsSettings -NoRestartExplorer 6>$null
        $taskbar = $script:regValues.Keys | Where-Object { $_ -like '*Explorer\Advanced|TaskbarAl' }
        $script:regValues[$taskbar] = 1
        $script:writes = @()
        Set-WindowsSettings -NoRestartExplorer 6>$null
        $script:writes.Count -eq 1 -and $script:writes[0].Name -eq 'TaskbarAl' -and $script:writes[0].Value -eq 0
    }
    Test-Case 'Missing keys are created before the value is written' {
        Reset-Fake
        Set-WindowsSettings -Group Privacy 6>$null
        $script:created.Count -eq 1 -and $script:created[0] -like '*\AdvertisingInfo' -and $script:writes.Count -eq 1
    }
    Test-Case 'Existing keys are not recreated' {
        Reset-Fake
        $script:keys = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo')
        Set-WindowsSettings -Group Privacy 6>$null
        $script:created.Count -eq 0 -and $script:writes.Count -eq 1
    }
    Test-Case 'Classic context menu is written as an empty String default value' {
        Reset-Fake
        Set-WindowsSettings -Group Explorer -NoRestartExplorer 6>$null
        $menu = $script:writes | Where-Object { $_.Name -eq '(default)' }
        @($menu).Count -eq 1 -and $menu.Type -eq 'String' -and $menu.Value -ceq '' -and $menu.Path -like '*\InprocServer32'
    }
    Test-Case 'Other settings are written as DWord' {
        Reset-Fake
        Set-WindowsSettings -NoRestartExplorer 6>$null
        @($script:writes | Where-Object { $_.Name -ne '(default)' -and $_.Type -ne 'DWord' }).Count -eq 0
    }
    Test-Case 'An unknown -Group is rejected' {
        $threw = $false
        try { Set-WindowsSettings -Group Bogus 6>$null } catch { $threw = $true }
        $threw
    }
}
finally {
    $env:PATH = $originalPath
    if ($global:_dotfilesProfileIdleSubscriptionId) {
        Unregister-Event -SubscriptionId $global:_dotfilesProfileIdleSubscriptionId -ErrorAction Ignore
    }
    Remove-Item -LiteralPath $testKey -Recurse -Force -ErrorAction Ignore
}

Complete-Tests
