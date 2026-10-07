# ---------------------------------------------------------------------------
# §0 Encoding & internal helpers
# ---------------------------------------------------------------------------

# Ensure UTF-8 in/out (avoid mojibake; consistent across machines)
try {
    [Console]::OutputEncoding = [Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
}
catch {}

# Remember the file that was actually loaded. This remains correct when the
# profile is dot-sourced from a synced or non-default location.
$script:DotfilesProfilePath = if ($PSCommandPath) { $PSCommandPath } else { $PROFILE.CurrentUserCurrentHost }

# Cached command-existence check used by feature guards
$script:_cmdCache = @{}
function Test-Cmd {
    param([Parameter(Mandatory)][string]$Name)
    if (-not $script:_cmdCache.ContainsKey($Name)) {
        $script:_cmdCache[$Name] = [bool](Get-Command $Name -ErrorAction Ignore)
    }
    $script:_cmdCache[$Name]
}

# Native commands signal failures through $LASTEXITCODE rather than PowerShell
# exceptions. Convert those failures into terminating errors for callers.
function Assert-NativeCommandSucceeded {
    param([Parameter(Mandatory)][string]$Command)

    if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code $LASTEXITCODE."
    }
}

# Cache a tool's shell-init output to a file and dot-source that instead of
# spawning the tool on every startup. Regenerates when the exe is newer.
function Get-InitCache {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][scriptblock]$Generator
    )
    $dir = Join-Path $env:LOCALAPPDATA 'pwsh-init-cache'
    $path = Join-Path $dir "$Name.ps1"
    $src = (Get-Command $Exe -ErrorAction Ignore).Source
    $stale = (-not (Test-Path -LiteralPath $path)) -or
    ($src -and (Get-Item -LiteralPath $src).LastWriteTime -gt (Get-Item -LiteralPath $path).LastWriteTime)
    if ($stale) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        (& $Generator) | Out-String | Set-Content -LiteralPath $path -Encoding utf8
    }
    $path
}

# ---------------------------------------------------------------------------
# §1 Aliases
# ---------------------------------------------------------------------------
# Let the profile's Git and bat functions take precedence over built-in aliases.
Remove-Item Alias:gl, Alias:gp, Alias:gcm, Alias:cat -Force -ErrorAction Ignore
Set-Alias cop   copilot
Set-Alias g     git
Set-Alias cx     codex
Set-Alias which Get-Command
Set-Alias cl    Clear-Host

# ---------------------------------------------------------------------------
# §2 Profile files: remote fetch and update
# ---------------------------------------------------------------------------
# dotfiles リポジトリ（public）の raw コンテンツ取得元。app-settings 配下の設定ファイルを
# クローンなしで取得するために使う。
$script:DotfilesRawBase = 'https://raw.githubusercontent.com/ntaksh42/dotfiles/main'

# remote-config バックエンド用: リポジトリ内のファイルを raw 経由で取得する（先頭の
# 管理用コメント行は StripCommentLines で除去できる）。
function Get-DotfilesRemoteConfig {
    param([Parameter(Mandatory)]$Tool)
    $uri = "$script:DotfilesRawBase/$($Tool.RepoPath)"
    try {
        $content = (Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop).Content
    }
    catch {
        throw "Failed to retrieve ${uri}: $($_.Exception.Message)"
    }
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "Retrieved empty content from $uri."
    }
    if ($Tool.StripCommentLines) {
        $lines = $content -split "`r?`n"
        $content = ($lines | Select-Object -Skip $Tool.StripCommentLines) -join "`n"
    }
    return $content
}

# remote-config バックエンド用: 既存ファイルとリモート内容の差分を表示する（git があれば
# `git diff --no-index` で色付き表示、なければ Compare-Object で簡易表示）。
function Show-DotfilesRemoteConfigDiff {
    param([Parameter(Mandatory)]$Tool, [Parameter(Mandatory)][string]$RemoteContent)
    if (Test-Cmd git) {
        $tmp = Join-Path $env:TEMP "dotfiles-remote-$([guid]::NewGuid().ToString('N')).tmp"
        try {
            Set-Content -LiteralPath $tmp -Value $RemoteContent -NoNewline -Encoding UTF8
            git --no-pager diff --no-index --color=always -- $Tool.Dest $tmp 2>$null
        }
        finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    else {
        Compare-Object (Get-Content -LiteralPath $Tool.Dest) ($RemoteContent -split "`r?`n") | ForEach-Object {
            $prefix = if ($_.SideIndicator -eq '<=') { '- (ローカル) ' } else { '+ (リポジトリ)' }
            "$prefix $($_.InputObject)"
        }
    }
}

# manifest.txt（1 行 1 ファイル、# 始まりはコメント）から profile.d 配下のファイル名を取り出す。
# 取得元は外部入力なので、ディレクトリ区切りを含む名前は受け付けない。
function Read-DotfilesManifest {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    foreach ($line in ($Text -split "`r?`n")) {
        $name = $line.Trim()
        if (-not $name -or $name.StartsWith('#')) { continue }
        if ($name -notmatch '^[A-Za-z0-9._-]+\.ps1$') { throw "manifest に不正なファイル名があります: $name" }
        $name
    }
}

# リポジトリ版のローダーと profile.d 一式のうち、ローカルと異なる（または未配置の）ものを返す。
# 全ファイルの取得・構文検証が終わるまで何も書き込まない。
function Get-DotfilesProfileUpdates {
    $profileDir = Split-Path -Parent $PROFILE.CurrentUserCurrentHost
    $repoDir = 'app-settings/pwsh'
    $manifest = Get-DotfilesRemoteConfig @{ RepoPath = "$repoDir/profile.d/manifest.txt" }
    $files = @(
        @{ Rel = 'Microsoft.PowerShell_profile.ps1' }
        @{ Rel = 'profile.d\manifest.txt'; Content = $manifest }
    )
    $files += foreach ($name in Read-DotfilesManifest $manifest) { @{ Rel = "profile.d\$name" } }

    foreach ($file in $files) {
        $tool = @{ RepoPath = "$repoDir/$($file.Rel -replace '\\', '/')"; Dest = Join-Path $profileDir $file.Rel }
        $content = if ($null -ne $file.Content) { $file.Content } else { Get-DotfilesRemoteConfig $tool }
        if ($file.Rel -like '*.ps1') {
            $tokens = $null; $parseErrors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$parseErrors)
            if ($parseErrors.Count -gt 0) { throw "取得した $($file.Rel) が不正な PowerShell のため更新を中断しました。" }
        }
        $exists = Test-Path -LiteralPath $tool.Dest -PathType Leaf
        if ($exists -and ((Get-Content -LiteralPath $tool.Dest -Raw) -ceq $content)) { continue }
        @{ Tool = $tool; Content = $content; Exists = $exists }
    }
}

