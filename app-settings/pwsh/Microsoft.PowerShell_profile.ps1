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
if (Test-Cmd zoxide) {
    Invoke-Expression (& { (zoxide init powershell | Out-String) })
}

# Starship: cross-shell prompt (best with a Nerd Font for glyphs)
if (Test-Cmd starship) {
    Invoke-Expression (&starship init powershell)
}

# bat: syntax-highlighted cat (bat outputs plain text when piped)
if (Test-Cmd bat) {
    function cat { bat @args }
}

# gsudo: sudo for Windows
if (Test-Cmd gsudo) {
    function sudo { gsudo @args }
}

# PSFzf: Ctrl+t (paths) / Alt+c (cd). Ctrl+r stays on the custom handler below.
if (Get-Module -ListAvailable -Name PSFzf) {
    Import-Module PSFzf
    try {
        Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordSetLocation 'Alt+c'
    } catch {
        Write-Warning "PSFzf binding failed: $($_.Exception.Message)"
    }
}

# Terminal-Icons: icons in directory listings
if (Get-Module -ListAvailable -Name Terminal-Icons) {
    Import-Module Terminal-Icons
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
    try { Invoke-Expression (& gh completion -s powershell | Out-String) } catch {}
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
    @{ Name='delta';             Backend='winget';   Id='dandavison.delta';      Cmd='delta'; PostInstall='delta' }
    @{ Name='gsudo';             Backend='winget';   Id='gerardog.gsudo';        Cmd='gsudo' }
    @{ Name='lazygit';           Backend='winget';   Id='JesseDuffield.lazygit'; Cmd='lazygit' }
    @{ Name='PSFzf';             Backend='psmodule'; Id='PSFzf' }
    @{ Name='Terminal-Icons';    Backend='psmodule'; Id='Terminal-Icons' }
    @{ Name='gita';              Backend='pip';      Id='gita';                  Cmd='gita' }
    @{ Name='git';               Backend='winget';   Id='Git.Git';               Cmd='git' }
    @{ Name='gh';                Backend='winget';   Id='GitHub.cli';            Cmd='gh' }
    @{ Name='fzf';               Backend='winget';   Id='junegunn.fzf';          Cmd='fzf' }
)

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
                    if (-not (Test-Cmd python) -and -not (Test-Cmd pip)) { throw 'Python/pip not found' }
                    pip install --user $t.Id
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
