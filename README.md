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
docs/                      ドキュメント・設計資料
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
```
