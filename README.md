# env - Claude Code 環境設定

Windows 環境の Claude Code dotfiles（hooks・skills・settings）を一元管理するリポジトリ。

## リポジトリ構成

```
claude/
  install.ps1              インストーラ（hooks・skills・settings を ~/.claude に展開）
  settings.template.json   settings.json のテンプレート
  hooks/                   Claude Code フック用スクリプト
  skills/                  Claude Code スキル
app-settings/              アプリ設定ファイルのバックアップ
tools/                     汎用 PowerShell ユーティリティ
```

## PowerShell コマンド

`app-settings/pwsh/Microsoft.PowerShell_profile.ps1` は基本ヘルパー・エイリアスと
`Update-Profile` を持つローダーで、機能本体は `app-settings/pwsh/profile.d/` に
分割しています（`navigation` / `git` / `vs-build` / `integrations` / `ai-cli` /
`devtools-catalog` / `devtools` / `extra-tools` / `windows-settings` / `psreadline` / `help`）。
読み込み順は `profile.d/manifest.txt` が決めます。新しいファイルを足すときは
`profile.d/` に置いて `manifest.txt` に 1 行追加します。配置時はローダーと
`profile.d/` の両方が必要です。

ローカルの変更を反映する場合は、リポジトリから同期します。

```powershell
pwsh -NoProfile -File tools/Sync-AppSettings.ps1 -WhatIf
pwsh -NoProfile -File tools/Sync-AppSettings.ps1
```

同期先は Windows の Documents フォルダ配下の `PowerShell/` です。
実環境で編集した場合は `-Direction Pull` でローダーと `profile.d/` を管理元へ取り込みます。
`profile` は現在読み込んでいるプロファイルを編集し、`reload` は再読み込みします。
`Update-Profile` は GitHub の `main` からローダーと `profile.d/` 一式を取得し、構文検証・
上書き確認・バックアップ後に更新するため、未公開のローカル変更は反映しません。

コマンド一覧は `phelp`（例: `phelp git`）、検索は Ctrl+G で開けます。
`gl`、`gp`、`gcm`、`cat` は標準エイリアスを置き換え、それぞれ
Git log、Git push、Git commit、bat 連携として動作します。
`gco` の引数なし実行は `git-switch` と同じブランチ選択を使います。
その他の既存の短縮名も維持しています。

検証は `pwsh -NoProfile -File app-settings/pwsh/tests/Invoke-AllTests.ps1` で全テストファイルを一括実行します（個別実行は各 `Test-*.ps1`）。

## 一部の端末だけに入れるアプリ

DevDeck（`ntaksh42/DevDeck`）と RdpManager（`ntaksh42/rdp-manager`）は全端末には不要なため、
`Install-DevTools` のカタログには入れず、専用の `Install-ExtraTools` で導入します。
GitHub Releases の最新インストーラを取得して実行し、導入済みで最新なら何もしません。
古い場合は更新し、実行中のアプリは終了します。

```powershell
Install-ExtraTools                       # DevDeck と RdpManager の両方
Install-ExtraTools -Name DevDeck         # 指定したものだけ
Install-ExtraTools -Name RdpManager -Yes # 確認を省略
```

DevDeck は NSIS 版（ユーザー単位・無人）、RdpManager は MSI 版（マシン単位のため UAC が出ます）を使います。
対象を増やすときは `profile.d/extra-tools.ps1` の `$script:ExtraTools` に 1 行足します。

## Git 設定

PowerShell 7 / Git for Windows 向けの共有設定は
`app-settings/git/.gitconfig` にあります。個人情報や署名鍵、認証 helper は
公開用の設定から分離し、`~/.gitconfig.local` で管理します。既存の設定が
ある場合は、それをローカル設定として残してから共有設定を配置します。