# Get-DotfilesProfileUpdates の結果を書き込む。既存ファイルは .backup.<日時> に退避する。
function Write-DotfilesProfileUpdates {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Updates)
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    foreach ($update in $Updates) {
        $dest = $update.Tool.Dest
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        if ($update.Exists) {
            $backup = "$dest.backup.$timestamp"
            Copy-Item -LiteralPath $dest -Destination $backup -Force
            Write-Host "バックアップ: $backup" -ForegroundColor Gray
        }
        Set-Content -LiteralPath $dest -Value $update.Content -NoNewline -Encoding UTF8
    }
}

# リポジトリ版のプロファイル（ローダー + profile.d）をまとめて更新する。
# 全ファイルの取得・構文検証後に差分表示 -> 確認 -> バックアップ -> 上書き -> 再読込。
# 上書き先は $PROFILE（クローンから dot-source している場合に管理元ファイルを潰さないため）。
function Update-Profile {
    [CmdletBinding()]
    param([switch]$Force)

    $updates = @(Get-DotfilesProfileUpdates)
    if ($updates.Count -eq 0) {
        Write-Host 'Profile is up to date.' -ForegroundColor Green
        return
    }
    if (-not $Force) {
        foreach ($update in $updates) {
            Write-Host $update.Tool.Dest -ForegroundColor Cyan
            if ($update.Exists) {
                Show-DotfilesRemoteConfigDiff -Tool $update.Tool -RemoteContent $update.Content | Write-Host
            }
        }
        if ((Read-Host 'プロファイル一式を更新しますか? (y/N)') -notmatch '^(y|yes)$') { Write-Host 'Aborted.'; return }
    }
    Write-DotfilesProfileUpdates $updates
    Write-Host 'Profile updated. Reloading...' -ForegroundColor Green
    . $PROFILE.CurrentUserCurrentHost
}

# ---------------------------------------------------------------------------
# §3 Load profile.d (order is defined by profile.d/manifest.txt)
# ---------------------------------------------------------------------------
$script:DotfilesManifestPath = Join-Path (Split-Path -Parent $script:DotfilesProfilePath) 'profile.d\manifest.txt'
# profile.d を持たない環境（分割前のプロファイルからの移行、ローダーだけの新規環境）では、
# インストール済みの $PROFILE に限りリポジトリ版を取得して補う。
if (-not (Test-Path -LiteralPath $script:DotfilesManifestPath -PathType Leaf) -and
    $script:DotfilesProfilePath -eq $PROFILE.CurrentUserCurrentHost) {
    try {
        Write-DotfilesProfileUpdates @(Get-DotfilesProfileUpdates | Where-Object { -not $_.Exists })
        Write-Host "profile.d を取得しました: $(Split-Path -Parent $script:DotfilesManifestPath)" -ForegroundColor Green
    }
    catch {
        Write-Warning "profile.d の自動取得に失敗しました: $($_.Exception.Message)"
    }
}
# dot-source は呼び出しスコープに定義を残すため、関数に包まずここで直接読み込む。
if (Test-Path -LiteralPath $script:DotfilesManifestPath -PathType Leaf) {
    foreach ($dotfilesPart in Read-DotfilesManifest (Get-Content -LiteralPath $script:DotfilesManifestPath -Raw)) {
        $dotfilesPartPath = Join-Path (Split-Path -Parent $script:DotfilesManifestPath) $dotfilesPart
        if (Test-Path -LiteralPath $dotfilesPartPath -PathType Leaf) {
            . $dotfilesPartPath
        }
        else {
            Write-Warning "$dotfilesPart が見つかりません。Update-Profile または tools/Sync-AppSettings.ps1 でプロファイル一式を配置してください。"
        }
    }
    Remove-Variable dotfilesPart, dotfilesPartPath -ErrorAction Ignore
}
else {
    Write-Warning 'profile.d が見つかりません。Update-Profile または tools/Sync-AppSettings.ps1 でプロファイル一式を配置してください。'
}
