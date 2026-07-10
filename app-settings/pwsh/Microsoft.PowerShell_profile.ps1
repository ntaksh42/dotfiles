# Microsoft.PowerShell_profile.ps1 - PowerShell 7
# 全部入りプロファイル: 日常コマンド + 環境構築補助
# 仕様: docs/superpowers/specs/2026-06-17-powershell-profile-enhancement-design.md

# ---------------------------------------------------------------------------
# §0 Encoding & internal helpers
# ---------------------------------------------------------------------------

# Ensure UTF-8 in/out (avoid mojibake; consistent across machines)
try {
    [Console]::OutputEncoding = [Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
} catch {}

# Cached command-existence check used by feature guards
$script:_cmdCache = @{}
function Test-Cmd {
    param([Parameter(Mandatory)][string]$Name)
    if (-not $script:_cmdCache.ContainsKey($Name)) {
        $script:_cmdCache[$Name] = [bool](Get-Command $Name -ErrorAction Ignore)
    }
    $script:_cmdCache[$Name]
}

# Cache a tool's shell-init output to a file and dot-source that instead of
# spawning the tool on every startup. Regenerates when the exe is newer.
function Get-InitCache {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][scriptblock]$Generator
    )
    $dir   = Join-Path $env:LOCALAPPDATA 'pwsh-init-cache'
    $path  = Join-Path $dir "$Name.ps1"
    $src   = (Get-Command $Exe -ErrorAction Ignore).Source
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
Set-Alias cc    claude
Set-Alias cop   copilot
Set-Alias g     git
Set-Alias which Get-Command

# ---------------------------------------------------------------------------
# §2 Navigation & file operations
# ---------------------------------------------------------------------------

# Create directory and move into it
function mkcd {
    param(
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$Path
    )
    New-Item -ItemType Directory -Force -Path $Path -ErrorAction Stop | Out-Null
    Set-Location $Path -ErrorAction Stop
}

# Display file/directory size
function size {
    param([string]$Path = ".")
    Get-ChildItem $Path |
        ForEach-Object {
            $bytes = if ($_.PSIsContainer) {
                (Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue |
                 Measure-Object -Property Length -Sum).Sum ?? 0
            } else { $_.Length }
            [PSCustomObject]@{ Name = $_.Name; Size = [math]::Round($bytes / 1MB, 2) }
        } | Sort-Object Size -Descending | Format-Table -AutoSize
}

# Go up directories
function ..   { Set-Location .. }
function ...  { Set-Location ..\.. }
function .... { Set-Location ..\..\.. }

