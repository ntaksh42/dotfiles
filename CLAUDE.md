# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## リポジトリ概要

Windows環境のClaude Code dotfiles・開発環境構成リポジトリ。Claude Codeのhooks、skills、settings、PowerShellプロファイル、ユーティリティツールを一元管理する。

## アーキテクチャ

```
claude/              Claude Code 設定の管理元（~/.claude へインストール）
  install.ps1        インストーラ（hooks・skills・agents・settingsを ~/.claude に展開）
  settings.template.json  settings.json テンプレート（{{CLAUDE_DIR}} 等のプレースホルダ）
  hooks/             フック用PowerShellスクリプト（.HOOKブロックでメタデータ定義）
  skills/            Claude Code スキル（各サブディレクトリが1スキル）
  agents/            サブエージェント定義（各 .md が1エージェント）
app-settings/        アプリ設定ファイルのバックアップ・管理
tools/               汎用PowerShellユーティリティ
```

### hooks の仕組み

- 各 `.ps1` ファイル先頭の `<# .HOOK { "event": "...", "matcher": "..." } #>` ブロックからメタデータを抽出
- `install.ps1` がメタデータを読み取り、`settings.json` の `hooks` セクションに自動登録
- stdinからJSON形式のコンテキスト（session_id, cwd, transcript_path等）を受け取る

### skills の仕組み

- `claude/skills/` 配下のサブディレクトリが個別スキル
- 各スキルは `SKILL.md`（プロンプト定義）と `references/`（参照資料）で構成
- `.skill` ファイル（単一ファイル形式）も存在する（例: `ai-news-researcher.skill`）

### agents の仕組み

- `claude/agents/` 配下の各 `.md` が個別サブエージェント（frontmatterに `name` / `description` / `tools` / `model`）
- `install.ps1` が `~/.claude/agents/` へコピーする

### セルフレビューの仕組み（self-review）

- コード変更（Edit/Write/MultiEdit/NotebookEdit）を行ったターンでは、出力確定前に `self-review` サブエージェントでのセルフレビューを必須とする
- `hooks/self-review-guard.ps1`（Stopフック）が transcript をper-turnで解析し、コード変更があるのにレビュー未実施なら応答をブロックして実施を促す
- レビューは読み取り専用で、指摘のみを返す（修正はメインエージェントが行う）

### settings.template.json

- プレースホルダ: `{{CLAUDE_DIR}}` → `~/.claude`、`{{IDLE_OUTPUT_DIR}}` → `~/claude-idle-snapshots`
- インストーラがプレースホルダを実際のパスに置換して `~/.claude/settings.json` を生成

## コマンド

```bash
# Claude Code 環境のインストール（hooks, skills, settings を ~/.claude に展開）
powershell.exe -ExecutionPolicy Bypass -File claude/install.ps1

# 複数gitリポジトリの一括pull
powershell.exe -File tools/Update-GitRepositories.ps1 -Path "C:\Projects"
```

## 開発規約

- hookスクリプトには必ず `.HOOK` メタデータブロックを含める（install.ps1の自動登録に必要）
- スキルはサブディレクトリ形式（`SKILL.md` + `references/`）を推奨
- PowerShellスクリプトは `$ErrorActionPreference = "Stop"` を使用
- settings.template.json のパスには `\\\\` エスケープを使用（JSON + PowerShellの二重エスケープ）

## アシスタントの作法（汎用・モデル非依存）

このセクションはモデルやバージョンに依存しない一般的な作業作法。どのClaudeモデルで作業しても適用される（特定モデルの自己紹介・モデルID・知識カットオフ等は含めない）。

### コミュニケーション
- 温かく丁寧に接し、相手の判断を否定的に決めつけない。
- 過剰な装飾を避ける。箇条書き・見出しは明確さに必要なときだけ使い、デフォルトにしない。単純な回答は自然な散文で返す。
- 結論を先に述べる。何が起きたか/何が分かったかを最初の一文で答え、詳細はその後に置く。
- 簡潔さより読みやすさを優先する。短くするために専門用語の羅列や矢印チェーンに圧縮しない。

### 誤りと指摘への対応
- 間違えたら認めて直す。何が問題だったかを述べ、問題に集中し続ける。過度な謝罪はしない。
- 批判は事実として受け止め、必要なら反証を示す。萎縮も丸呑みもしない。

### 技術的判断の公平さ
- トレードオフのある選択では、自分の好みだけでなく各案の最善のケースを公平に提示する。
- 単純なYes/Noに収まらない論点は、無理に二択へ畳まず理由とともに説明する。

### 事実性と自律性
- どんな話題も事実ベース・客観的に扱う。有害な依頼（マルウェア、攻撃手法等）は長い説明なしに断る。
- 行動できる情報が揃ったら、可逆な作業は許可を待たずに進める。破壊的・不可逆な操作のみ確認する。
- 中身のない相槌や継続利用の促しをしない。ユーザーの過度な依存を助長しない。
