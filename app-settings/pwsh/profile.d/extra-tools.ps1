# Install-DevTools には含めず、必要な端末だけ Install-ExtraTools で入れるアプリ。
# GitHub Releases の最新インストーラを取得して実行する。
# Kind: exe = NSIS（/S で無人・ユーザー単位）、msi = msiexec（perMachine のため UAC が出る）。
$script:ExtraTools = @(
    @{ Name = 'DevDeck'; Repo = 'ntaksh42/DevDeck'; AssetPattern = '*_x64-setup.exe'; Kind = 'exe'; UninstallName = 'DevDeck'; Process = 'azdo-dashboard' }
    @{ Name = 'RdpManager'; Repo = 'ntaksh42/rdp-manager'; AssetPattern = '*.msi'; Kind = 'msi'; UninstallName = 'rdpmanager'; Process = 'rdpmanager' }
)

# 「アプリと機能」に載る導入情報（未導入なら $null）。
function Get-ExtraToolUninstallEntry {
    param([Parameter(Mandatory)]$Tool)
    $keys = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    Get-ItemProperty -Path $keys -ErrorAction Ignore |
        Where-Object { $_.DisplayName -eq $Tool.UninstallName } |
        Select-Object -First 1
}

# 未導入、または最新より古い ExtraTools を導入・更新する。-Name で対象を絞る（既定は全部）。
function Install-ExtraTools {
    [CmdletBinding()]
    param([string[]]$Name, [switch]$Yes)

    $tools = @(if ($Name) {
            foreach ($n in $Name) {
                $found = $script:ExtraTools | Where-Object { $_.Name -eq $n }
                if (-not $found) { throw "Unknown tool '$n'. Available: $(($script:ExtraTools.Name) -join ', ')" }
                $found
            }
        }
        else { $script:ExtraTools })

    $pending = @(foreach ($tool in $tools) {
            try {
                $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$($tool.Repo)/releases/latest" `
                    -Headers @{ 'User-Agent' = 'dotfiles-install-extratools' }
            }
            catch {
                Write-Warning "$($tool.Name): latest release could not be checked; skipping."
                continue
            }
            $entry = Get-ExtraToolUninstallEntry $tool
            if ($entry -and (Test-DevToolVersionCurrent $entry.DisplayVersion $release.tag_name)) {
                Write-Host "$($tool.Name) is up to date ($($release.tag_name))." -ForegroundColor Green
                continue
            }
            $asset = $release.assets | Where-Object { $_.name -like $tool.AssetPattern } | Select-Object -First 1
            if (-not $asset) {
                Write-Warning "$($tool.Name): no asset matching '$($tool.AssetPattern)' in $($release.tag_name); skipping."
                continue
            }
            [pscustomobject]@{ Tool = $tool; Tag = $release.tag_name; Asset = $asset; Action = if ($entry) { 'update' } else { 'install' } }
        })
    if ($pending.Count -eq 0) { return }

    Write-Host 'The following tools will be installed/updated:' -ForegroundColor Cyan
    $pending | ForEach-Object { Write-Host "  - $($_.Tool.Name) $($_.Tag) ($($_.Action))" }
    if (-not $Yes) {
        $ans = Read-Host 'Proceed? Running instances will be closed. (y/N)'
        if ($ans -notmatch '^(y|yes)$') { Write-Host 'Aborted.'; return }
    }

    $dir = Join-Path $env:TEMP 'dotfiles-extra-tools'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $results = @()
    foreach ($p in $pending) {
        $t = $p.Tool
        Write-Host "$($p.Action) $($t.Name) $($p.Tag)..." -ForegroundColor Green
        $ok = $false
        $file = Join-Path $dir $p.Asset.name
        try {
            Invoke-WebRequest -Uri $p.Asset.browser_download_url -OutFile $file -UseBasicParsing
            Get-Process -Name $t.Process -ErrorAction Ignore | Stop-Process -Force
            $proc = if ($t.Kind -eq 'msi') {
                Start-Process msiexec.exe -ArgumentList '/i', "`"$file`"", '/passive' -Wait -PassThru
            }
            else {
                Start-Process $file -ArgumentList '/S' -Wait -PassThru
            }
            # 3010 は成功だが再起動が必要。
            if ($proc.ExitCode -notin 0, 3010) { throw "installer exited with code $($proc.ExitCode)" }
            $ok = $true
        }
        catch {
            Write-Warning "  Failed: $($_.Exception.Message)"
        }
        finally {
            Remove-Item -LiteralPath $file -Force -ErrorAction Ignore
        }
        $results += [pscustomobject]@{ Tool = $t.Name; Action = $p.Action; Result = if ($ok) { 'OK' } else { 'FAILED' } }
    }

    Write-Host "`nInstall summary:" -ForegroundColor Cyan
    $results | Format-Table -AutoSize
}
