# Claude Code Harness (dotfiles)

Windows 向け Claude Code ハーネス環境のリポジトリ。ユーザーの `~/.claude/` へインストールして使う dotfiles。

## インストール

```powershell
cd claude
.\install.ps1
```

インストール後は Claude Code を再起動すること。

## リポジトリ構造

```
claude/
├── settings.template.json   # 設定テンプレート（{{CLAUDE_DIR}} プレースホルダーあり）
├── install.ps1              # インストーラー
├── hooks/                   # Claude Code フックスクリプト
│   ├── session-start.ps1           # SessionStart: 環境チェック・ウェルカム
│   ├── dangerous-command-guard.ps1 # PreToolUse: 危険コマンドをブロック/確認
│   ├── instruction-compliance-hook.ps1 # Stop: CLAUDE.md 遵守チェック
│   ├── reset-compliance-counter.ps1    # UserPromptSubmit: 違反カウンタリセット
│   ├── claude-notification.ps1     # Notification: Windows Toast 通知
│   └── statusline.ps1              # StatusLine: リポジトリ/モデル/コンテキスト表示
└── skills/                  # Claude Code スキル
    ├── save-report/         # 会話結果をHTMLレポートとして保存
    ├── skill-generator/     # 新しいスキルの作成・パッケージング
    ├── ado-operation/       # Azure DevOps 操作
    ├── copilot-delegate/    # GitHub Copilot 委譲
    ├── drawio-diagram/      # Draw.io 図作成
    └── presentation-creator/ # プレゼンテーション作成
```

## フック一覧

| イベント | スクリプト | 役割 |
|---------|-----------|------|
| SessionStart | session-start.ps1 | 環境変数確認・ウェルカムメッセージ |
| UserPromptSubmit | reset-compliance-counter.ps1 | 違反カウンタリセット |
| PreToolUse (Bash) | dangerous-command-guard.ps1 | 危険コマンドブロック |
| Stop | instruction-compliance-hook.ps1 | CLAUDE.md 遵守チェック |
| Notification | claude-notification.ps1 | Toast 通知 |
| StatusLine | statusline.ps1 | ステータス行表示 |

## settings.template.json の {{CLAUDE_DIR}} プレースホルダー

`install.ps1` が `{{CLAUDE_DIR}}` を実際の `~/.claude` パスに置換して `settings.json` を生成する。
フックスクリプトのパスはすべてこのプレースホルダーを使うこと。

## スキル追加手順

```powershell
# skill-generator スキルを使って新スキルを作成
# 1. claude/skills/<name>/ ディレクトリを作成
# 2. SKILL.md を書く（YAML frontmatter + Markdown 本文）
# 3. install.ps1 を再実行してスキルをデプロイ
```

## 開発時の注意

- フックスクリプトは必ず `exit 0` で終了する（例外は deny 時も同様）
- フックから JSON を出力するときは `ConvertTo-Json -Depth 10 -Compress` を使う
- `instruction-compliance-hook.ps1` の Stop フックは `stop_hook_active` チェックで無限ループを防止済み
- `dangerous-command-guard.ps1` の入力は `ConvertFrom-Json` で解析すること（正規表現は不可）
