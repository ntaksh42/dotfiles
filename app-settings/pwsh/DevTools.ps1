$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# §7 Environment setup helpers
# ---------------------------------------------------------------------------

# Tool catalog (data-driven). Backend: winget | msstore | pip | psmodule | script | remote-config
$script:DevTools = @(
    @{ Name = 'Files'; Backend = 'winget'; Id = 'FilesCommunity.Files' }
    @{ Name = 'Everything'; Backend = 'winget'; Id = 'voidtools.Everything' }
    @{ Name = 'PC Manager'; Backend = 'msstore'; Id = '9PM860492SZD' }
    @{ Name = 'Waypoint'; Backend = 'script'; Id = 'https://raw.githubusercontent.com/ntaksh42/waypoint/main/installer/install.ps1'; Path = (Join-Path $env:LOCALAPPDATA 'Programs\waypoint\waypoint.exe'); Args = @{ Silent = $true }; RebootRequiredExitCode = 3010; Repo = 'ntaksh42/waypoint'; VersionSource = 'product' }
    @{ Name = 'Windows-Operation-Cli'; Backend = 'script'; Id = 'https://raw.githubusercontent.com/ntaksh42/Windows-Operation-Cli/main/install.ps1'; Path = (Join-Path $env:LOCALAPPDATA 'Programs\windows-operation-cli\windows-operation-cli.exe'); Args = @{ FromRelease = $true }; RequiredCommand = 'claude'; Repo = 'ntaksh42/Windows-Operation-Cli' }
    @{ Name = 'Crit'; Backend = 'script'; Id = "$script:DotfilesRawBase/tools/Install-Crit.ps1"; Path = (Join-Path $env:USERPROFILE '.local\bin\crit.exe'); Repo = 'tomasz-tomczyk/crit'; VersionSource = 'command' }
    @{ Name = 'starship'; Backend = 'winget'; Id = 'Starship.Starship'; Cmd = 'starship' }
    @{ Name = 'zoxide'; Backend = 'winget'; Id = 'ajeetdsouza.zoxide'; Cmd = 'zoxide' }
    @{ Name = 'eza'; Backend = 'winget'; Id = 'eza-community.eza'; Cmd = 'eza' }
    @{ Name = 'bat'; Backend = 'winget'; Id = 'sharkdp.bat'; Cmd = 'bat' }
    @{ Name = 'fd'; Backend = 'winget'; Id = 'sharkdp.fd'; Cmd = 'fd' }
    @{ Name = 'ripgrep'; Backend = 'winget'; Id = 'BurntSushi.ripgrep.MSVC'; Cmd = 'rg' }
    @{ Name = 'jq'; Backend = 'winget'; Id = 'jqlang.jq'; Cmd = 'jq' }
    @{ Name = 'delta'; Backend = 'winget'; Id = 'dandavison.delta'; Cmd = 'delta'; PostInstall = 'delta' }
    @{ Name = 'gsudo'; Backend = 'winget'; Id = 'gerardog.gsudo'; Cmd = 'gsudo' }
    @{ Name = 'lazygit'; Backend = 'winget'; Id = 'JesseDuffield.lazygit'; Cmd = 'lazygit' }
    @{ Name = 'VSCode'; Backend = 'winget'; Id = 'Microsoft.VisualStudioCode'; Cmd = 'code' }
    @{ Name = 'Python'; Backend = 'winget'; Id = 'Python.Python.3.12'; Cmd = 'python' }
    @{ Name = 'PowerShell 7'; Backend = 'winget'; Id = 'Microsoft.PowerShell'; Cmd = 'pwsh' }
    @{ Name = 'PSFzf'; Backend = 'psmodule'; Id = 'PSFzf' }
    @{ Name = 'Terminal-Icons'; Backend = 'psmodule'; Id = 'Terminal-Icons' }
    @{ Name = 'gita'; Backend = 'pip'; Id = 'gita'; Cmd = 'gita' }
    @{ Name = 'git'; Backend = 'winget'; Id = 'Git.Git'; Cmd = 'git' }
    @{ Name = 'gh'; Backend = 'winget'; Id = 'GitHub.cli'; Cmd = 'gh' }
    @{ Name = 'Azure CLI'; Backend = 'winget'; Id = 'Microsoft.AzureCLI'; Cmd = 'az' }
    @{ Name = 'fzf'; Backend = 'winget'; Id = 'junegunn.fzf'; Cmd = 'fzf' }
    @{ Name = 'starship.toml'; Backend = 'remote-config'; RepoPath = 'app-settings/starship/starship.toml'; Dest = (Join-Path $env:USERPROFILE '.config\starship.toml') }
    @{ Name = 'VSCode settings.json'; Backend = 'remote-config'; RepoPath = 'app-settings/vscode/settings.json'; Dest = (Join-Path $env:APPDATA 'Code\User\settings.json') }
    @{ Name = 'VSCode keybindings.json'; Backend = 'remote-config'; RepoPath = 'app-settings/vscode/keybindings.json'; Dest = (Join-Path $env:APPDATA 'Code\User\keybindings.json') }
    @{ Name = 'ccstatusline settings.json'; Backend = 'remote-config'; RepoPath = 'app-settings/ccstatusline/settings.json'; Dest = (Join-Path $env:USERPROFILE '.config\ccstatusline\settings.json') }
    @{ Name = 'auto-session-title (mod)'; Backend = 'claude-plugin'; Id = 'auto-session-title@dotfiles-mods'; Marketplace = 'dotfiles-mods'; MarketplaceSource = 'ntaksh42/dotfiles'; RequiredCommand = 'claude' }
    @{ Name = 'ado-pr-status (mod)'; Backend = 'claude-plugin'; Id = 'ado-pr-status@dotfiles-mods'; Marketplace = 'dotfiles-mods'; MarketplaceSource = 'ntaksh42/dotfiles'; RequiredCommand = 'claude' }
)