```powershell
# 既存の ~/.gitconfig がある場合（認証・ユーザー情報もそのまま保持）
Move-Item ~/.gitconfig ~/.gitconfig.local
Copy-Item app-settings/git/.gitconfig ~/.gitconfig

# Git を初めて設定する場合は、上の Move-Item の代わりにこちらを実行
Copy-Item app-settings/git/.gitconfig.local.example ~/.gitconfig.local
notepad ~/.gitconfig.local
```

`delta` が未導入の場合は `Install-DevTools` で導入できます。設定後は
`git config --global --list` で読み込み結果を確認してください。

## ステータスライン設定

`claude/settings.template.json` の `statusLine` は `npx -y ccstatusline@latest`
を呼び出します。ccstatusline はレイアウト設定を
`~/.config/ccstatusline/settings.json` から読み込みます。この設定は
`app-settings/ccstatusline/settings.json` を管理元として `Install-DevTools`
（remote-config バックエンド）が配置・更新します。

```powershell
Install-DevTools
```

ccstatusline はTUI上での編集で設定ファイル自身を書き換えるため、
`Install-DevTools` は配置済みの設定と管理元の内容が異なる場合、差分を表示した
上で上書き可否を確認します（手元での編集を誤って消さないよう、この確認は
`-Force` を付けても省略されません）。上書き確認も含めてすべての確認に「はい」と
答える場合は `Install-DevTools -Yes` を使います（差分表示とバックアップは行われます）。

`Install-DevTools` は `~/.agents/skills/` にだけあるスキルを `~/.claude/skills/` へ移し、
元の場所にシンボリックリンクを作ります。同名の既存スキルと `SKILL.md` のないディレクトリは変更しません。

配置後は Claude Code を再起動すると、モデル・コンテキスト使用率・git ブランチ・
セッション使用量などの構成が反映されます。

## Claude Code Mods

`Install-DevTools` は `claude/mods/` の Mod（`auto-session-title`）も導入します。
`dotfiles-mods` マーケットプレイスが未登録なら GitHub の `ntaksh42/dotfiles` から登録し、
その後 `claude plugin install` を実行します。`claude/install.ps1` がクローン先のパスで
登録済みの場合は、そのマーケットプレイスをそのまま使います。GitHub から登録する場合は、
Mod が `main` に取り込まれている必要があります。`claude` が PATH に無いとスキップされます。

## Codex ステータスライン

**現在は一時的に無効化中です。** `Install-DevTools` は Codex ステータスラインを
インストールせず、導入済みの環境では `%LOCALAPPDATA%\CodexStatusline\codex-wt.ps1` を
`codex-wt.ps1.disabled` に退避します（`codex` は通常の Codex CLI を起動します）。
再び有効にするには、`.disabled` を元の名前に戻し、`Install-DevTools` のカタログと
`Disable-CodexStatusline` の呼び出しを元に戻します。

有効だった頃は、下側 18% のペインにモデル、推論強度、コンテキスト、git 状態、
セッション/週次の使用量を表示していました。`tools/Install-CodexStatusline.ps1` と
`app-settings/codex-statusline/` は再開用に残してあります。

## Crit

`Install-DevTools` は Crit 本体と Codex 連携もインストールします。インストール時に
`~/.crit.config.json` の既存項目を維持しつつ、社内利用向けの安全設定として
ローカルホスト限定、更新確認の無効化、Share の無効化、`agent_cmd` の無効化を設定します。

```json
{
  "host": "127.0.0.1",
  "no_update_check": true,
  "share_url": "",
  "share_targets": [],
  "agent_cmd": ""
}
```

## セットアップ手順

### 1. リポジトリをクローン

```powershell
git clone https://github.com/ntaksh42/env.git
cd env
```

### 2. インストーラを実行

```powershell
powershell.exe -ExecutionPolicy Bypass -File claude\install.ps1
```

インストーラが行うこと：
- `claude/hooks/*.ps1` を `~/.claude/hooks/` にコピー
- `claude/skills/` を `~/.claude/skills/` にコピー
- `claude/agents/*.md` を `~/.claude/agents/` にコピー
- `settings.template.json` からパスを解決して `~/.claude/settings.json` を生成
- 各フックスクリプト先頭の `.HOOK` メタデータを読み取り、settings.json に自動登録

