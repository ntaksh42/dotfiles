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
    if ($Tool.VersionSource -eq 'appx') {
        $package = Get-AppxPackage -Name $Tool.AppxName | Select-Object -First 1
        if ($package) { return (ConvertTo-DevToolVersion $package.Version) }
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

# 導入済み plugin の版が GitHub の main にある plugin.json と同じか確認する。読めなければ $null。
# 手元の写し（ZIP の展開先やクローン）は古いことがあるので、比べる相手にしない。
function Test-DevToolPluginUpToDate {
    param([Parameter(Mandatory)]$Tool)
    try {
        $installed = (claude plugin list --json | ConvertFrom-Json | Where-Object { $_.id -eq $Tool.Id }).version
        if (-not $installed) { return $null }
        $name = ($Tool.Id -split '@')[0]
        $manifest = Get-DotfilesRemoteConfig @{ RepoPath = '.claude-plugin/marketplace.json' } | ConvertFrom-Json
        $source = ($manifest.plugins | Where-Object { $_.name -eq $name }).source
        if ($source -isnot [string]) { return $null }
        $pluginJson = Get-DotfilesRemoteConfig @{ RepoPath = "$($source -replace '^\./', '')/.claude-plugin/plugin.json" }
        $latest = ($pluginJson | ConvertFrom-Json).version
        if (-not $latest) { return $null }
        return (Test-DevToolVersionCurrent $installed $latest)
    }
    catch { return $null }
}

# plugin のマーケットプレイスを置くフォルダ。GitHub の main の ZIP をここへ展開する。
function Get-DevToolMarketplaceDir {
    param([Parameter(Mandatory)]$Tool)
    return (Join-Path $env:LOCALAPPDATA "dotfiles\marketplaces\$($Tool.Marketplace)")
}

# MarketplaceSource (owner/repo) の main を ZIP で取得し、マーケットプレイスのフォルダを置き換える。
# git もクローンも使わない。展開は隣のフォルダで行い、成功してから入れ替える。
function Save-DevToolMarketplace {
    param([Parameter(Mandatory)]$Tool)
    $dest = Get-DevToolMarketplaceDir $Tool
    $staging = "$dest.download"
    try {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        $zip = Join-Path $staging 'main.zip'
        Invoke-WebRequest -Uri "https://github.com/$($Tool.MarketplaceSource)/archive/refs/heads/main.zip" -OutFile $zip -UseBasicParsing
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $staging 'x')
        $root = @(Get-ChildItem -LiteralPath (Join-Path $staging 'x') -Directory)
        if ($root.Count -ne 1) { throw "Unexpected layout in the archive of $($Tool.MarketplaceSource)." }
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        Move-Item -LiteralPath $root[0].FullName -Destination $dest
    }
    finally { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
}

# 保存済みの plugin の設定値を、claude plugin install に渡す --config 引数にする。
# マーケットプレイスを登録し直すと設定値が消えるため、消す前に控えて入れ直すのに使う。
function Get-DevToolPluginConfigArgs {
    param([Parameter(Mandatory)][string]$Id)
    $configDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
    $path = Join-Path $configDir 'settings.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $configs = (Read-DevToolLocalText $path | ConvertFrom-Json).pluginConfigs
    if (-not $configs -or -not $configs.$Id -or -not $configs.$Id.options) { return }
    foreach ($option in $configs.$Id.options.psobject.Properties) {
        $value = if ($option.Value -is [bool]) { "$($option.Value)".ToLowerInvariant() } else { "$($option.Value)" }
        '--config'
        "$($option.Name)=$value"
    }
}

# winget / msstore 側に新しい版があるか。--upgrade-available は該当なしでも終了コード 0 を
# 返すため、出力にパッケージ ID が現れるかで判定する。取りこぼしても winget upgrade 側が
# 「更新なし」を成功として扱うので、更新が一度余分に走るだけで害はない。
function Test-DevToolWingetUpgradeAvailable {
    param([Parameter(Mandatory)]$Tool)
    $source = if ($Tool.Backend -eq 'msstore') { 'msstore' } else { 'winget' }
    $output = @(winget list --id $Tool.Id --exact --source $source --upgrade-available --accept-source-agreements 2>$null)
    return [bool]($output -match [regex]::Escape($Tool.Id))
}

# winget upgrade は更新が不要なときも失敗扱いの終了コードを返すため、それだけは成功とみなす。
# 呼び出し側の実行で $LASTEXITCODE が変わるので、終了コードは引数で受け取る。
function Assert-DevToolWingetUpgraded {
    param([Parameter(Mandatory)]$Tool, [int]$ExitCode)
    # 0x8A15002B = APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE
    if ($ExitCode -eq -1978335189) {
        Write-Host '  Already up to date.' -ForegroundColor Gray
        return
    }
    if ($ExitCode -ne 0) { throw "winget upgrade $($Tool.Id) failed with exit code $ExitCode." }
}

# 更新中に実行ファイルが掴まれていると失敗したり、起動中のアプリを落とされるため、
# ProcessName を持つものは起動中なら更新を見送る。ProcessPath は同名の別プロセス
# （Claude デスクトップアプリに対する Claude Code CLI の claude.exe など）を除くための
# パス パターン。
function Test-DevToolProcessRunning {
    param([Parameter(Mandatory)]$Tool)
    if (-not $Tool.ProcessName) { return $false }
    $processes = @(Get-Process -Name $Tool.ProcessName -ErrorAction SilentlyContinue)
    if ($Tool.ProcessPath) {
        $processes = @($processes | Where-Object { $_.Path -and $_.Path -like $Tool.ProcessPath })
    }
    return ($processes.Count -gt 0)
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
        'script' {
            if ($Tool.AppxName) { return [bool](Get-AppxPackage -Name $Tool.AppxName) }
            return (Test-Path -LiteralPath $Tool.Path -PathType Leaf)
        }
        'npm' { return [bool](Test-Cmd $Tool.Cmd) }
        'claude-plugin' {
            if (-not (Test-Cmd claude)) { return $false }
            try { $plugins = claude plugin list --json | ConvertFrom-Json } catch { return $false }
            # インストール済みでも無効なら未導入扱いにし、Install-DevTools で有効化する。
            # Replaces に挙げた旧 plugin が残っている間も未導入扱いにし、Install-DevTools で外す。
            if ($Tool.Replaces -and ($plugins | Where-Object { $Tool.Replaces -contains $_.id })) { return $false }
            if (-not ($plugins | Where-Object { $_.id -eq $Tool.Id -and $_.enabled })) { return $false }
            # 旧版はマーケットプレイスをクローン先のパスで登録していた。ZIP の展開先以外を指す登録は
            # 未導入扱いにし、Install-DevTools で登録し直す。
            $registered = claude plugin marketplace list --json | ConvertFrom-Json | Where-Object { $_.name -eq $Tool.Marketplace }
            return (-not ($registered -and $registered.path -ne (Get-DevToolMarketplaceDir $Tool)))
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
            # ソースを絞らないと、無関係なソース（社内ネットワークで塞がれた msstore 等）の
            # 失敗でも非 0 になり、導入済みを未導入と誤判定する。
            $source = if ($Tool.Backend -eq 'msstore') { 'msstore' } else { 'winget' }
            $null = winget list --id $Tool.Id --exact --source $source --accept-source-agreements 2>$null
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

# 配置済みのプロファイル・共通ルール・dotfiles plugin が GitHub の main と一致するかを一覧する。
# 古い項目には直すコマンドを添える。取得に失敗した項目は「不明」。
function Test-DotfilesDeployment {
    param(
        [string]$ClaudeDir = (Join-Path $env:USERPROFILE '.claude'),
        [string]$CodexDir = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' })
    )
    $row = { param($target, $state, $fix) [pscustomobject]@{ Target = $target; Status = $state; Fix = $fix } }
    $status = { param($ok) if ($null -eq $ok) { '不明' } elseif ($ok) { 'OK' } else { '古い' } }

    $profileOk = try { @(Get-DotfilesProfileUpdates).Count -eq 0 } catch { $null }
    & $row 'PowerShell プロファイル' (& $status $profileOk) 'Update-Profile'

    $rules = try { Get-DotfilesRemoteConfig @{ RepoPath = 'claude/CLAUDE.global.md' } } catch { $null }
    foreach ($dest in @((Join-Path $ClaudeDir 'CLAUDE.md'), (Join-Path $CodexDir 'AGENTS.md'))) {
        $ok = if ($null -eq $rules) { $null }
        elseif (-not (Test-Path -LiteralPath $dest -PathType Leaf)) { $false }
        else { Test-DevToolTextEqual (Read-DevToolLocalText $dest) $rules }
        & $row $dest (& $status $ok) 'tools/Install-AgentInstructions.ps1'
    }

    foreach ($tool in @($script:DevTools | Where-Object { $_.Backend -eq 'claude-plugin' })) {
        $ok = if (Test-Cmd claude) { Test-DevToolPluginUpToDate $tool } else { $null }
        & $row $tool.Id (& $status $ok) 'Install-DevTools'
    }
}

function Sync-DevToolSkills {
    param(
        [string]$AgentsSkillsDir = (Join-Path $env:USERPROFILE '.agents\skills'),
        [string]$ClaudeSkillsDir = (Join-Path $env:USERPROFILE '.claude\skills')
    )

    $ErrorActionPreference = 'Stop'
    $AgentsSkillsDir = [IO.Path]::GetFullPath($AgentsSkillsDir).TrimEnd('\', '/')
    $ClaudeSkillsDir = [IO.Path]::GetFullPath($ClaudeSkillsDir).TrimEnd('\', '/')
    if ($AgentsSkillsDir -eq $ClaudeSkillsDir -or
        $AgentsSkillsDir.StartsWith("$ClaudeSkillsDir\", [StringComparison]::OrdinalIgnoreCase) -or
        $ClaudeSkillsDir.StartsWith("$AgentsSkillsDir\", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Skills directories must be separate, non-nested paths.'
    }
    $agents = Get-Item -LiteralPath $AgentsSkillsDir -Force -ErrorAction SilentlyContinue
    $claude = Get-Item -LiteralPath $ClaudeSkillsDir -Force -ErrorAction SilentlyContinue
    if ($claude.LinkType) {
        if ([IO.Path]::GetFullPath($claude.Target) -eq $AgentsSkillsDir) { return }
        throw "Skills directory points elsewhere: $ClaudeSkillsDir"
    }
    if (-not $agents -and -not $claude) { return }
    if (($agents -and (-not $agents.PSIsContainer -or $agents.LinkType)) -or
        ($claude -and -not $claude.PSIsContainer)) {
        throw 'Skills source paths must be ordinary directories.'
    }

    if ($claude) {
        foreach ($entry in Get-ChildItem -LiteralPath $ClaudeSkillsDir -Force) {
            if ($entry.LinkType) { throw "Resolve the linked skill before migration: $($entry.FullName)" }
        }
    }

    # Reject unrelated links before moving anything. Old links into Claude are
    # superseded by the real Claude directories during migration.
    if ($agents) {
        foreach ($entry in Get-ChildItem -LiteralPath $AgentsSkillsDir -Force) {
            if ($entry.LinkType) {
                $target = [IO.Path]::GetFullPath($entry.Target)
                if ($target.StartsWith('\\?\')) { $target = $target.Substring(4) }
                if ($target -ne (Join-Path $ClaudeSkillsDir $entry.Name) -or
                    -not (Test-Path -LiteralPath $target -PathType Container)) {
                    throw "Resolve the linked skill before migration: $($entry.FullName)"
                }
            }
        }
    }

    $backup = "$AgentsSkillsDir-backup-$([guid]::NewGuid().ToString('N'))"
    $moves = [Collections.Generic.List[object]]::new()
    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $AgentsSkillsDir) -Force | Out-Null
        if ($claude) {
            if ($agents) {
                Move-Item -LiteralPath $AgentsSkillsDir -Destination $backup
                $moves.Add(@($AgentsSkillsDir, $backup))
            }
            Move-Item -LiteralPath $ClaudeSkillsDir -Destination $AgentsSkillsDir
            $moves.Add(@($ClaudeSkillsDir, $AgentsSkillsDir))
            if ($agents) {
                foreach ($entry in Get-ChildItem -LiteralPath $backup -Force) {
                    $destination = Join-Path $AgentsSkillsDir $entry.Name
                    if ($entry.LinkType -or (Get-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue)) { continue }
                    Move-Item -LiteralPath $entry.FullName -Destination $destination
                    $moves.Add(@($entry.FullName, $destination))
                }
            }
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $ClaudeSkillsDir) -Force | Out-Null
        # Junctions work on Windows without Developer Mode or administrator rights.
        New-Item -ItemType Junction -Path $ClaudeSkillsDir -Target $AgentsSkillsDir | Out-Null
    }
    catch {
        for ($i = $moves.Count - 1; $i -ge 0; $i--) {
            Move-Item -LiteralPath $moves[$i][1] -Destination $moves[$i][0]
        }
        throw
    }
    if (Test-Path -LiteralPath $backup) { Write-Host "Previous Codex skills: $backup" -ForegroundColor Gray }
    Write-Host "Linked skills: $ClaudeSkillsDir -> $AgentsSkillsDir" -ForegroundColor Gray
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

# 廃止した Windows-Operation-Cli（agent-desktop に置き換え）の MCP 登録・本体・版マーカー・
# スキルを外す。無ければ何もしない。起動中は本体を消せないので本体だけ見送る。
function Remove-RetiredDevTools {
    param(
        [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\windows-operation-cli'),
        [string]$MarkerPath = (Join-Path $env:LOCALAPPDATA 'dotfiles\devtools\Windows-Operation-Cli.version'),
        [string]$SkillDir = (Join-Path $env:USERPROFILE '.claude\skills\windows-operation-cli')
    )

    $ErrorActionPreference = 'Stop'
    if (Test-Cmd claude) {
        $null = claude mcp get windows-operation-cli 2>&1
        if ($LASTEXITCODE -eq 0) {
            claude mcp remove --scope user windows-operation-cli
            Assert-NativeCommandSucceeded 'claude mcp remove windows-operation-cli'
            Write-Host 'Windows-Operation-Cli の MCP 登録を削除しました。' -ForegroundColor Yellow
        }
    }
    if (Test-Path -LiteralPath $InstallDir) {
        if (Get-Process -Name 'windows-operation-cli' -ErrorAction SilentlyContinue) {
            Write-Warning 'windows-operation-cli is running; close it to remove it.'
        }
        else {
            Remove-Item -LiteralPath $InstallDir -Recurse -Force
            Write-Host "Windows-Operation-Cli を削除しました: $InstallDir" -ForegroundColor Yellow
        }
    }
    if (Test-Path -LiteralPath $MarkerPath) { Remove-Item -LiteralPath $MarkerPath -Force }
    if (Test-Path -LiteralPath $SkillDir) {
        Remove-Item -LiteralPath $SkillDir -Recurse -Force
        Write-Host "Windows-Operation-Cli のスキルを削除しました: $SkillDir" -ForegroundColor Yellow
    }
}

# agent-desktop のスキルは CLI に内蔵されている（版と常に一致する）ので、それを
# スキル ディレクトリへ書き出す。CLI が無ければ何もしない。
function Sync-AgentDesktopSkill {
    param([string]$SkillsDir = (Join-Path $env:USERPROFILE '.claude\skills'))

    $ErrorActionPreference = 'Stop'
    if (-not (Test-Cmd agent-desktop)) { return }
    $json = agent-desktop skills get desktop
    Assert-NativeCommandSucceeded 'agent-desktop skills get desktop'
    $content = ($json | ConvertFrom-Json).data.content
    if (-not $content) { throw 'agent-desktop returned an empty skill.' }
    $path = Join-Path $SkillsDir 'agent-desktop\SKILL.md'
    if ((Test-Path -LiteralPath $path) -and (Test-DevToolTextEqual (Read-DevToolLocalText $path) $content)) { return }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    Set-Content -LiteralPath $path -Value $content -NoNewline -Encoding UTF8
    Write-Host "agent-desktop のスキルを配置しました: $path" -ForegroundColor Gray
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

    $ErrorActionPreference = 'Stop'
    if ($Yes) { $Force = $true }

    try { Disable-CodexStatusline }
    catch { Write-Warning "Disable-CodexStatusline failed: $($_.Exception.Message)" }
    try { Remove-RetiredDevTools }
    catch { Write-Warning "Remove-RetiredDevTools failed: $($_.Exception.Message)" }

    # 判定は winget/ネットワークを伴うため1回だけ行い、以降は結果を使い回す。
    $results = @()
    $installed = @{}
    foreach ($tool in $script:DevTools) {
        try { $installed[$tool.Name] = [bool](Test-ToolInstalled $tool) }
        catch {
            Write-Warning "$($tool.Name): installation status could not be checked; skipping. $($_.Exception.Message)"
            $results += [PSCustomObject]@{ Tool = $tool.Name; Action = 'Checking'; Result = 'FAILED' }
        }
    }
    $toInstall = @($script:DevTools | Where-Object { $installed.ContainsKey($_.Name) -and -not $installed[$_.Name] })
    $latestVersions = @{}
    $toUpdate = @(foreach ($tool in $script:DevTools) {
        if (-not $installed[$tool.Name] -or $tool.InstallOnly) { continue }
        try {
            if ($tool.Backend -eq 'claude-plugin') {
                $upToDate = Test-DevToolPluginUpToDate $tool
                if ($null -eq $upToDate) { Write-Warning "$($tool.Name): plugin version could not be checked; skipping update." }
                elseif (-not $upToDate) { $tool }
                continue
            }
            if ($tool.Backend -eq 'winget' -or $tool.Backend -eq 'msstore') {
                # winget 管理のものは Upgradable を付けたものだけ更新対象にする。
                if (-not $tool.Upgradable) { continue }
                if (-not (Test-DevToolWingetUpgradeAvailable $tool)) { continue }
            }
            elseif ($tool.Backend -ne 'script') { continue }
            elseif ($tool.Repo) {
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
            if (Test-DevToolProcessRunning $tool) {
                Write-Warning "$($tool.Name) is running; close it before updating."
                continue
            }
            $tool
        }
        catch {
            Write-Warning "$($tool.Name): update could not be checked; skipping. $($_.Exception.Message)"
            $results += [PSCustomObject]@{ Tool = $tool.Name; Action = 'Checking'; Result = 'FAILED' }
        }
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
        try { Sync-DevToolSkills }
        catch { Write-Warning "Sync-DevToolSkills failed: $($_.Exception.Message)" }
        try { Sync-AgentDesktopSkill }
        catch { Write-Warning "Sync-AgentDesktopSkill failed: $($_.Exception.Message)" }
        if ($results.Count -gt 0) {
            Write-Host "`nInstall summary:" -ForegroundColor Cyan
            $results | Format-Table -AutoSize
        }
        else { Write-Host 'All dev tools already installed.' -ForegroundColor Green }
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

    try { Sync-DevToolSkills }
    catch { Write-Warning "Sync-DevToolSkills failed: $($_.Exception.Message)" }

    $selfUpdates = @()
    foreach ($t in $pending) {
        $isUpdate = $toUpdate -contains $t
        # 実行中の pwsh 自身を更新すると MSI がこのセッションを閉じることがあるため、最後に回す。
        if ($isUpdate -and $t.SelfUpdate) { $selfUpdates += $t; continue }
        $action = if ($isUpdate) { 'Updating' } else { 'Installing' }
        Write-Host "$action $($t.Name)..." -ForegroundColor Green
        $ok = $false
        $rebootRequired = $false
        try {
            switch ($t.Backend) {
                'winget' {
                    if ($isUpdate) {
                        winget upgrade --id $t.Id --exact --source winget --accept-package-agreements --accept-source-agreements
                        Assert-DevToolWingetUpgraded $t $LASTEXITCODE
                    }
                    else {
                        winget install --id $t.Id --exact --source winget --accept-package-agreements --accept-source-agreements
                        # 導入済みと判定できなかったものは install が「更新なし」で返るので成功とみなす。
                        if ($LASTEXITCODE -eq -1978335189) { Write-Host '  Already installed.' -ForegroundColor Gray }
                        else { Assert-NativeCommandSucceeded "winget install $($t.Id)" }
                    }
                }
                'msstore' {
                    if ($isUpdate) {
                        winget upgrade --id $t.Id --source msstore --accept-package-agreements --accept-source-agreements
                        Assert-DevToolWingetUpgraded $t $LASTEXITCODE
                    }
                    else {
                        winget install --id $t.Id --source msstore --accept-package-agreements --accept-source-agreements
                        if ($LASTEXITCODE -eq -1978335189) { Write-Host '  Already installed.' -ForegroundColor Gray }
                        else { Assert-NativeCommandSucceeded "winget install $($t.Id)" }
                    }
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
                'npm' {
                    npm install -g $t.Id
                    Assert-NativeCommandSucceeded "npm install -g $($t.Id)"
                    $script:_cmdCache.Remove($t.Cmd)
                }
                'claude-plugin' {
                    $plugins = claude plugin list --json | ConvertFrom-Json
                    foreach ($old in $t.Replaces) {
                        if ($plugins | Where-Object { $_.id -eq $old }) {
                            claude plugin uninstall $old
                            Assert-NativeCommandSucceeded "claude plugin uninstall $old"
                        }
                    }
                    # マーケットプレイスは GitHub の main の ZIP を展開したフォルダで登録する。
                    # 旧版がクローン先のパスで登録していたら消して登録し直す。消すと plugin と設定値も
                    # 消えるため、設定値を控えて install に渡す。
                    $dir = Get-DevToolMarketplaceDir $t
                    $registered = claude plugin marketplace list --json | ConvertFrom-Json | Where-Object { $_.name -eq $t.Marketplace }
                    $config = @()
                    if ($registered -and $registered.path -ne $dir) {
                        $config = @(Get-DevToolPluginConfigArgs $t.Id)
                        claude plugin marketplace remove $t.Marketplace
                        Assert-NativeCommandSucceeded "claude plugin marketplace remove $($t.Marketplace)"
                        $registered = $null
                        $plugins = @()
                    }
                    Save-DevToolMarketplace $t
                    $current = $plugins | Where-Object { $_.id -eq $t.Id }
                    if ($current) {
                        # 統合などで中身が変わっていることがあるので、有効化の前に更新する。
                        claude plugin marketplace update $t.Marketplace
                        Assert-NativeCommandSucceeded "claude plugin marketplace update $($t.Marketplace)"
                        claude plugin update $t.Id
                        Assert-NativeCommandSucceeded "claude plugin update $($t.Id)"
                        # 有効な plugin に enable を呼ぶと claude は失敗を返すため、無効なときだけ呼ぶ。
                        if (-not $current.enabled) {
                            claude plugin enable $t.Id
                            Assert-NativeCommandSucceeded "claude plugin enable $($t.Id)"
                        }
                        break
                    }
                    if (-not $registered) {
                        claude plugin marketplace add $dir
                        Assert-NativeCommandSucceeded "claude plugin marketplace add $dir"
                    }
                    claude plugin install $t.Id @config
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
            # Post-install: delta -> configure git pager (with confirmation)
            if ($t.PostInstall -eq 'delta') {
                $cfg = if ($Force) { 'y' } else { Read-Host 'Configure git to use delta as pager? (y/N)' }
                if ($cfg -match '^(y|yes)$') {
                    git config --global core.pager delta
                    Assert-NativeCommandSucceeded 'git config --global core.pager delta'
                    git config --global interactive.diffFilter 'delta --color-only'
                    Assert-NativeCommandSucceeded 'git config --global interactive.diffFilter'
                    git config --global delta.navigate true
                    Assert-NativeCommandSucceeded 'git config --global delta.navigate true'
                    Write-Host '  git pager set to delta.' -ForegroundColor Gray
                }
            }
            $ok = $true
        }
        catch {
            Write-Warning "  Failed: $($_.Exception.Message)"
        }
        $result = if (-not $ok) { 'FAILED' } elseif ($rebootRequired) { 'RESTART REQUIRED' } else { 'OK' }
        $results += [PSCustomObject]@{ Tool = $t.Name; Action = $action; Result = $result }
    }

    try { refreshenv }
    catch { Write-Warning "refreshenv failed: $($_.Exception.Message)" }
    try { Sync-AgentDesktopSkill }
    catch { Write-Warning "Sync-AgentDesktopSkill failed: $($_.Exception.Message)" }
    # 別ウィンドウの winget で更新するので、このセッションが閉じられても他の処理は終わっている。
    foreach ($t in $selfUpdates) {
        $result = 'STARTED'
        try {
            Start-Process winget -ArgumentList 'upgrade', '--id', $t.Id, '--exact', '--source', 'winget', '--accept-package-agreements', '--accept-source-agreements'
            Write-Host "Updating $($t.Name) in a separate window. Restart the shell after it finishes." -ForegroundColor Yellow
        }
        catch {
            Write-Warning "$($t.Name): update could not be started. $($_.Exception.Message)"
            $result = 'FAILED'
        }
        $results += [PSCustomObject]@{ Tool = $t.Name; Action = 'Updating'; Result = $result }
    }
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

