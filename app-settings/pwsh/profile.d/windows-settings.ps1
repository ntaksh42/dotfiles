# Read a registry value; '(default)' reads the key's default value. Returns $null if absent
function Get-WindowsSettingValue($Path, $Name) {
    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $key) { return $null }
    $key.GetValue($(if ($Name -eq '(default)') { '' } else { $Name }))
}

function Test-IsAdministrator {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Apply Windows settings (registry) from the catalog below. Idempotent; HKLM entries need admin.
# -Check only reports differences and returns $true when none. -WhatIf previews writes.
function Set-WindowsSettings {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$Check,

        [ValidateSet('Explorer', 'Appearance', 'Dev', 'Input', 'Privacy', 'Security')]
        [string[]]$Group,

        [switch]$NoRestartExplorer
    )

    $cv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion'
    $adv = "$cv\Explorer\Advanced"

    # Type defaults to DWord. Explorer = $true restarts explorer.exe after the change.
    $settings = @(
        @{ Group = 'Explorer'; Label = 'タスクバーを左寄せ'; Path = $adv; Name = 'TaskbarAl'; Value = 0; Explorer = $true }
        @{ Group = 'Explorer'; Label = 'タスクバーの検索を非表示'; Path = "$cv\Search"; Name = 'SearchboxTaskbarMode'; Value = 0; Explorer = $true }
        @{ Group = 'Explorer'; Label = '拡張子を表示'; Path = $adv; Name = 'HideFileExt'; Value = 0; Explorer = $true }
        @{ Group = 'Explorer'; Label = '隠しファイルを表示'; Path = $adv; Name = 'Hidden'; Value = 1; Explorer = $true }
        @{ Group = 'Explorer'; Label = 'タスクバーの「タスクの終了」を有効化'; Path = "$adv\TaskbarDeveloperSettings"; Name = 'TaskbarEndTask'; Value = 1; Explorer = $true }
        @{ Group = 'Explorer'; Label = '従来のコンテキストメニュー'; Path = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'; Name = '(default)'; Value = ''; Type = 'String'; Explorer = $true }
        @{ Group = 'Appearance'; Label = 'アプリをダークモード'; Path = "$cv\Themes\Personalize"; Name = 'AppsUseLightTheme'; Value = 0 }
        @{ Group = 'Appearance'; Label = 'システムをダークモード'; Path = "$cv\Themes\Personalize"; Name = 'SystemUsesLightTheme'; Value = 0 }
        @{ Group = 'Dev'; Label = '開発者モード'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'; Name = 'AllowDevelopmentWithoutDevLicense'; Value = 1 }
        @{ Group = 'Dev'; Label = '長いパスを有効化'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'; Name = 'LongPathsEnabled'; Value = 1 }
        @{ Group = 'Input'; Label = 'クリップボード履歴'; Path = 'HKCU:\Software\Microsoft\Clipboard'; Name = 'EnableClipboardHistory'; Value = 1 }
        @{ Group = 'Privacy'; Label = '広告 ID を無効化'; Path = "$cv\AdvertisingInfo"; Name = 'Enabled'; Value = 0 }
        @{ Group = 'Security'; Label = 'UAC: 管理者の昇格確認を出さない'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'ConsentPromptBehaviorAdmin'; Value = 0 }
    )

    $isAdmin = Test-IsAdministrator
    $diffCount = 0
    $restartExplorer = $false

    foreach ($s in $settings | Where-Object { -not $Group -or $_.Group -in $Group }) {
        $label = "[$($s.Group)] $($s.Label)"
        $current = Get-WindowsSettingValue $s.Path $s.Name

        if ($null -ne $current -and "$current" -eq "$($s.Value)") {
            Write-Host "OK   $label"
            continue
        }

        $diffCount++
        $from = if ($null -eq $current) { '<未設定>' } else { $current }

        if ($Check) {
            Write-Host "DIFF $label : $from -> $($s.Value)" -ForegroundColor Yellow
            continue
        }
        if ($s.Path -like 'HKLM:*' -and -not $isAdmin) {
            Write-Warning "管理者権限が必要なためスキップ: $label"
            continue
        }

        if ($s.Explorer) { $restartExplorer = $true }
        if ($PSCmdlet.ShouldProcess("$($s.Path)\$($s.Name)", "$from -> $($s.Value)")) {
            if (-not (Test-Path -LiteralPath $s.Path)) {
                New-Item -Path $s.Path -Force | Out-Null
            }
            $type = if ($s.Type) { $s.Type } else { 'DWord' }
            Set-ItemProperty -LiteralPath $s.Path -Name $s.Name -Value $s.Value -Type $type
            Write-Host "SET  $label : $from -> $($s.Value)" -ForegroundColor Green
        }
    }

    if ($restartExplorer -and -not $NoRestartExplorer) {
        if ($PSCmdlet.ShouldProcess('explorer.exe', '再起動')) {
            Stop-Process -Name explorer -Force
        }
    }

    if ($Check) {
        if ($diffCount -gt 0) { Write-Host "$diffCount 件の差分があります。" -ForegroundColor Yellow }
        $diffCount -eq 0
    }
}