### 3. Claude Code を再起動

設定を反映するために Claude Code を再起動してください。

---

## AI 向け CLI ツール

`%LOCALAPPDATA%\Microsoft\WinGet\Links\` に以下のツールをインストール済みです。

- `jq` v1.8.1: JSON プロセッサ。API レスポンスや設定ファイルの前処理でトークン消費を大きく抑えられます。
- `rg` (ripgrep) v15.1.0: `.gitignore` を自動除外する高速 grep。`--json` 出力に対応し、多くの AI エージェントと相性が良いです。
- `yq` v4.53.2: YAML / TOML / XML プロセッサ。jq 風構文で K8s や CI 設定を処理できます。

---

## フックの仕組み

各フックスクリプトは先頭に `.HOOK` メタデータブロックを持ちます：

```powershell
<#
.HOOK
{
  "event": "PostToolUse",
  "matcher": "Task",
  "async": true
}
#>
```

`install.ps1` がこのブロックを解析して `settings.json` の `hooks` セクションに自動登録します。  
新しいフックを追加する場合は、スクリプト先頭にこのブロックを含めるだけで自動的に反映されます。

## ユーティリティ

```powershell
# 複数 git リポジトリを一括 pull
powershell.exe -File tools\Update-GitRepositories.ps1 -Path "C:\Projects"

# app-settings/ の設定ファイルと実環境の配置先を同期
pwsh -File tools\Sync-AppSettings.ps1              # repo -> 実環境 (既定)
pwsh -File tools\Sync-AppSettings.ps1 -Direction Pull  # 実環境 -> repo

# Windows 設定（レジストリ）を適用 (pwsh プロファイル経由)。HKLM 項目は管理者権限が必要
Set-WindowsSettings -Check    # 差分のみ表示
Set-WindowsSettings           # 適用
```

## Orca 設定

`Install-DevTools` は Orca 本体も winget（`StablyAI.Orca`）でインストールします。
導入済みの場合はスキップします。

Orca の外観・エディタ・ターミナル設定は `app-settings/orca/settings.json` に保存します。
`python tools/Export-OrcaSettings.py` で現在の設定を取り込めます。認証情報や作業履歴は
対象外です。JSON の自動読み込みには対応していないため、復元方法と対象範囲は
`app-settings/orca/README.md` を参照してください。

## PowerToys 設定

PowerToys の設定（FancyZones のレイアウト・ホットキーを含む）は
`app-settings/powertoys/` に保存します。対象は PowerToys 公式の Back up & restore と
同じ設定ファイルです。ユーザー名入りのパスを含む `Workspaces\workspaces.json` と
`NewPlus\settings.json` は公開リポジトリに載せないため対象外です。

```powershell
pwsh -File tools\Sync-PowerToysSettings.ps1 -Direction Pull  # 実環境 -> repo（バックアップ）
pwsh -File tools\Sync-PowerToysSettings.ps1 -WhatIf          # 復元の対象だけ確認
pwsh -File tools\Sync-PowerToysSettings.ps1                  # repo -> 実環境（復元）
```

バックアップ（Pull）は `app-settings/powertoys/manifest.txt` も更新します。
新しい PC では `Install-DevTools` が PowerToys 本体（winget）に続いて設定を GitHub の `main`
から配置します（`PowerToys settings`）。`FancyZones\custom-layouts.json` が未作成の環境にだけ
一度実行し、既存ファイルが異なる場合は `.backup.<日時>` を残します。設定を取り直すときは
上の `Sync-PowerToysSettings.ps1` を使います。

復元は PowerToys を停止してコピーし、起動していた場合は再起動します。
FancyZones のモニターごとの適用レイアウト（`applied-layouts.json`）は対象外なので、
復元後に各モニターへレイアウトを選び直してください。
