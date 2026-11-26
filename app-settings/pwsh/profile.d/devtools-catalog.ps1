$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# §7 Environment setup helpers
# ---------------------------------------------------------------------------

# Tool catalog (data-driven). Backend: winget | msstore | pip | npm | psmodule | script | remote-config | claude-plugin
$script:DevTools = @(
    @{ Name = 'Files'; Backend = 'winget'; Id = 'FilesCommunity.Files' }
    @{ Name = 'Everything'; Backend = 'winget'; Id = 'voidtools.Everything' }
    @{ Name = 'Orca'; Backend = 'winget'; Id = 'StablyAI.Orca' }
    @{ Name = 'PC Manager'; Backend = 'msstore'; Id = '9PM860492SZD' }
    # Claude デスクトップアプリは downloads.claude.ai 配布の exe（Store 版ではない）。
    # 同名の Claude Code CLI と区別するため、起動中かどうかはインストール先のパスで判定する。
    @{ Name = 'Claude'; Backend = 'winget'; Id = 'Anthropic.Claude'; Upgradable = $true; ProcessName = 'claude'; ProcessPath = '*\WindowsApps\Claude_*' }
    # ChatGPT は Store 版（Appx 識別子は OpenAI.Codex）が入るため msstore から入れる。
    # Store 版の更新は Microsoft Store 側でも走るので、winget が差分を見つけたときだけ更新する。
    @{ Name = 'ChatGPT'; Backend = 'msstore'; Id = '9PLM9XGG6VKS'; Upgradable = $true; ProcessName = 'ChatGPT' }
    # 既存の設定を上書きしないよう、レイアウトが未作成（custom-layouts.json なし）の環境にだけ一度配置する。
    @{ Name = 'Waypoint'; Backend = 'script'; Id = 'https://raw.githubusercontent.com/ntaksh42/waypoint/main/installer/install.ps1'; Path = (Join-Path $env:LOCALAPPDATA 'Programs\waypoint\waypoint.exe'); Args = @{ Silent = $true }; RebootRequiredExitCode = 3010; Repo = 'ntaksh42/waypoint'; VersionSource = 'product' }
    # MSIX のため導入先のファイルではなくパッケージ名で判定する（AppxName）。
    @{ Name = 'Dockyard'; Backend = 'script'; Id = "$script:DotfilesRawBase/tools/Install-Dockyard.ps1"; AppxName = 'Dockyard'; Repo = 'ntaksh42/dockyard'; VersionSource = 'appx' }
    # 日本語入力。アプリ自身が自動更新するため、未導入のときだけ入れる（InstallOnly）。
    @{ Name = 'Meltype'; Backend = 'script'; Id = "$script:DotfilesRawBase/tools/Install-Meltype.ps1"; Path = (Join-Path $env:LOCALAPPDATA 'Programs\Meltype\Meltype.exe'); InstallOnly = $true }
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
    # Install-DevTools を動かしている pwsh 自身なので、更新はほかの処理を終えてから別ウィンドウで行う（SelfUpdate）。
    @{ Name = 'PowerShell 7'; Backend = 'winget'; Id = 'Microsoft.PowerShell'; Cmd = 'pwsh'; Upgradable = $true; SelfUpdate = $true }
    @{ Name = 'PSFzf'; Backend = 'psmodule'; Id = 'PSFzf' }
    @{ Name = 'Terminal-Icons'; Backend = 'psmodule'; Id = 'Terminal-Icons' }
    @{ Name = 'gita'; Backend = 'script'; Id = 'https://github.com/ntaksh42/gita/releases/latest/download/install.ps1'; Path = (Join-Path $env:LOCALAPPDATA 'Programs\gita\gita.exe'); RebootRequiredExitCode = 3010; Repo = 'ntaksh42/gita'; VersionSource = 'command' }
    # Windows-Operation-Cli の後継。スキルは Sync-AgentDesktopSkill が CLI から書き出す。
    @{ Name = 'agent-desktop'; Backend = 'npm'; Id = 'agent-desktop'; Cmd = 'agent-desktop'; RequiredCommand = 'npm' }
    @{ Name = 'git'; Backend = 'winget'; Id = 'Git.Git'; Cmd = 'git' }
    @{ Name = 'gh'; Backend = 'winget'; Id = 'GitHub.cli'; Cmd = 'gh' }
    @{ Name = 'Azure CLI'; Backend = 'winget'; Id = 'Microsoft.AzureCLI'; Cmd = 'az' }
    @{ Name = 'fzf'; Backend = 'winget'; Id = 'junegunn.fzf'; Cmd = 'fzf' }
    @{ Name = 'starship.toml'; Backend = 'remote-config'; RepoPath = 'app-settings/starship/starship.toml'; Dest = (Join-Path $env:USERPROFILE '.config\starship.toml') }
    @{ Name = 'VSCode settings.json'; Backend = 'remote-config'; RepoPath = 'app-settings/vscode/settings.json'; Dest = (Join-Path $env:APPDATA 'Code\User\settings.json') }
    @{ Name = 'VSCode keybindings.json'; Backend = 'remote-config'; RepoPath = 'app-settings/vscode/keybindings.json'; Dest = (Join-Path $env:APPDATA 'Code\User\keybindings.json') }
    @{ Name = 'ccstatusline settings.json'; Backend = 'remote-config'; RepoPath = 'app-settings/ccstatusline/settings.json'; Dest = (Join-Path $env:USERPROFILE '.config\ccstatusline\settings.json') }
    # Orca は再起動か Shortcuts 画面の再読み込みで反映する。
    @{ Name = 'Orca keybindings.json'; Backend = 'remote-config'; RepoPath = 'app-settings/orca/keybindings.json'; Dest = (Join-Path $env:USERPROFILE '.orca\keybindings.json') }
    # Everything は終了時に Filters.csv を上書き保存するため、反映前に終了させておくこと。
    @{ Name = 'Everything Filters.csv'; Backend = 'remote-config'; RepoPath = 'app-settings/everything/Filters.csv'; Dest = (Join-Path $env:APPDATA 'Everything\Filters.csv') }
    # Claude Code と Codex の共通ルール。同じ管理元を両方へ配る。
    @{ Name = 'Claude CLAUDE.md'; Backend = 'remote-config'; RepoPath = 'claude/CLAUDE.global.md'; Dest = (Join-Path $env:USERPROFILE '.claude\CLAUDE.md') }
    @{ Name = 'Codex AGENTS.md'; Backend = 'remote-config'; RepoPath = 'claude/CLAUDE.global.md'; Dest = (Join-Path $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }) 'AGENTS.md') }
    @{ Name = 'dotfiles (mod)'; Backend = 'claude-plugin'; Id = 'dotfiles@dotfiles-mods'; Marketplace = 'dotfiles-mods'; MarketplaceSource = 'ntaksh42/dotfiles'; RequiredCommand = 'claude'; Replaces = @('auto-session-title@dotfiles-mods', 'ado-pr-status@dotfiles-mods', 'ado-link-bar@dotfiles-mods', 'toast-notify@dotfiles-mods') }
    # 管理対象のキーだけを ~/.claude/settings.json にマージする。
    @{ Name = 'claude settings'; Backend = 'script'; Id = "$script:DotfilesRawBase/tools/Install-ClaudeSettings.ps1"; Path = (Join-Path $env:USERPROFILE '.claude\settings.json'); RemoteInputs = @('claude/settings.template.json') }
    # 自作のスキル。~/.claude/skills へ置く。インストーラが配置した claude/skills の Git ツリー SHA を Path に記録し、
    # 更新は RemoteTree（GitHub の main の同じフォルダの SHA との比較）で判定する。どのスキルのどのファイルが変わっても更新される。
    @{ Name = 'dotfiles skills'; Backend = 'script'; Id = "$script:DotfilesRawBase/tools/Install-DotfilesSkills.ps1"; Path = (Join-Path $env:USERPROFILE '.claude\skills\.dotfiles-skills-tree'); RemoteTree = 'claude/skills' }
    # 設定に登録する hook。配置したファイルとインストーラを GitHub の main と比べて更新する。
    @{ Name = 'lite hooks'; Backend = 'script'; Id = "$script:DotfilesRawBase/tools/Install-LiteHooks.ps1"; Path = (Join-Path $env:USERPROFILE '.claude\hooks\lite-hook.mjs'); RemoteFiles = @('claude/hooks/lite-hook.mjs') }
    @{ Name = 'reply-check hook'; Backend = 'script'; Id = "$script:DotfilesRawBase/tools/Install-ReplyCheckHook.ps1"; Path = (Join-Path $env:USERPROFILE '.claude\hooks\reply-check.mjs'); RemoteFiles = @('claude/hooks/reply-check.mjs') }
    @{ Name = 'jp-deslop hook'; Backend = 'script'; Id = "$script:DotfilesRawBase/tools/Install-JpDeslopHook.ps1"; Path = (Join-Path $env:USERPROFILE '.claude\hooks\jp-deslop-check.mjs'); RemoteFiles = @('claude/hooks/jp-deslop-check.mjs') }
    @{ Name = 'verify-check hook'; Backend = 'script'; Id = "$script:DotfilesRawBase/tools/Install-VerifyCheckHook.ps1"; Path = (Join-Path $env:USERPROFILE '.claude\hooks\verify-check.mjs'); RemoteFiles = @('claude/hooks/verify-check.mjs') }
    @{ Name = 'compact-reinject hook'; Backend = 'script'; Id = "$script:DotfilesRawBase/tools/Install-CompactReinjectHook.ps1"; Path = (Join-Path $env:USERPROFILE '.claude\hooks\compact-reinject.mjs'); RemoteFiles = @('claude/hooks/compact-reinject.mjs') }
)

