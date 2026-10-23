# Make this PC reachable over SSH: install OpenSSH Server, start sshd at boot, use pwsh as
# the login shell, and make sure port 22 is open on Domain and Private networks. Idempotent; needs admin.
# -SetPrivate also switches Public networks to Private (only for networks you trust).
# -DisablePasswordAuth turns off password login (run it after registering keys with Add-SshHost).
function Enable-SshServer {
    param([switch]$SetPrivate, [switch]$DisablePasswordAuth)

    if (-not (Test-IsAdministrator)) {
        Write-Error '管理者権限の PowerShell で実行してください。'
        return
    }

    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
    if ($cap.State -ne 'Installed') {
        Write-Host 'OpenSSH Server をインストールしています...'
        try { Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null }
        catch {
            if ("$_" -match '0x800f0954') {
                Write-Error 'OpenSSH Server を取得できませんでした (0x800f0954)。WSUS 管理下の端末では Windows Update から取れません。グループポリシー「オプション コンポーネントのインストールと修復の設定を指定する」で Windows Update からの直接取得を許可するか、情シスに導入を依頼してください。'
            }
            else { Write-Error "OpenSSH Server のインストールに失敗しました: $_" }
            return
        }
    }
    Set-Service -Name sshd -StartupType Automatic
    Start-Service -Name sshd

    if ($DisablePasswordAuth) {
        # sshd uses the first value it reads, so set the global lines (before any Match) or put one at the top.
        $configPath = Join-Path $env:ProgramData 'ssh\sshd_config'
        $lines = @(Get-Content -LiteralPath $configPath)
        $inMatch = $false; $found = $false
        $lines = foreach ($line in $lines) {
            if ($line -match '^\s*Match\s') { $inMatch = $true }
            if (-not $inMatch -and $line -match '^\s*PasswordAuthentication\s') { $found = $true; 'PasswordAuthentication no' } else { $line }
        }
        if (-not $found) { $lines = @('PasswordAuthentication no') + $lines }
        Set-Content -LiteralPath $configPath -Value $lines -Encoding ascii
        Restart-Service -Name sshd
        Write-Host 'パスワードでのログインを無効にしました（鍵でのみ接続できます）。'
    }

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

    # Port 22 must be open on Domain (company network) and Private. Public is left as the rule has it.
    $ruleName = 'OpenSSH-Server-In-TCP'
    $rule = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
    if ($rule) {
        $profiles = "$($rule.Profile)"
        if ($profiles -ne 'Any' -and ($profiles -notmatch 'Domain' -or $profiles -notmatch 'Private')) {
            $want = @('Domain', 'Private') + @($profiles -split ',\s*' | Where-Object { $_ -eq 'Public' })
            Set-NetFirewallRule -Name $ruleName -Profile $want
        }
        Enable-NetFirewallRule -Name $ruleName
    }
    else {
        New-NetFirewallRule -Name $ruleName -DisplayName 'OpenSSH Server (sshd)' -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -Profile Domain, Private | Out-Null
    }

    # Company GPO can make Windows ignore locally created rules; then only IT can open the port.
    $ignored = Get-NetFirewallProfile -PolicyStore ActiveStore | Where-Object { "$($_.AllowLocalFirewallRules)" -eq 'False' } | ForEach-Object Name
    if ($ignored) {
        Write-Warning "グループポリシーでローカルのファイアウォール規則が無効になっています ($($ignored -join ', '))。port 22 の受信許可を情シスに依頼してください。"
    }

    foreach ($p in Get-NetConnectionProfile | Where-Object NetworkCategory -eq 'Public') {
        if (-not $SetPrivate) {
            Write-Warning "ネットワーク '$($p.Name)' ($($p.InterfaceAlias)) は Public です。ここからの SSH 接続は通らないことがあります。信頼できるネットワークなら Enable-SshServer -SetPrivate で Private に変えられます。"
            continue
        }
        try {
            Set-NetConnectionProfile -InterfaceIndex $p.InterfaceIndex -NetworkCategory Private -ErrorAction Stop
            Write-Host "ネットワーク '$($p.Name)' ($($p.InterfaceAlias)) を Public から Private に変更しました。"
        }
        catch {
            Write-Warning "ネットワーク '$($p.Name)' を Private に変更できませんでした（グループポリシーで固定されている可能性があります）: $_"
        }
    }

    # Domain accounts log in as DOMAIN\user; local accounts as plain user.
    $user = if ($env:USERDOMAIN -and $env:USERDOMAIN -ne $env:COMPUTERNAME) { "$env:USERDOMAIN\$env:USERNAME" } else { $env:USERNAME }
    $ips = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.PrefixOrigin -in 'Dhcp', 'Manual' } | ForEach-Object IPAddress
    Write-Host 'sshd を起動しました。ほかの PC から次のコマンドで接続できます:' -ForegroundColor Green
    Write-Host "  ssh $user@$env:COMPUTERNAME"
    foreach ($ip in $ips) { Write-Host "  ssh $user@$ip" }
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
    # A new key gets a passphrase (ssh-keygen asks) and goes into ssh-agent, so BatchMode logins
    # (the check below, Invoke-SshAll) work without asking again.
    $agentReady = $true
    if (-not (Test-Path -LiteralPath $keyPath)) {
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
        Write-Host '秘密鍵のパスフレーズを決めて入力してください。'
        ssh-keygen -t ed25519 -f $keyPath -q
        if ($LASTEXITCODE -ne 0) { Write-Error 'ssh-keygen に失敗しました。'; return }

        $agent = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
        if ($agent -and $agent.Status -ne 'Running' -and "$($agent.StartType)" -eq 'Disabled' -and -not (Test-IsAdministrator)) {
            $agent = $null
            Write-Warning 'ssh-agent が無効です。管理者の PowerShell で Set-Service ssh-agent -StartupType Automatic; Start-Service ssh-agent を実行し、ssh-add で鍵を登録してください。'
        }
        if ($agent) {
            if ($agent.Status -ne 'Running') {
                if ("$($agent.StartType)" -eq 'Disabled') { Set-Service -Name ssh-agent -StartupType Automatic }
                Start-Service -Name ssh-agent
            }
            ssh-add $keyPath
        }
        $agentReady = $agent -and $LASTEXITCODE -eq 0
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

    if (-not $agentReady) {
        Write-Host "完了: ssh $Alias で接続できます（パスフレーズを聞かれます）。" -ForegroundColor Green
        return
    }
    ssh -o BatchMode=yes $Alias 'echo ok' | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "完了: ssh $Alias で接続できます。" -ForegroundColor Green }
    else { Write-Error "鍵での接続確認に失敗しました: ssh $Alias" }
}

# Run a command on every host in ~/.ssh/hosts.txt (one ~/.ssh/config Host name per line, # for
# comments) in parallel. Key login is required (see Add-SshHost); returns Host / ExitCode / Output.
function Invoke-SshAll {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Command,
        [string]$Path = (Join-Path $HOME '.ssh\hosts.txt'),
        [int]$ThrottleLimit = 16
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Error "ホスト一覧がありません: $Path（1 行に 1 つ、~/.ssh/config の Host 名を書いてください）"
        return
    }
    $hosts = Get-Content -LiteralPath $Path | ForEach-Object Trim | Where-Object { $_ -and -not $_.StartsWith('#') }

    $hosts | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $output = ssh -o BatchMode=yes -o ConnectTimeout=10 $_ $using:Command 2>&1
        [pscustomobject]@{ Host = $_; ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
    }
}