# Go up N directory levels (default 1)
function up {
    param([int]$Levels = 1)
    if ($Levels -lt 1) { $Levels = 1 }
    Set-Location (('..\' * $Levels).TrimEnd('\'))
}

# Jump to source\repos
function repos { Set-Location (Join-Path $env:USERPROFILE 'source\repos') }

# Listing: eza when available, else Get-ChildItem
if (Test-Cmd eza) {
    function ll { eza -lh  --git --icons --group-directories-first @args }
    function la { eza -lah --git --icons --group-directories-first @args }
    function lt { eza --tree --level=2 --icons @args }
} else {
    function ll { Get-ChildItem @args }
    function la { Get-ChildItem -Force @args }
    function lt { Get-ChildItem -Recurse -Depth 1 @args }
}

# Fuzzy find a file and open it (fd + fzf)
function ff {
    if (-not (Test-Cmd fzf)) { Write-Warning 'ff needs fzf'; return }
    $sel = if (Test-Cmd fd) { & fd --type f | fzf }
           else { Get-ChildItem -Recurse -File | Select-Object -ExpandProperty FullName | fzf }
    if ($sel) { Invoke-Item $sel }
}

# Fuzzy find a directory and cd into it (fd + fzf)
function fcd {
    if (-not (Test-Cmd fzf)) { Write-Warning 'fcd needs fzf'; return }
    $sel = if (Test-Cmd fd) { & fd --type d | fzf }
           else { Get-ChildItem -Recurse -Directory | Select-Object -ExpandProperty FullName | fzf }
    if ($sel) { Set-Location $sel }
}

# touch: create file or update timestamp
function touch {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path $Path) { (Get-Item $Path).LastWriteTime = Get-Date }
    else { New-Item -ItemType File -Path $Path | Out-Null }
}

# Copy a file to <name>.bak-YYYYMMDD-HHmmss alongside it (snapshot before edits)
function backup-file {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Write-Warning "Not a file: $Path"; return }
    $item = Get-Item -LiteralPath $Path
    $dest = Join-Path $item.DirectoryName ('{0}.bak-{1}' -f $item.Name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item -LiteralPath $item.FullName -Destination $dest
    Write-Host "Backed up -> $dest" -ForegroundColor Green
}

# Reload this profile
function reload { . $PROFILE }

# Edit this profile (VS Code if present, else Notepad)
function Edit-Profile {
    if (Test-Cmd code) { code $PROFILE } else { notepad $PROFILE }
}
Set-Alias profile Edit-Profile

# ---------------------------------------------------------------------------
# §3 Git / GitHub
# ---------------------------------------------------------------------------

# Show git status in short format
function gs { git status -sb @args }

# Show git log with graph
function gl { git log --oneline --graph --decorate -20 @args }

# Undo last git commit (return to staging)
function git-undo { git reset --soft HEAD~1 }

function ga  { git add @args }
function gaa { git add -A @args }
function gb  { git branch @args }
function gd  { git diff @args }
function gds { git diff --staged @args }
function gp  { git push @args }
function gpl { git pull @args }
function gf  { git fetch --all --prune @args }

# Commit with a message (message required)
function gcm {
    if ($args.Count -eq 0) { Write-Warning 'usage: gcm <message>'; return }
    git commit -m "$args"
}

# Checkout; no arg -> fzf branch picker
function gco {
    if ($args.Count -gt 0) { git checkout @args; return }
    if (-not (Test-Cmd fzf)) { Write-Warning 'usage: gco <branch> (fzf not found for interactive pick)'; return }
    $branch = git branch --all --format='%(refname:short)' | Sort-Object -Unique | fzf
    if ($branch) { git checkout ($branch.Trim() -replace '^origin/', '') }
}

# lazygit TUI
if (Test-Cmd lazygit) { function lg { lazygit @args } }

# gh helpers
if (Test-Cmd gh) {
    function prc { gh pr create @args }
    function prv { gh pr view --web @args }
    function prl { gh pr list @args }
    function prs { gh pr status @args }
}

# cd to the git repository root
function groot {
    $root = git rev-parse --show-toplevel 2>$null
    if ($root) { Set-Location $root } else { Write-Warning 'Not a git repository' }
}

# Clone a repo and cd into it
function gclone {
    param([Parameter(Mandatory)][string]$Url)
    git clone $Url
    if ($LASTEXITCODE -eq 0) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension(($Url.TrimEnd('/')))
        if ($name -and (Test-Path $name)) { Set-Location $name }
    }
}

# Interactively browse commits (fzf list + diff preview via delta when available)
function glog {
    if (-not (Test-Cmd fzf)) { Write-Warning 'glog needs fzf'; return }
    $preview = if (Test-Cmd delta) { 'git show --color=always {1} | delta' }
               else { 'git show --color=always {1}' }
    git log --color=always --format='%C(auto)%h %s %C(dim)%an, %ar' @args |
        fzf --ansi --no-sort --reverse --preview $preview
}

# gita wrapper: clean each repo's stray "nul" file, then pull every repo.
# A repo whose current branch has no origin upstream is switched to -Fallback first.
function clean-pull-all {
    [CmdletBinding()]
    param([string]$Fallback = 'main')

    if (-not (Test-Cmd gita)) { Write-Warning 'clean-pull-all needs gita (gita add <path> to register repos)'; return }

    $names = @(((gita ls) -join ' ') -split '\s+' | Where-Object { $_ })
    if ($names.Count -eq 0) { Write-Warning 'No repos registered in gita (use: gita add <path>)'; return }

    foreach ($name in $names) {
        $repo = (gita ls $name).Trim()
        Write-Host "[$name] " -ForegroundColor Cyan -NoNewline
        if (-not $repo -or -not (Test-Path -LiteralPath $repo)) { Write-Warning "path not found: $repo"; continue }
        Write-Host $repo -ForegroundColor DarkGray

        # 1) Remove Windows-reserved "nul" files (block git checkout/pull on Windows).
        $stray = @(
            git -C $repo ls-files
            git -C $repo ls-files --others --exclude-standard
        ) | Where-Object { $_ -match '(^|/)nul$' } | Sort-Object -Unique
        foreach ($rel in $stray) {
            $full = Join-Path $repo ($rel -replace '/', '\')
            Remove-Item -LiteralPath "\\?\$full" -Force -ErrorAction SilentlyContinue
            Write-Host "  removed stray file: $rel" -ForegroundColor Yellow
        }

        # 2) Fetch, then pull the current branch; fall back if it has no origin upstream.
        git -C $repo fetch --prune --quiet
        $branch = (git -C $repo rev-parse --abbrev-ref HEAD).Trim()
        git -C $repo rev-parse --verify --quiet "origin/$branch" *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  no origin/$branch -> switching to $Fallback" -ForegroundColor Yellow
            git -C $repo checkout $Fallback
            if ($LASTEXITCODE -ne 0) { Write-Warning "  checkout $Fallback failed"; continue }
        }
        git -C $repo pull --ff-only
    }
}