# Ensure Python/pip is available; install via winget if missing. Returns $true on success.
function Install-PythonIfMissing {
    if ((Test-Cmd python) -or (Test-Cmd pip)) { return $true }
    Write-Host 'Python/pip not found; installing Python via winget...' -ForegroundColor Green
    winget install --id Python.Python.3.12 --exact --source winget --accept-package-agreements --accept-source-agreements
    Assert-NativeCommandSucceeded 'winget install Python.Python.3.12'
    refreshenv
    $script:_cmdCache.Remove('python'); $script:_cmdCache.Remove('pip')
    if ((Test-Cmd python) -or (Test-Cmd pip)) { return $true }
    Write-Warning 'Python install ran but python/pip is still not on PATH (a new shell may be required).'
    return $false
}

# windows-operation-cli は実行ファイルに版情報がないため、導入時のタグと
# 実行ファイルのハッシュを記録して次回の比較に使う。
function Get-DevToolVersionMarkerPath {
    param([Parameter(Mandatory)]$Tool)
    $name = $Tool.Name -replace '[^A-Za-z0-9._-]', '-'
    return Join-Path $env:LOCALAPPDATA "dotfiles\devtools\$name.version"
}

# GitHub Releases の最新タグ。取得できない場合（オフライン・レート制限）は $null。
function Get-DevToolLatestVersion {
    param([Parameter(Mandatory)]$Tool)
    if (-not $Tool.Repo) { return $null }
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$($Tool.Repo)/releases/latest" `
            -Headers @{ 'User-Agent' = 'dotfiles-install-devtools' }
        return $release.tag_name
    }
    catch {
        return $null
    }
}

# 比較用にバージョン文字列を正規化する（前後空白・先頭 v・+ビルドメタデータを除去）。
function ConvertTo-DevToolVersion {
    param([AllowNull()][string]$Version)
    if (-not $Version) { return $null }
    return (($Version.Trim() -replace '^[vV]', '') -split '\+', 2)[0]
}

