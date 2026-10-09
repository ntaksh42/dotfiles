$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# §7 Environment setup helpers
# ---------------------------------------------------------------------------

# Tool catalog (data-driven). Backend: winget | msstore | pip | psmodule | script | remote-config
$script:DevTools = @(
    @{ Name = 'Files'; Backend = 'winget'; Id = 'FilesCommunity.Files' }
    @{ Name = 'Everything'; Backend = 'winget'; Id = 'voidtools.Everything' }
    @{ Name = 'Orca'; Backend = 'winget'; Id = 'StablyAI.Orca' }
    @{ Name = 'PC Manager'; Backend = 'msstore'; Id = '9PM860492SZD' }
    @{ Name = 'PowerToys'; Backend = 'winget'; Id = 'Microsoft.PowerToys' }
    # 既存の設定を上書きしないよう、レイアウトが未作成（custom-layouts.json なし）の環境にだけ一度配置する。
    @{ Name = 'PowerToys settings'; Backend = 'script'; Id = "$script:DotfilesRawBase/tools/Install-PowerToysSettings.ps1"; Path = (Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys\FancyZones\custom-layouts.json'); InstallOnly = $true }
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
    @{ Name = 'ado-link-bar (mod)'; Backend = 'claude-plugin'; Id = 'ado-link-bar@dotfiles-mods'; Marketplace = 'dotfiles-mods'; MarketplaceSource = 'ntaksh42/dotfiles'; RequiredCommand = 'claude' }
    @{ Name = 'toast-notify (mod)'; Backend = 'claude-plugin'; Id = 'toast-notify@dotfiles-mods'; Marketplace = 'dotfiles-mods'; MarketplaceSource = 'ntaksh42/dotfiles'; RequiredCommand = 'claude' }
)