# fzf でブランチを選んで切替。ローカルに無ければ origin から作成して追跡。
function git-switch {
    if (-not (Test-Cmd fzf)) { Write-Warning 'git-switch needs fzf'; return }
    $sel = git branch --all --format='%(refname:short)' |
        Where-Object { $_ -and $_ -notmatch '/HEAD$' } |
        Sort-Object -Unique | fzf
    if (-not $sel) { return }
    $local = $sel.Trim() -replace '^origin/', ''
    git rev-parse --verify --quiet "refs/heads/$local" *> $null
    if ($LASTEXITCODE -eq 0) { git checkout $local }
    else { git checkout -b $local --track "origin/$local" }
}

# 現在ブランチへマージ済みのローカルブランチを一括削除 (保護ブランチは残す)。
function git-clean-branches {
    param([string[]]$Protected = @('main', 'master', 'develop'))
    $cur = (git rev-parse --abbrev-ref HEAD).Trim()
    $merged = @(git branch --merged |
        ForEach-Object { ($_ -replace '^[*+ ]+', '').Trim() } |
        Where-Object { $_ -and $_ -ne $cur -and $_ -notin $Protected })
    if ($merged.Count -eq 0) { Write-Host 'No merged branches to delete.' -ForegroundColor Green; return }
    Write-Host 'Merged branches to delete:' -ForegroundColor Cyan
    $merged | ForEach-Object { Write-Host "  $_" }
    if ((Read-Host 'Proceed? (y/N)') -notmatch '^(y|yes)$') { Write-Host 'Aborted.'; return }
    $merged | ForEach-Object { git branch -d $_ }
}

# このディレクトリと直下のサブディレクトリにある git リポジトリを gita に登録。
function gita-scan {
    param([string]$Path = '.')
    if (-not (Test-Cmd gita)) { Write-Warning 'gita-scan needs gita'; return }
    $root = (Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue).Path
    if (-not $root) { Write-Warning "Path not found: $Path"; return }

    $targets = @()
    if (Test-Path -LiteralPath (Join-Path $root '.git')) { $targets += $root }
    $targets += @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.git') } |
        Select-Object -ExpandProperty FullName)

    if ($targets.Count -eq 0) { Write-Host 'No git repos found (this dir and its direct subdirs).' -ForegroundColor Yellow; return }
    foreach ($t in $targets) { gita add $t }
    Write-Host "Registered $($targets.Count) repo(s) with gita." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# §4 Visual Studio / build (C#/C++)
# ---------------------------------------------------------------------------

# Locate latest VS install path via vswhere
function Get-VsInstallPath {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { return $null }
    (& $vswhere -latest -property installationPath 2>$null)
}

# Resolve devenv.exe of the latest VS
function Get-DevEnvPath {
    $vsPath = Get-VsInstallPath
    if (-not $vsPath) { return $null }
    $devenv = Join-Path $vsPath 'Common7\IDE\devenv.exe'
    if (Test-Path $devenv) { $devenv } else { $null }
}

# Enter VS Developer environment in the CURRENT session (on demand; slow)
function vsdev {
    $vsPath = Get-VsInstallPath
    if (-not $vsPath) { Write-Warning 'Visual Studio not found (vswhere)'; return }
    $dll = Join-Path $vsPath 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll'
    if (-not (Test-Path $dll)) { Write-Warning "DevShell module not found: $dll"; return }
    try {
        Import-Module $dll
        Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'
    } catch {
        Write-Warning "vsdev failed: $($_.Exception.Message)"
    }
}