# 導入済みが最新以上なら $true。数値として読めれば 1.2.3 と 1.2.3.0 を同一視し、
# 導入済みの方が新しい場合も更新しない。読めなければ文字列一致で判定する。
function Test-DevToolVersionCurrent {
    param([AllowNull()][string]$Installed, [Parameter(Mandatory)][string]$Latest)
    $i = ConvertTo-DevToolVersion $Installed
    $l = ConvertTo-DevToolVersion $Latest
    if (-not $i) { return $false }
    $iv = $null; $lv = $null
    if ([version]::TryParse($i, [ref]$iv) -and [version]::TryParse($l, [ref]$lv)) {
        # [version] は省略された部分を -1 とするため 0 埋めしてから比較する。
        $pad = { param($v) [version]::new($v.Major, $v.Minor, [math]::Max($v.Build, 0), [math]::Max($v.Revision, 0)) }
        return ((& $pad $iv) -ge (& $pad $lv))
    }
    return ($i -eq $l)
}

# 改行コード・BOM・末尾の改行の違いを無視してテキストを比較する。
function Test-DevToolTextEqual {
    param([AllowNull()][string]$Left, [AllowNull()][string]$Right)
    $normalize = { param($s) if ($null -eq $s) { return $null }; ($s.TrimStart([char]0xFEFF) -replace "`r`n", "`n").TrimEnd("`n") }
    return ((& $normalize $Left) -ceq (& $normalize $Right))
}

# ローカルファイルを UTF-8 として読む（Windows PowerShell の Get-Content は BOM なし
# UTF-8 を ANSI として読み、日本語を含むファイルが常に不一致になるため）。
function Read-DevToolLocalText {
    param([Parameter(Mandatory)][string]$Path)
    return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
}

# 導入済みバージョン。版情報がない windows-operation-cli のみマーカーを使う。
function Get-DevToolInstalledVersion {
    param([Parameter(Mandatory)]$Tool)
    if ($Tool.VersionSource -eq 'product') {
        $info = (Get-Item -LiteralPath $Tool.Path).VersionInfo
        foreach ($v in @($info.ProductVersion, $info.FileVersion)) {
            if ($v -and $v.Trim()) { return (ConvertTo-DevToolVersion $v) }
        }
        return $null
    }
    if ($Tool.VersionSource -eq 'command') {
        try {
            $output = @(& $Tool.Path --version) -join "`n"
            if ($LASTEXITCODE -eq 0 -and $output -match '\bv?(\d+\.\d+[^\s]*)') { return (ConvertTo-DevToolVersion $Matches[1]) }
        }
        catch {}
        return $null
    }
    $marker = Get-DevToolVersionMarkerPath $Tool
    if ((Test-Path -LiteralPath $marker -PathType Leaf) -and
        (Test-Path -LiteralPath $Tool.Path -PathType Leaf)) {
        $recorded = @(Get-Content -LiteralPath $marker)
        if ($recorded.Count -ge 2 -and $recorded[0].Trim() -and
            $recorded[1].Trim() -eq (Get-FileHash -LiteralPath $Tool.Path).Hash) {
            return ($recorded[0].Trim() -replace '^v', '')
        }
    }
    return $null
}

# 配布元の2ファイルが両方ともローカルと一致するか確認する。通信失敗時は $null。
function Test-DevToolRemoteFilesUpToDate {
    param([Parameter(Mandatory)]$Tool)
    $upToDate = $true
    try {
        foreach ($relativePath in $Tool.RemoteFiles) {
            $remote = (Invoke-WebRequest -Uri "$script:DotfilesRawBase/$relativePath" -UseBasicParsing).Content
            $localPath = Join-Path (Split-Path -Parent $Tool.Path) (Split-Path -Leaf $relativePath)
            if (-not (Test-Path -LiteralPath $localPath -PathType Leaf) -or
                -not (Test-DevToolTextEqual (Read-DevToolLocalText $localPath) $remote)) { $upToDate = $false }
        }
    }
    catch { return $null }
    return $upToDate
}

