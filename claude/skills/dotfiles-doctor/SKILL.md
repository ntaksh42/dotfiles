---
name: dotfiles-doctor
description: この dotfiles リポジトリの設定整合性を点検する。「dotfiles をチェックして」「設定の整合性を見て」「hook がちゃんと登録されるか確認して」「install.ps1 が壊れてないか」などと依頼されたときに使用。hooks の .HOOK メタデータ・settings.template.json・skills 構成を install.ps1 の挙動に照らして検証する。
---

# dotfiles-doctor — dotfiles 整合性チェック

`claude/install.ps1` がエラーなく正しく展開できる状態かを点検し、問題と修正案を報告する。
このリポジトリ専用。実行する破壊的操作はなく、読み取りと検証が中心。

## チェック項目

### 1. hooks の .HOOK メタデータ
`claude/hooks/*.ps1` を 1 つずつ確認する。

- 各ファイル先頭に `<# .HOOK { ... } #>` ブロックがあるか（無いと settings.json に登録されない）
- ブロック内の JSON が `ConvertFrom-Json` でパース可能か（壊れていると install 時に WARNING）
- `event` キーが存在するか。値が正規のイベント名か
  （PreToolUse / PostToolUse / SessionStart / SessionEnd / Stop / Notification / UserPromptSubmit / PreCompact 等）
- `matcher` / `async` / `asyncRewake` を使う場合、型が妥当か（async は bool）

### 2. settings.template.json
- JSON として妥当か（`ConvertFrom-Json` で読めるか）
- プレースホルダは `{{CLAUDE_DIR}}` / `{{IDLE_OUTPUT_DIR}}` のみか（未定義プレースホルダが残っていないか）
- Windows パスは `\\\\`（JSON + PowerShell 二重エスケープ）になっているか
- `$schema` 等の必須キー構成が崩れていないか

### 3. skills 構成
- `claude/skills/` 配下の各サブディレクトリに `SKILL.md` があるか
- `SKILL.md` の frontmatter に `name` と `description` があるか
- frontmatter の `name` がディレクトリ名と一致しているか
- 単一ファイル形式 `*.skill` が混在していれば、それも認識して報告する

### 4. install.ps1 との突き合わせ
- hooks のうち `.HOOK` ブロックを持たないものは「登録対象外」として一覧化する
- 同一 event × 同一 matcher の重複（install.ps1 はスキップするが意図しない重複は警告）

## 進め方

1. 上記を読み取りで検証する（実際に install.ps1 は実行しない）
2. 結果を **OK / 警告 / エラー** で分類して報告する
3. 各指摘に「対象ファイル → 問題 → 具体的修正」を付ける
4. 問題が無ければ「整合性 OK」と明言する

## 原則

- 検証のために設定を書き換えない。修正は提案にとどめ、依頼があってから適用する
- install.ps1 の実挙動（正規表現 `(?s)<#\s*\.HOOK\s*(\{.*?\})\s*#>`、matcher 重複スキップ等）を基準に判断する
