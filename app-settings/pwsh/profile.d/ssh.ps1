# Make this PC reachable over SSH: install OpenSSH Server, start sshd at boot, use pwsh as
# the login shell, and make sure port 22 is open. Idempotent; needs admin.
function Enable-SshServer {
    if (-not (Test-IsAdministrator)) {
        Write-Error '管理者権限の PowerShell で実行してください。'
        return
    }

    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
    if ($cap.State -ne 'Installed') {
        Write-Host 'OpenSSH Server をインストールしています...'
        Add-WindowsCapability -Online -Name $cap.Name | Out-Null
    }
    Set-Service -Name sshd -StartupType Automatic
    Start-Service -Name sshd

    $pwsh = (Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $pwsh) {
        $default = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
        if (Test-Path -LiteralPath $default) { $pwsh = $default }
    }
    if ($pwsh) {
        New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
        Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $pwsh -Type String
        Write-Host "SSH の既定シェル: $pwsh"
    }
    else {
        Write-Warning 'pwsh が見つからないため、SSH の既定シェルは変更しませんでした。PowerShell 7 を入れてから再実行してください。'
    }

    # The capability normally creates this rule (all network profiles); recreate it if it was removed.
    if (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue) {
        Enable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP'
    }
    else {
        New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -Profile Private | Out-Null
    }

    $ips = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.PrefixOrigin -in 'Dhcp', 'Manual' } | ForEach-Object IPAddress
    Write-Host 'sshd を起動しました。ほかの PC から次のコマンドで接続できます:' -ForegroundColor Green
    Write-Host "  ssh $env:USERNAME@$env:COMPUTERNAME"
    foreach ($ip in $ips) { Write-Host "  ssh $env:USERNAME@$ip" }
}

# Set up key-based login to a Windows SSH host: create ~/.ssh/id_ed25519 if missing, register
# the public key on the host (asks for the host's password once), and add a Host entry to ~/.ssh/config.
function Add-SshHost {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$User,
        [string]$Alias = $HostName,
        [int]$Port = 22
    )

    $sshDir = Join-Path $HOME '.ssh'
    $keyPath = Join-Path $sshDir 'id_ed25519'
    if (-not (Test-Path -LiteralPath $keyPath)) {
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
        ssh-keygen -t ed25519 -N '' -f $keyPath -q
        if ($LASTEXITCODE -ne 0) { Write-Error 'ssh-keygen に失敗しました。'; return }
    }
    $publicKey = (Get-Content -LiteralPath "$keyPath.pub" -Raw).Trim()

    # Runs on the host in Windows PowerShell. sshd reads administrators' keys from ProgramData
    # (only Administrators and SYSTEM may have access), everyone else's from ~/.ssh.
    $remote = @'
$key = '__KEY__'
$admin = (whoami /groups) -match 'S-1-5-32-544'
$file = if ($admin) { "$env:ProgramData\ssh\administrators_authorized_keys" } else { "$HOME\.ssh\authorized_keys" }
New-Item -ItemType Directory -Path (Split-Path $file) -Force | Out-Null
if (-not ((Test-Path $file) -and (Get-Content $file) -contains $key)) { Add-Content -LiteralPath $file -Value $key -Encoding ascii }
if ($admin) { icacls $file /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null }
'@ -replace '__KEY__', $publicKey
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))

    Write-Host "$User@$HostName に公開鍵を登録します（接続先のパスワードを入力してください）"
    ssh -p $Port -o StrictHostKeyChecking=accept-new "$User@$HostName" "powershell -NoProfile -EncodedCommand $encoded"
    if ($LASTEXITCODE -ne 0) { Write-Error '公開鍵の登録に失敗しました。'; return }

    $configPath = Join-Path $sshDir 'config'
    if ((Test-Path -LiteralPath $configPath) -and (Select-String -LiteralPath $configPath -Pattern "^\s*Host\s+$([regex]::Escape($Alias))\s*$" -Quiet)) {
        Write-Warning "~/.ssh/config に Host $Alias が既にあるため追記しません。"
    }
    else {
        $entry = @('', "Host $Alias", "    HostName $HostName", "    User $User")
        if ($Port -ne 22) { $entry += "    Port $Port" }
        $entry += '    IdentityFile ~/.ssh/id_ed25519'
        Add-Content -LiteralPath $configPath -Value $entry
    }

    ssh -o BatchMode=yes $Alias 'echo ok' | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "完了: ssh $Alias で接続できます。" -ForegroundColor Green }
    else { Write-Error "鍵での接続確認に失敗しました: ssh $Alias" }
}