# Detect whether a catalog tool is installed
function Test-ToolInstalled {
    param([Parameter(Mandatory)]$Tool)
    switch ($Tool.Backend) {
        'psmodule' { return [bool](Get-Module -ListAvailable -Name $Tool.Id) }
        'pip' {
            if (Test-Cmd $Tool.Cmd) { return $true }
            # --user の導入先 Scripts が PATH に無いとコマンドが見えないため pip 側でも確認する。
            if (-not (Test-Cmd python)) { return $false }
            $null = python -m pip show $Tool.Id 2>$null
            return ($LASTEXITCODE -eq 0)
        }
        # RequiredCommand の有無は導入済み判定に含めない（含めると claude が PATH に
        # 無いだけで毎回インストーラが走り、最後に失敗する）。Install-DevTools 側で扱う。
        'script' { return (Test-Path -LiteralPath $Tool.Path -PathType Leaf) }
        'claude-plugin' {
            if (-not (Test-Cmd claude)) { return $false }
            try { $plugins = claude plugin list --json | ConvertFrom-Json } catch { return $false }
            return [bool]($plugins | Where-Object { $_.id -eq $Tool.Id })
        }
        'remote-config' {
            if (-not (Test-Path -LiteralPath $Tool.Dest -PathType Leaf)) { return $false }
            try { $remote = Get-DotfilesRemoteConfig $Tool }
            catch {
                # 取得できないのに未導入扱いにすると既存ファイルの上書き処理へ進むため、据え置く。
                Write-Warning "$($Tool.Name): remote config could not be checked; keeping existing file."
                return $true
            }
            $local = Read-DevToolLocalText $Tool.Dest
            if (Test-DevToolTextEqual $local $remote) { return $true }
            # JSON は整形（インデント・改行）だけの違いを差分とみなさない。
            if ($Tool.Dest -like '*.json') {
                try {
                    $l = $local | ConvertFrom-Json | ConvertTo-Json -Depth 100 -Compress
                    $r = $remote | ConvertFrom-Json | ConvertTo-Json -Depth 100 -Compress
                    return ($l -ceq $r)
                }
                catch {}
            }
            return $false
        }
        default {
            if ($Tool.Cmd -and (Test-Cmd $Tool.Cmd)) { return $true }
            # 出力の Id 列は端末幅で「…」に切り詰められ文字列照合が外れるため、終了コード
            # （見つからなければ非 0）で判定する。msstore の規約確認で止まらないよう同意も渡す。
            $null = winget list --id $Tool.Id --exact --accept-source-agreements 2>$null
            return ($LASTEXITCODE -eq 0)
        }
    }
}

# Report install status of all catalog tools
function Show-DevEnv {
    $script:DevTools | ForEach-Object {
        [PSCustomObject]@{
            Tool      = $_.Name
            Backend   = $_.Backend
            Id        = $_.Id
            Installed = if (Test-ToolInstalled $_) { 'OK' } else { '-' }
        }
    } | Format-Table -AutoSize
}

function Sync-DevToolSkills {
    param(
        [string]$AgentsSkillsDir = (Join-Path $env:USERPROFILE '.agents\skills'),
        [string]$ClaudeSkillsDir = (Join-Path $env:USERPROFILE '.claude\skills')
    )

    if (-not (Test-Path -LiteralPath $AgentsSkillsDir -PathType Container)) { return }
    foreach ($skill in (Get-ChildItem -LiteralPath $AgentsSkillsDir -Directory -Force)) {
        if ($skill.LinkType -or -not (Test-Path -LiteralPath (Join-Path $skill.FullName 'SKILL.md') -PathType Leaf)) { continue }
        $destination = Join-Path $ClaudeSkillsDir $skill.Name
        if (Get-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue) { continue }

        New-Item -ItemType Directory -Path $ClaudeSkillsDir -Force | Out-Null
        Move-Item -LiteralPath $skill.FullName -Destination $destination -ErrorAction Stop
        try {
            New-Item -ItemType SymbolicLink -Path $skill.FullName -Target $destination -ErrorAction Stop | Out-Null
            Write-Host "Linked skill: $($skill.Name)" -ForegroundColor Gray
        }
        catch {
            Move-Item -LiteralPath $destination -Destination $skill.FullName -ErrorAction Stop
            throw
        }
    }
}

