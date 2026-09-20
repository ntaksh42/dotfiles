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
`-Force` を付けても省略されません）。

配置後は Claude Code を再起動すると、モデル・コンテキスト使用率・git ブランチ・
セッション使用量などの構成が反映されます。

## Codex ステータスライン

`Install-DevTools` は Codex 用の Windows Terminal ステータスラインも
`%LOCALAPPDATA%\CodexStatusline` に配置します。PowerShell プロファイルを同期・再読み込み後、
通常どおり `codex` を起動すると、下側 18% のペインにモデル、推論強度、コンテキスト、
git 状態、セッション/週次の使用量を表示します。

```powershell
pwsh -File tools\Sync-AppSettings.ps1
. $PROFILE
Install-DevTools
codex
```

`codex exec`、`codex review`、ログインや App Server などの非対話コマンドは、ステータスラインを
開かず通常の Codex CLI を実行します。Python、Windows Terminal、Codex CLI が必要です。

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
```