# Find nearest *.sln walking up from current directory
function Find-Sln {
    $dir = (Get-Location).Path
    while ($dir) {
        $slns = Get-ChildItem -Path $dir -Filter *.sln -File -ErrorAction SilentlyContinue
        if ($slns) { return $slns }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return @()
}

# Open nearest solution in Visual Studio
function sln {
    $devenv = Get-DevEnvPath
    if (-not $devenv) { Write-Warning 'Visual Studio (devenv) not found'; return }
    $slns = Find-Sln
    if (-not $slns) { Write-Warning 'No .sln found upward from current directory'; return }
    $target = if ($slns.Count -eq 1) { $slns[0].FullName }
              elseif (Test-Cmd fzf) { $slns.FullName | fzf }
              else { $slns[0].FullName }
    if ($target) { Start-Process $devenv $target }
}

# Open a path (default: current dir) in Visual Studio
function vs {
    param([string]$Path = ".")
    $devenv = Get-DevEnvPath
    if (-not $devenv) { Write-Warning 'Visual Studio (devenv) not found'; return }
    Start-Process $devenv (Resolve-Path $Path).Path
}

# dotnet / msbuild shortcuts
function db  { dotnet build @args }
function dr  { dotnet run @args }
function dt  { dotnet test @args }
function msb { msbuild @args }

# ---------------------------------------------------------------------------
# §5 Tool integrations (all guarded)
# ---------------------------------------------------------------------------

# zoxide: smart cd (z / zi)
# --hook pwd: hook Set-Location instead of prompt, so starship (which
# overwrites prompt below) doesn't clobber the directory-tracking hook.
if (Test-Cmd zoxide) {
    . (Get-InitCache 'zoxide' 'zoxide' { zoxide init --hook pwd powershell })
}

# Starship: cross-shell prompt (best with a Nerd Font for glyphs)
if (Test-Cmd starship) {
    . (Get-InitCache 'starship' 'starship' { starship init powershell })
}

# bat: syntax-highlighted cat (bat outputs plain text when piped)
if (Test-Cmd bat) {
    function cat { bat @args }
}

# gsudo: sudo for Windows
if (Test-Cmd gsudo) {
    function sudo { gsudo @args }
}

# Defer heavy modules (PSFzf + Terminal-Icons, ~2s combined) to the first idle
# tick so the prompt appears immediately; they load once shortly after startup.
$global:_deferDone = $false
$null = Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -Action {
    if ($global:_deferDone) { return }
    $global:_deferDone = $true
    if (Get-Module -ListAvailable -Name PSFzf) {
        try {
            Import-Module PSFzf
            Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordSetLocation 'Alt+c'
            # PSFzf grabs Ctrl+r on import; re-assert the custom fzf history handler.
            if (Get-Command fzf -ErrorAction Ignore) {
                Set-PSReadLineKeyHandler -Key Ctrl+r -ScriptBlock { Invoke-FzfHistory }
            }
        } catch {}
    }
    if (Get-Module -ListAvailable -Name Terminal-Icons) {
        Import-Module Terminal-Icons
    }
}

# Native tab completion (verified snippets), each guarded on command presence
if (Test-Cmd dotnet) {
    Register-ArgumentCompleter -Native -CommandName dotnet -ScriptBlock {
        param($commandName, $wordToComplete, $cursorPosition)
        dotnet complete --position $cursorPosition "$wordToComplete" | ForEach-Object {
            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
        }
    }
}

if (Test-Cmd gh) {
    . (Get-InitCache 'gh' 'gh' { gh completion -s powershell })
}

if (Test-Cmd winget) {
    Register-ArgumentCompleter -Native -CommandName winget -ScriptBlock {
        param($wordToComplete, $commandAst, $cursorPosition)
        [Console]::InputEncoding = [Console]::OutputEncoding = $OutputEncoding = [System.Text.Utf8Encoding]::new()
        $word = $wordToComplete.Replace('"', '""')
        $ast  = $commandAst.ToString().Replace('"', '""')
        winget complete --word="$word" --commandline "$ast" --position $cursorPosition | ForEach-Object {
            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
        }
    }
}

# Reload PATH from Machine + User scope (use after installs; no shell restart)
function refreshenv {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = ($machine, $user | Where-Object { $_ }) -join ';'
    Write-Host 'PATH refreshed.' -ForegroundColor Green
}
Set-Alias Update-SessionPath refreshenv

# Clipboard shortcuts
function clip  { $input | Set-Clipboard }
function paste { Get-Clipboard }

# Show public IP address
function myip { (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 5).ip }

# Show what's listening on a TCP port
function port {
    param([Parameter(Mandatory)][int]$Port)
    Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue |
        Select-Object LocalAddress, LocalPort, State, OwningProcess,
            @{ n='Process'; e={ (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName } }
}

# Kill the process(es) listening on a TCP port
function killport {
    param([Parameter(Mandatory)][int]$Port)
    $conns = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
    if (-not $conns) { Write-Warning "Nothing listening on port $Port"; return }
    $conns.OwningProcess | Sort-Object -Unique | ForEach-Object {
        Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
        Write-Host "Killed PID $_ on port $Port" -ForegroundColor Yellow
    }
}

# 司令塔/実行を分離して claude 起動: 立案・俯瞰は上位モデル、実行はサブエージェント
function script:Invoke-ClaudeOrchest {
    param(
        [Parameter(Mandatory)][string]$MainModel,
        [Parameter(Mandatory)][string]$SubagentModel,
        [object[]]$Rest
    )
    $orchestPrompt = @'
あなたは司令塔として俯瞰・立案・検証を担い、実行はサブエージェントに委譲する。

- 実装・修正の委譲先には implementer サブエージェントを使う（報告形式と作法が定義済み）。
- 委譲プロンプトは自己完結させる: 対象ファイル、背景、期待結果、完了条件、報告形式（変更差分と検証結果のみ簡潔に）を必ず含める。サブエージェントは会話履歴を参照できない。
- 独立したタスクは 1 メッセージで並列に委譲する。
- 成果物を受領したら evaluator サブエージェントに変更差分と完了条件を渡して検証させる。不合格なら修正点を具体化して implementer に再委譲する。最終判断は evaluator の報告を確認して自分で行う。
- 例外: 2〜3 ステップで終わる小さな作業、設計判断、あいまいな要件の解釈は委譲せず自分で行う。
'@
    $prev = $env:CLAUDE_CODE_SUBAGENT_MODEL
    $env:CLAUDE_CODE_SUBAGENT_MODEL = $SubagentModel
    try {
        claude --model $MainModel --append-system-prompt $orchestPrompt @Rest
    } finally {
        if ($null -ne $prev) { $env:CLAUDE_CODE_SUBAGENT_MODEL = $prev }
        else { Remove-Item Env:CLAUDE_CODE_SUBAGENT_MODEL -ErrorAction Ignore }
    }
}
function fable-orchest      { Invoke-ClaudeOrchest 'claude-fable-5'  'claude-sonnet-5' $args }
function fable-orchest-opus { Invoke-ClaudeOrchest 'claude-fable-5'  'claude-opus-4-8' $args }
function opus-orchest       { Invoke-ClaudeOrchest 'claude-opus-4-8' 'claude-sonnet-5' $args }
function fable-orchest-plan { Invoke-ClaudeOrchest 'claude-fable-5'  'claude-sonnet-5' (@('--permission-mode', 'plan') + $args) }
Set-Alias ccf  fable-orchest
Set-Alias ccfo fable-orchest-opus
Set-Alias cco  opus-orchest
Set-Alias ccfp fable-orchest-plan

# ---------------------------------------------------------------------------
# §6 Environment setup helpers
# ---------------------------------------------------------------------------

# Tool catalog (data-driven). Backend: winget | msstore | pip | psmodule
$script:DevTools = @(
    @{ Name='Files';             Backend='winget';   Id='FilesCommunity.Files' }
    @{ Name='Everything';        Backend='winget';   Id='voidtools.Everything' }
    @{ Name='EverythingToolbar'; Backend='winget';   Id='stnkl.EverythingToolbar' }
    @{ Name='PC Manager';        Backend='msstore';  Id='9PM860492SZD' }
    @{ Name='Flow Launcher';     Backend='winget';   Id='Flow-Launcher.Flow-Launcher' }
    @{ Name='starship';          Backend='winget';   Id='Starship.Starship';     Cmd='starship' }
    @{ Name='zoxide';            Backend='winget';   Id='ajeetdsouza.zoxide';   Cmd='zoxide' }
    @{ Name='eza';               Backend='winget';   Id='eza-community.eza';     Cmd='eza' }
    @{ Name='bat';               Backend='winget';   Id='sharkdp.bat';           Cmd='bat' }
    @{ Name='fd';                Backend='winget';   Id='sharkdp.fd';            Cmd='fd' }
    @{ Name='ripgrep';           Backend='winget';   Id='BurntSushi.ripgrep.MSVC'; Cmd='rg' }
    @{ Name='jq';                Backend='winget';   Id='jqlang.jq';             Cmd='jq' }
    @{ Name='delta';             Backend='winget';   Id='dandavison.delta';      Cmd='delta'; PostInstall='delta' }
    @{ Name='gsudo';             Backend='winget';   Id='gerardog.gsudo';        Cmd='gsudo' }
    @{ Name='lazygit';           Backend='winget';   Id='JesseDuffield.lazygit'; Cmd='lazygit' }
    @{ Name='Zed';               Backend='winget';   Id='ZedIndustries.Zed';     Cmd='zed' }
    @{ Name='PSFzf';             Backend='psmodule'; Id='PSFzf' }
    @{ Name='Terminal-Icons';    Backend='psmodule'; Id='Terminal-Icons' }
    @{ Name='gita';              Backend='pip';      Id='gita';                  Cmd='gita' }
    @{ Name='git';               Backend='winget';   Id='Git.Git';               Cmd='git' }
    @{ Name='gh';                Backend='winget';   Id='GitHub.cli';            Cmd='gh' }
    @{ Name='fzf';               Backend='winget';   Id='junegunn.fzf';          Cmd='fzf' }
)

# Ensure Python/pip is available; install via winget if missing. Returns $true on success.
function Install-PythonIfMissing {
    if ((Test-Cmd python) -or (Test-Cmd pip)) { return $true }
    Write-Host 'Python/pip not found; installing Python via winget...' -ForegroundColor Green
    winget install --id Python.Python.3.12 --exact --source winget --accept-package-agreements --accept-source-agreements
    refreshenv
    $script:_cmdCache.Remove('python'); $script:_cmdCache.Remove('pip')
    if ((Test-Cmd python) -or (Test-Cmd pip)) { return $true }
    Write-Warning 'Python install ran but python/pip is still not on PATH (a new shell may be required).'
    return $false
}

# Detect whether a catalog tool is installed
function Test-ToolInstalled {
    param([Parameter(Mandatory)]$Tool)
    switch ($Tool.Backend) {
        'psmodule' { return [bool](Get-Module -ListAvailable -Name $Tool.Id) }
        'pip'      { return (Test-Cmd $Tool.Cmd) }
        default {
            if ($Tool.Cmd -and (Test-Cmd $Tool.Cmd)) { return $true }
            $listed = winget list --id $Tool.Id --exact 2>$null | Select-String -SimpleMatch $Tool.Id
            return [bool]$listed
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

# Install all missing catalog tools (idempotent; confirm unless -Force)
function Install-DevTools {
    [CmdletBinding()]
    param([switch]$Force)

    $pending = @($script:DevTools | Where-Object { -not (Test-ToolInstalled $_) })
    if ($pending.Count -eq 0) { Write-Host 'All dev tools already installed.' -ForegroundColor Green; return }

    Write-Host 'The following tools will be installed:' -ForegroundColor Cyan
    $pending | ForEach-Object { Write-Host "  - $($_.Name) [$($_.Backend)] $($_.Id)" }
    if (-not $Force) {
        $ans = Read-Host 'Proceed? (y/N)'
        if ($ans -notmatch '^(y|yes)$') { Write-Host 'Aborted.'; return }
    }

    $results = @()
    foreach ($t in $pending) {
        Write-Host "Installing $($t.Name)..." -ForegroundColor Green
        $ok = $false
        try {
            switch ($t.Backend) {
                'winget'   { winget install --id $t.Id --exact --source winget --accept-package-agreements --accept-source-agreements }
                'msstore'  { winget install --id $t.Id --source msstore --accept-package-agreements --accept-source-agreements }
                'pip'      {
                    if (-not (Install-PythonIfMissing)) { throw 'Python/pip not found and could not be installed' }
                    if (Test-Cmd pip) { pip install --user $t.Id }
                    else { python -m pip install --user $t.Id }
                }
                'psmodule' { Install-Module $t.Id -Scope CurrentUser -Force -AcceptLicense }
            }
            $ok = $true
        } catch {
            Write-Warning "  Failed: $($_.Exception.Message)"
        }
        $results += [PSCustomObject]@{ Tool = $t.Name; Result = if ($ok) { 'OK' } else { 'FAILED' } }

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

# ---------------------------------------------------------------------------
# §7 PSReadLine - prediction and key bindings
# ---------------------------------------------------------------------------

# Interactive history search with delete support (Ctrl+r replacement)
# Usage: Ctrl+r to search, Del to delete selected entry and re-open
function Invoke-FzfHistory {
    $histFile = Join-Path $env:APPDATA 'Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt'
    if (-not (Test-Path $histFile)) { return }

    while ($true) {
        $selected = Get-Content $histFile |
            Where-Object { $_ -ne '' } |
            Select-Object -Unique |
            & fzf --scheme=history --no-sort --tac `
                  --prompt 'history> ' `
                  --expect 'del'

        # $selected[0] = 押されたキー、$selected[1] = 選択した行
        if (-not $selected) { return }

        $key  = $selected[0]
        $line = $selected[1]

        if ($key -eq 'del' -and $line) {
            $content = Get-Content $histFile
            $content | Where-Object { $_ -ne $line } | Set-Content $histFile
            # ループして再表示
        } elseif ($line) {
            [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt()
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert($line)
            return
        } else {
            return
        }
    }
}

if ($host.Name -eq 'ConsoleHost') {
    Import-Module PSReadLine

    Set-PSReadLineOption -PredictionSource History
    Set-PSReadLineOption -PredictionViewStyle ListView
    Set-PSReadLineOption -EditMode Windows
    Set-PSReadLineOption -HistorySearchCursorMovesToEnd
    Set-PSReadLineOption -HistoryNoDuplicates
    Set-PSReadLineOption -MaximumHistoryCount 10000

    Set-PSReadLineKeyHandler -Key UpArrow   -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
    Set-PSReadLineKeyHandler -Key Ctrl+d    -Function DeleteCharOrExit
    Set-PSReadLineKeyHandler -Key Tab       -Function MenuComplete
    Set-PSReadLineKeyHandler -Key Alt+a     -Function SelectCommandArgument

    # Smart auto-closing brackets / quotes (adapted from the PSReadLine sample profile)
    Set-PSReadLineKeyHandler -Key '(','{','[' -BriefDescription InsertPairedBraces -ScriptBlock {
        param($key, $arg)
        $close = @{ '(' = ')'; '{' = '}'; '[' = ']' }[[string]$key.KeyChar]
        $line = $null; $cursor = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        $selStart = $null; $selLen = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::GetSelectionState([ref]$selStart, [ref]$selLen)
        if ($selLen -ne -1) {
            [Microsoft.PowerShell.PSConsoleReadLine]::Replace($selStart, $selLen, "$($key.KeyChar)" + $line.Substring($selStart, $selLen) + $close)
            [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($selStart + $selLen + 2)
        } else {
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert("$($key.KeyChar)$close")
            [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($cursor + 1)
        }
    }

    Set-PSReadLineKeyHandler -Key ')',']','}' -BriefDescription SmartCloseBraces -ScriptBlock {
        param($key, $arg)
        $line = $null; $cursor = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        if ($cursor -lt $line.Length -and $line[$cursor] -eq $key.KeyChar) {
            [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($cursor + 1)
        } else {
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert("$($key.KeyChar)")
        }
    }

    Set-PSReadLineKeyHandler -Key '"',"'" -BriefDescription SmartInsertQuote -ScriptBlock {
        param($key, $arg)
        $quote = $key.KeyChar
        $line = $null; $cursor = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        if ($cursor -lt $line.Length -and $line[$cursor] -eq $quote) {
            [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($cursor + 1)
        } else {
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert("$quote$quote")
            [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($cursor + 1)
        }
    }

    # fzf history search (registered last so PSFzf doesn't override Ctrl+r)
    if (Test-Cmd fzf) {
        Set-PSReadLineKeyHandler -Key Ctrl+r -ScriptBlock { Invoke-FzfHistory }
    }
}

# ---------------------------------------------------------------------------
# §8 Help - list the commands this profile provides
# ---------------------------------------------------------------------------

# Catalog of commands defined above (data-driven; keep in sync when adding commands)
$script:ProfileHelp = [ordered]@{
    'Navigation & files' = @(
        @{ Cmd='mkcd <path>';      Desc='ディレクトリを作成して移動' }
        @{ Cmd='size [path]';      Desc='ファイル/フォルダのサイズ一覧 (MB, 降順)' }
        @{ Cmd='.. / ... / ....';  Desc='1/2/3 階層上へ移動' }
        @{ Cmd='up [n]';           Desc='n 階層上へ移動 (既定 1)' }
        @{ Cmd='repos';            Desc='~/source/repos へジャンプ' }
        @{ Cmd='ll / la / lt';     Desc='一覧表示 (eza があればアイコン/git 付き)' }
        @{ Cmd='ff';               Desc='fzf でファイルを絞り込んで開く' }
        @{ Cmd='fcd';              Desc='fzf でディレクトリを絞り込んで cd' }
        @{ Cmd='touch <path>';     Desc='ファイル作成 / タイムスタンプ更新' }
        @{ Cmd='backup-file <f>';  Desc='<名前>.bak-日時 でバックアップ作成' }
        @{ Cmd='reload';           Desc='プロファイルを再読込' }
        @{ Cmd='profile';          Desc='プロファイルを編集 (code/notepad)' }
    )
    'Git / GitHub' = @(
        @{ Cmd='gs';               Desc='git status -sb' }
        @{ Cmd='gl';               Desc='git log をグラフ表示 (直近 20)' }
        @{ Cmd='git-undo';         Desc='直前コミットを取り消し (staging へ戻す)' }
        @{ Cmd='ga / gaa';         Desc='git add / git add -A' }
        @{ Cmd='gb';               Desc='git branch' }
        @{ Cmd='gd / gds';         Desc='git diff / git diff --staged' }
        @{ Cmd='gp / gpl / gf';    Desc='git push / pull / fetch --all --prune' }
        @{ Cmd='gcm <msg>';        Desc='git commit -m' }
        @{ Cmd='gco [branch]';     Desc='checkout (引数なしは fzf で選択)' }
        @{ Cmd='lg';               Desc='lazygit (あれば)' }
        @{ Cmd='prc/prv/prl/prs';  Desc='gh pr create/view/list/status (あれば)' }
        @{ Cmd='groot';            Desc='リポジトリのルートへ cd' }
        @{ Cmd='gclone <url>';     Desc='clone して cd' }
        @{ Cmd='glog';             Desc='fzf でコミット閲覧 (delta プレビュー)' }
        @{ Cmd='clean-pull-all';   Desc='gita 全リポジトリを掃除して pull (-Fallback で切替先指定)' }
        @{ Cmd='git-switch';       Desc='fzf でブランチ切替 (無ければ origin から作成)' }
        @{ Cmd='git-clean-branches'; Desc='マージ済みローカルブランチを一括削除' }
        @{ Cmd='gita-scan [path]'; Desc='直下の git リポジトリを gita に一括登録' }
    )
    'Visual Studio / build' = @(
        @{ Cmd='vsdev';            Desc='現セッションを VS Developer 環境化' }
        @{ Cmd='sln';              Desc='最寄りの .sln を VS で開く' }
        @{ Cmd='vs [path]';        Desc='指定パスを VS で開く' }
        @{ Cmd='db / dr / dt';     Desc='dotnet build / run / test' }
        @{ Cmd='msb';              Desc='msbuild' }
    )
    'Tools & system' = @(
        @{ Cmd='cat <file>';       Desc='bat 連携 (あれば)' }
        @{ Cmd='sudo <cmd>';       Desc='gsudo 連携 (あれば)' }
        @{ Cmd='z / zi';           Desc='zoxide スマート cd (あれば)' }
        @{ Cmd='refreshenv';       Desc='PATH を再読込 (インストール後に)' }
        @{ Cmd='clip / paste';     Desc='クリップボードへ書込 / 読出' }
        @{ Cmd='myip';             Desc='公開 IP アドレスを表示' }
        @{ Cmd='port <n>';         Desc='ポートを使用中のプロセスを表示' }
        @{ Cmd='killport <n>';     Desc='ポートを使用中のプロセスを強制終了' }
        @{ Cmd='fable-orchest / ccf'; Desc='Fable が立案・Sonnet 5 が実行の構成で claude 起動' }
        @{ Cmd='fable-orchest-opus / ccfo'; Desc='Fable が立案・Opus 4.8 が実行の構成で claude 起動' }
        @{ Cmd='opus-orchest / cco'; Desc='Opus 4.8 が立案・Sonnet 5 が実行の構成で claude 起動' }
        @{ Cmd='fable-orchest-plan / ccfp'; Desc='ccf を plan モードで起動（立案を承認してから実行）' }
    )
    'Dev environment' = @(
        @{ Cmd='Show-DevEnv';      Desc='開発ツールの導入状況を一覧' }
        @{ Cmd='Install-DevTools'; Desc='未導入ツールを一括インストール' }
        @{ Cmd='Update-DevTools';  Desc='winget/PS モジュールを更新' }
    )
    'Aliases' = @(
        @{ Cmd='cc / cop';         Desc='claude / copilot' }
        @{ Cmd='g';                Desc='git' }
        @{ Cmd='which';            Desc='Get-Command' }
    )
}

# Show the commands this profile provides. Optional keyword filters cmd/desc/section.
function Show-ProfileHelp {
    param([string]$Filter)

    foreach ($section in $script:ProfileHelp.Keys) {
        $items = $script:ProfileHelp[$section]
        if ($Filter) {
            $items = @($items | Where-Object {
                $_.Cmd -like "*$Filter*" -or $_.Desc -like "*$Filter*" -or $section -like "*$Filter*"
            })
        }
        if (-not $items) { continue }

        Write-Host ''
        Write-Host "[$section]" -ForegroundColor Cyan
        foreach ($i in $items) {
            Write-Host ('  {0,-22}' -f $i.Cmd) -ForegroundColor Yellow -NoNewline
            Write-Host $i.Desc -ForegroundColor Gray
        }
    }
    Write-Host ''
    Write-Host "tip: 'phelp <keyword>' で絞り込み (例: phelp git)" -ForegroundColor DarkGray
}
Set-Alias phelp Show-ProfileHelp