# Codex statusline は一時的に無効化中。導入済みの環境ではラッパーを退避する
# （codex 関数はラッパーが無ければ素の Codex CLI を起動する）。戻すときは
# `.disabled` を元の名前へ戻す。
function Disable-CodexStatusline {
    $wrapper = Join-Path $env:LOCALAPPDATA 'CodexStatusline\codex-wt.ps1'
    if (-not (Test-Path -LiteralPath $wrapper -PathType Leaf)) { return }
    Move-Item -LiteralPath $wrapper -Destination "$wrapper.disabled" -Force
    Write-Host "Codex statusline を無効化しました: $wrapper.disabled" -ForegroundColor Yellow
}

# Install missing catalog tools. Script-backed tools compare installed versions or
# remote file contents before updating. If the remote check fails, skip the update.
# remote-config の既存ファイル上書きは、ccstatusline のようにアプリ自身が書き換える
# 生きた設定を壊しうるため、-Force でも確認とJSON検証は省略しない
# （-Force が省略するのは冒頭の一括インストール確認と delta 導入後の確認のみ）。
# -Yes は上書き確認も含むすべての確認に y と答える（差分表示・JSON検証・バックアップは行う）。
function Install-DevTools {
    [CmdletBinding()]
    param([switch]$Force, [switch]$Yes)

    if ($Yes) { $Force = $true }

    Disable-CodexStatusline

    # 判定は winget/ネットワークを伴うため1回だけ行い、以降は結果を使い回す。
    $installed = @{}
    foreach ($tool in $script:DevTools) { $installed[$tool.Name] = [bool](Test-ToolInstalled $tool) }
    $toInstall = @($script:DevTools | Where-Object { -not $installed[$_.Name] })
    $latestVersions = @{}
    $toUpdate = @(foreach ($tool in $script:DevTools) {
        if ($tool.Backend -ne 'script' -or -not $installed[$tool.Name]) { continue }
        if ($tool.Repo) {
            $latest = Get-DevToolLatestVersion $tool
            if (-not $latest) {
                Write-Warning "$($tool.Name): latest version could not be checked; skipping update."
                continue
            }
            $latestVersions[$tool.Name] = $latest
            if (Test-DevToolVersionCurrent (Get-DevToolInstalledVersion $tool) $latest) { continue }
        }
        elseif ($tool.RemoteFiles) {
            $upToDate = Test-DevToolRemoteFilesUpToDate $tool
            if ($null -eq $upToDate) {
                Write-Warning "$($tool.Name): remote files could not be checked; skipping update."
                continue
            }
            if ($upToDate) { continue }
        }
        if ($tool.Name -eq 'Windows-Operation-Cli' -and
            (Get-Process -Name 'windows-operation-cli' -ErrorAction SilentlyContinue)) {
            Write-Warning 'Windows-Operation-Cli is running; close it before updating.'
            continue
        }
        $tool
    })
    # 前提コマンドが無いまま走らせても最後に失敗するだけなので、インストーラ自体を起動しない。
    $pending = @($toInstall + $toUpdate | Where-Object {
            if ($_.RequiredCommand -and -not (Get-Command $_.RequiredCommand -ErrorAction Ignore)) {
                Write-Warning "$($_.Name): '$($_.RequiredCommand)' not found; skipping."
                return $false
            }
            $true
        })
    if ($pending.Count -eq 0) {
        Sync-DevToolSkills
        Write-Host 'All dev tools already installed.' -ForegroundColor Green
        return
    }

    Write-Host 'The following tools will be installed/updated:' -ForegroundColor Cyan
    $pending | ForEach-Object {
        $action = if ($toUpdate -contains $_) { 'update' } else { 'install' }
        Write-Host "  - $($_.Name) [$($_.Backend)] $($_.Id) ($action)"
    }
    if (-not $Force) {
        $ans = Read-Host 'Proceed? (y/N)'
        if ($ans -notmatch '^(y|yes)$') { Write-Host 'Aborted.'; return }
    }

    Sync-DevToolSkills

    $results = @()
    foreach ($t in $pending) {
        $action = if ($toUpdate -contains $t) { 'Updating' } else { 'Installing' }
        Write-Host "$action $($t.Name)..." -ForegroundColor Green
        $ok = $false
        $rebootRequired = $false
        try {
            switch ($t.Backend) {
                'winget' {
                    winget install --id $t.Id --exact --source winget --accept-package-agreements --accept-source-agreements
                    Assert-NativeCommandSucceeded "winget install $($t.Id)"
                }
                'msstore' {
                    winget install --id $t.Id --source msstore --accept-package-agreements --accept-source-agreements
                    Assert-NativeCommandSucceeded "winget install $($t.Id)"
                }
                'pip' {
                    if (-not (Install-PythonIfMissing)) { throw 'Python/pip not found and could not be installed' }
                    if (Test-Cmd pip) {
                        pip install --user $t.Id
                        Assert-NativeCommandSucceeded "pip install $($t.Id)"
                    }
                    else {
                        python -m pip install --user $t.Id
                        Assert-NativeCommandSucceeded "python -m pip install $($t.Id)"
                    }
                }
                'psmodule' { Install-Module $t.Id -Scope CurrentUser -Force -AcceptLicense }
                'claude-plugin' {
                    # claude/install.ps1 が同名マーケットプレイスをクローン先のパスで登録済みなら、それを使う。
                    $marketplaces = claude plugin marketplace list --json | ConvertFrom-Json
                    if (-not ($marketplaces | Where-Object { $_.name -eq $t.Marketplace })) {
                        claude plugin marketplace add $t.MarketplaceSource
                        Assert-NativeCommandSucceeded "claude plugin marketplace add $($t.MarketplaceSource)"
                    }
                    claude plugin install $t.Id
                    Assert-NativeCommandSucceeded "claude plugin install $($t.Id)"
                }
                'script' {
                    $installerName = $t.Name -replace '[^A-Za-z0-9._-]', '-'
                    $installerPath = Join-Path $env:TEMP "$installerName-install.ps1"
                    Invoke-WebRequest -Uri $t.Id -OutFile $installerPath
                    # Splat as a hashtable: an array of '-Flag' strings is passed
                    # positionally, so switches never bind by name.
                    try {
                        if ($t.Args) {
                            $installerArgs = $t.Args.Clone()
                            if ($t.Name -eq 'Windows-Operation-Cli') {
                                $releaseTag = $latestVersions[$t.Name]
                                if (-not $releaseTag) { $releaseTag = Get-DevToolLatestVersion $t }
                                if (-not $releaseTag) { throw 'Windows-Operation-Cli release could not be checked.' }
                                $latestVersions[$t.Name] = $releaseTag
                                $installerArgs.Version = $releaseTag
                            }
                            & $installerPath @installerArgs
                        }
                        else { & $installerPath }
                    }
                    catch {
                        if ($t.RebootRequiredExitCode -and $_.Exception.Message -match "exit code $($t.RebootRequiredExitCode)") {
                            $rebootRequired = $true
                            Write-Warning "  Installed successfully, but Windows must be restarted before using $($t.Name)."
                        }
                        else {
                            throw
                        }
                    }
                    if ($t.RequiredCommand -and -not (Get-Command $t.RequiredCommand -ErrorAction Ignore)) {
                        throw "$($t.Name) requires '$($t.RequiredCommand)' to register its MCP server."
                    }
                }
                'remote-config' {
                    $content = Get-DotfilesRemoteConfig $t
                    # 取得内容がJSON宛先なのに壊れている場合、既存の生きた設定を
                    # 壊れたJSONで上書きしてしまう事故（例: StripCommentLines の
                    # 設定ミスで先頭行が欠落）を防ぐため、書き込み前に検証する。
                    if ($t.Dest -like '*.json') {
                        try { $null = $content | ConvertFrom-Json }
                        catch {
                            throw "取得した $($t.RepoPath) が不正なJSONのため中断しました（$($_.Exception.Message)）。$($t.Dest) は変更していません。"
                        }
                    }
                    $destDir = Split-Path -Parent $t.Dest
                    if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
                        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
                    }
                    $skip = $false
                    $existed = Test-Path -LiteralPath $t.Dest -PathType Leaf
                    # 既存ファイルがある場合の上書き確認は -Force でも省略しない（-Yes のみ省略）。
                    if ($existed) {
                        Write-Host "  差分 (ローカル -> リポジトリ):" -ForegroundColor Cyan
                        Show-DotfilesRemoteConfigDiff -Tool $t -RemoteContent $content | Write-Host
                        $cfg = if ($Yes) { 'y' } else { Read-Host "  $($t.Dest) は既に存在します。上書きしますか? (y/N)" }
                        if ($cfg -notmatch '^(y|yes)$') { $skip = $true }
                    }
                    if ($skip) {
                        Write-Host '  スキップしました。' -ForegroundColor Gray
                    }
                    else {
                        if ($existed) {
                            $backup = "$($t.Dest).backup.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
                            Copy-Item -LiteralPath $t.Dest -Destination $backup -Force
                            Write-Host "  既存ファイルをバックアップ: $backup" -ForegroundColor Gray
                        }
                        Set-Content -LiteralPath $t.Dest -Value $content -NoNewline -Encoding UTF8
                    }
                }
            }
            $ok = $true
            # 実行ファイルから版を読めないものだけ、更新前に確認したタグを記録する。
            if ($t.Repo -and -not $t.VersionSource) {
                $installedVersion = $latestVersions[$t.Name]
                if (-not $installedVersion) { $installedVersion = Get-DevToolLatestVersion $t }
                if ($installedVersion) {
                    $marker = Get-DevToolVersionMarkerPath $t
                    $hash = (Get-FileHash -LiteralPath $t.Path).Hash
                    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $marker) | Out-Null
                    Set-Content -LiteralPath $marker -Value "$installedVersion`n$hash" -NoNewline -Encoding UTF8
                }
            }
        }
        catch {
            Write-Warning "  Failed: $($_.Exception.Message)"
        }
        $result = if (-not $ok) { 'FAILED' } elseif ($rebootRequired) { 'RESTART REQUIRED' } else { 'OK' }
        $results += [PSCustomObject]@{ Tool = $t.Name; Action = $action; Result = $result }

        # Post-install: delta -> configure git pager (with confirmation)
        if ($ok -and $t.PostInstall -eq 'delta') {
            $cfg = if ($Force) { 'y' } else { Read-Host 'Configure git to use delta as pager? (y/N)' }
            if ($cfg -match '^(y|yes)$') {
                git config --global core.pager delta
                git config --global interactive.diffFilter 'delta --color-only'
                git config --global delta.navigate true
                Write-Host '  git pager set to delta.' -ForegroundColor Gray
            }
        }
    }

    refreshenv
    Write-Host "`nInstall summary:" -ForegroundColor Cyan
    $results | Format-Table -AutoSize
}

# Upgrade winget packages and PSGallery modules from the catalog
function Update-DevTools {
    Write-Host 'Upgrading winget packages...' -ForegroundColor Green
    winget upgrade --all --accept-package-agreements --accept-source-agreements
    Write-Host 'Updating PowerShell modules...' -ForegroundColor Green
    foreach ($m in ($script:DevTools | Where-Object { $_.Backend -eq 'psmodule' })) {
        if (Get-Module -ListAvailable -Name $m.Id) {
            Update-Module $m.Id -ErrorAction SilentlyContinue
        }
    }
}
