# AGENTS.md

このファイルはコーディングエージェント（Claude Code、Codex CLI 等）がこのリポジトリで作業する際のガイダンスを提供する。

## リポジトリ概要

Windows環境のClaude Code dotfiles・開発環境構成リポジトリ。Claude Codeのhooks、skills、agents、settings、PowerShellプロファイル、ユーティリティツールを一元管理する。

## アーキテクチャ

```
claude/              Claude Code 設定の管理元
  install.ps1        インストーラ（CLAUDE.md・settings.json を ~/.claude に配置）
  settings.template.json  settings.json テンプレート（{{REPO_DIR}} プレースホルダ）
  CLAUDE.global.md   グローバル CLAUDE.md の管理元（~/.claude/CLAUDE.md へ展開、既存はバックアップ）
  mods/              Claude Code プラグイン。リポジトリ直下の .claude-plugin/marketplace.json で
                     dotfiles-mods マーケットプレイスとして公開し、settings で有効化する
    dotfiles/        自作の skills・hooks・Mod をまとめた唯一の plugin
app-settings/        アプリ設定ファイルのバックアップ・管理
tools/               汎用PowerShellユーティリティ
```

### skills・hooks の仕組み

- skills と hooks は `claude/mods/dotfiles` plugin に置く。導入は `Install-DevTools` が `claude plugin install` で行う
- スキルは `claude/mods/dotfiles/skills/<name>/SKILL.md`。plugin 内なのでスキル名は `dotfiles:<name>` になる
- Mod（TypeScript の hooks module）は `hooks/<mod>/register.ts(x)` に置き、`hooks/register.ts` から呼ぶ。エンジンは同じイベントの matcher 無しフックを plugin につき 1 つしか許さないので、イベントが重なる Mod は `hooks/register.ts` でネストして束ねる
- 組織の管理設定（`allowManagedModsOnly` 等）で mod が拒否される環境向けに、mod を使わない代替を同じ plugin に置く: toast-notify と auto-session-title は `scripts/lite-hook.mjs`（`hooks.json` の settings hook）、ado-pr-status は ccstatusline が呼ぶ `statusline/pr-line.mjs` の自己更新、cmdHistory は `skills/cmd-history`。mod が動くセッションでは mod が環境変数 `DOTFILES_MOD_TOAST` / `DOTFILES_MOD_TITLE` を設定し、`lite-hook.mjs` はそれを見て何もしない（二重通知を避ける）。通知の送信は `scripts/toast-send.ps1` を mod と共有する
- Mod の設定（userConfig）は `plugin.json` に Mod 名の接頭辞（`toast*`、`linkBar*`）を付けて置く
- hook は `claude/mods/dotfiles/hooks/hooks.json` に登録し、スクリプトは `${CLAUDE_PLUGIN_ROOT}` で参照する
- スキルからスクリプト等を参照するときは `~/.claude/skills/...` と決め打ちせず、SKILL.md のあるディレクトリからの相対で書く

### settings.template.json

- プレースホルダ: `{{REPO_DIR}}` → リポジトリのクローン先（dotfiles-mods マーケットプレイスの登録先）
- インストーラがプレースホルダを実際のパスに置換して `~/.claude/settings.json` を生成

## コマンド

```bash
# CLAUDE.md と settings.json を ~/.claude に配置する
powershell.exe -ExecutionPolicy Bypass -File claude/install.ps1

# app-settings/ の設定ファイルを実環境へ配置する（pwsh プロファイル経由。GitHub の main から取得）
# 配置対象は app-settings/pwsh/profile.d/devtools-catalog.ps1 のカタログで定義する。プロファイル自体は Update-Profile
Install-DevTools

# claude/mods/ の全 mod に claude plugin validate / test をかける（失敗があれば終了コード 1）
pwsh -File tools/Test-ClaudeMods.ps1

# Windows 設定（レジストリ）の適用。pwsh プロファイル経由のコマンド（app-settings/pwsh/profile.d/windows-settings.ps1）
# HKLM 項目は管理者権限が必要
Set-WindowsSettings -Check    # 差分のみ表示（書き込まない）
Set-WindowsSettings           # 適用（Explorer 系は explorer.exe を再起動）
```

## 開発規約

- hook を追加したら `claude/mods/dotfiles/hooks/hooks.json` に登録する
- スキルはサブディレクトリ形式（`SKILL.md` + `references/`）を使用する
- plugin の中身を変えたら `plugin.json` の `version` を上げる
- devtools カタログの winget / msstore 項目は `Upgradable = $true` を付けたものだけ `Install-DevTools` が更新する（既定は未導入時のインストールのみ）。更新で落とされると困るアプリには `ProcessName`（同名の別プロセスがあるなら `ProcessPath` も）を付け、起動中は更新を見送らせる
- PowerShellスクリプトは `$ErrorActionPreference = "Stop"` を使用
- settings.template.json のパスは JSON 文字列としての `\\` エスケープを使用（`\\\\` は過剰）

## モデルの使い分け

- **機械的な変更は Sonnet サブエージェントに移譲する。** 判断をほぼ伴わない定型作業（一括リネーム、フォーマット適用、import 整理、定型ファイルの雛形生成、明確な手順が確定済みの修正など）は、`Task`/`Agent` ツールで model=sonnet のサブエージェントに委譲してコストと時間を抑える。
- 設計判断・トレードオフの検討・あいまいな要件の解釈・レビューが必要な変更は移譲せず、メインで対応する。
- 移譲する際は、対象ファイル・期待結果・完了条件を明示し、結果を受け取ったら差分を確認する。

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
