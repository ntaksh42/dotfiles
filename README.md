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

### 2. アイドル通知の出力先フォルダを設定

`idle-snapshot.ps1` はアイドル時に HTML ファイルを生成します。  
出力先は環境変数 `CLAUDE_IDLE_OUTPUT_DIR` で指定します（未設定時は `~/claude-idle-snapshots`）。

Power Automate など外部サービスで監視するフォルダを指定してください：

```powershell
[Environment]::SetEnvironmentVariable("CLAUDE_IDLE_OUTPUT_DIR", "C:\path\to\your\folder", "User")
```

### 3. インストーラを実行

```powershell
powershell.exe -ExecutionPolicy Bypass -File claude\install.ps1
```

インストーラが行うこと：
- `claude/hooks/*.ps1` を `~/.claude/hooks/` にコピー
- `claude/skills/` を `~/.claude/skills/` にコピー
- `settings.template.json` からパスを解決して `~/.claude/settings.json` を生成
- 各フックスクリプト先頭の `.HOOK` メタデータを読み取り、settings.json に自動登録

### 4. Claude Code を再起動

設定を反映するために Claude Code を再起動してください。

---

## AI 向け CLI ツール

`%LOCALAPPDATA%\Microsoft\WinGet\Links\` に以下のツールをインストール済みです。

- `jq` v1.8.1: JSON プロセッサ。API レスポンスや設定ファイルの前処理でトークン消費を大きく抑えられます。
- `rg` (ripgrep) v15.1.0: `.gitignore` を自動除外する高速 grep。`--json` 出力に対応し、多くの AI エージェントと相性が良いです。
- `yq` v4.53.2: YAML / TOML / XML プロセッサ。jq 風構文で K8s や CI 設定を処理できます。

---

## アイドル通知機能（idle-snapshot）

Claude Code がアイドル状態になったとき（`idle_prompt` 通知）に HTML ファイルを生成する機能です。

### 生成されるファイル

ファイル名形式：`{PC名}_{yyyyMMdd-HHmmss}.html`  
例：`DESKTOP-PC01_20260516-143210.html`

内容：
- セッション情報（PC名・時刻・セッションID・作業ディレクトリ）
- Git のブランチ・変更ファイル一覧（git リポジトリ内の場合）
- 直近の会話メッセージ（最大3件）

### Power Automate との連携例

1. Power Automate で「ファイルが作成されたとき」トリガーを設定
2. 監視フォルダに `CLAUDE_IDLE_OUTPUT_DIR` と同じパスを指定
3. メール送信やチーム通知などのアクションを追加

---

## フックの仕組み

各フックスクリプトは先頭に `.HOOK` メタデータブロックを持ちます：

```powershell
<#
.HOOK
{
  "event": "Notification",
  "matcher": "idle_prompt"
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
