---
name: harness
description: Claude Code と Codex CLI のハーネス環境（指示ファイル、skills、subagents、hooks、MCP、plugins、feature flags）を公式の診断コマンドで点検し、両者のずれと不具合を一覧にして、公式の手段で直す。「ハーネスを点検して」「Claude と Codex の設定を揃えて」「スキルが Codex に無い」「hooks が効かない」「設定が壊れていないか見て」「使っていないスキルを整理したい」と言われたとき、/dotfiles:harness で使う。エージェントの設計そのものの相談には使わない。
argument-hint: "[check|fix] [対象: instructions|skills|agents|hooks|mcp|plugins]"
---

# harness

自前の診断ロジックは持たず、Claude Code と Codex の公式コマンドの結果を突き合わせる。直すときも公式の手段を使い、正本（dotfiles リポジトリ）を先に直す。

引数が無ければ `check`（読み取りのみ）として動く。`fix` は check の結果をユーザーが確認してから行う。

## 0. 準備

- dotfiles リポジトリの場所は `claude plugin marketplace list` の `dotfiles-mods` の Source（Folder）から取る。以下 `<dotfiles>` と書く
- `<dotfiles>/claude/harness-intentional.md` があれば読む。ここに載っている差分は意図的なものなので報告しない

## 1. 公式コマンドで集める（読み取りのみ、並列で実行してよい）

| 対象 | Claude Code | Codex |
|---|---|---|
| 全体の健康状態 | `claude doctor` | `codex doctor --json`。`checks` は id をキーにしたオブジェクトで、`status` が `ok` 以外のものと `details` の `startup warning` を見る |
| plugins | `claude plugin list`、`claude plugin details <name>`（トークン消費） | `codex plugin list`、`codex plugin marketplace list` |
| MCP | `claude mcp list`（URL のクエリ文字列は伏せて表示する） | `codex mcp list` |
| feature flags | — | `codex features list` |

ファイルで見るもの：

| 対象 | Claude Code | Codex | 正本 |
|---|---|---|---|
| 指示ファイル | `~/.claude/CLAUDE.md` | `~/.codex/AGENTS.md` | `<dotfiles>/claude/CLAUDE.global.md`（Codex 側は無し） |
| skills | `~/.claude/skills/`、plugin 内 `skills/` | `~/.agents/skills/`、`~/.codex/skills/`、plugin 内 `skills/` | `<dotfiles>/claude/mods/dotfiles/skills/` |
| subagents | `~/.claude/agents/*.md` | `~/.codex/agents/*.toml` | 無し |
| hooks | `~/.claude/settings.json` の `hooks`、plugin の `hooks/hooks.json` | `~/.codex/hooks.json`、`config.toml` の `[hooks]` | `<dotfiles>/claude/mods/dotfiles/hooks/hooks.json` |
| settings | `~/.claude/settings.json` | `~/.codex/config.toml` | `<dotfiles>/claude/settings.template.json`（`{{REPO_DIR}}` は比較から外す） |

doctor が拾わない、参照切れと重複も確かめる。

- hooks の `command` が指すスクリプトが実在するか（両ハーネス）。逆に、hooks 用フォルダにあってどこからも呼ばれていないスクリプトがないか
- Codex `config.toml` の `[[skills.config]]` の `path` と `[projects.*]` のディレクトリが実在するか
- plugin のスキルと同名のスキルが `~/.claude/skills` や `~/.agents/skills` にも置かれていないか
- `~/.claude/skills` と `~/.agents/skills` の同名スキルの中身が一致しているか

## 2. セッション内でしか動かない公式コマンドを案内する

次は組み込みコマンドでスキルからは実行できない。ユーザーに実行を頼み、結果を貼ってもらうか、要点を聞く。

- Claude Code: `/doctor`（修正つき点検）、`/doctor prompt-audit`（古い指示・矛盾する指示）、`/skill-doctor`（スキルごとのコンテキスト消費と未使用スキル）
- Codex: `/status`、`/debug-config`（実効設定と出どころ）

`check` の時点では依頼だけ添え、結果を待たずに 3 へ進んでよい。

## 3. 突き合わせて報告する

項目ごとに次のどれかに分類する。

- **不具合**: doctor が warn / fail を出したもの、参照切れ、パースできない設定
- **ずれ**: 片方にしか無い、または内容が違う（指示ファイル、skills、subagents、MCP、hooks）
- **正本との差**: 実環境が dotfiles の正本と違う。`install.ps1` の再実行で消える変更は「上書きリスク」と明記する
- **未使用**: `/skill-doctor` や `claude plugin details` で使われていない、または消費が大きいもの
- **対象外**: ランタイムの状態（スレッド DB、Defender の除外など）や、アプリが自分で書く設定。報告はするが直さない

ずれは「意図的な差か」をユーザーに確認する。意図的と答えたものは `<dotfiles>/claude/harness-intentional.md` に「対象 / 理由 / 記録日」の表で追記する（fix の承認と同じタイミングでよい）。

報告は表にまとめる。列は「# / 対象 / 分類 / 根拠（コマンド出力やファイル） / 直す場所 / 使う公式手段」で、重要な順に並べる。項目が多いときは HTML で見せ、最後に「直すなら番号で指定」と推奨の番号を添える。

## 4. 直す（fix、ユーザーの承認後）

直す場所は正本を優先する。`~/.claude/settings.json` と `~/.claude/CLAUDE.md` は `<dotfiles>/claude/install.ps1` が生成・上書きするので、直接は直さない。git 管理外のファイル（`~/.codex/*` など）を書き換える前は、一時フォルダへ控えを取る。

| 直すもの | 使う公式手段 |
|---|---|
| Claude の settings / hooks / 権限 | `update-config` スキル。恒久化するなら `settings.template.json` か plugin の `hooks/hooks.json` に反映する |
| skill の新規作成・改善 | Claude: `skill-creator`。Codex: `$skill-creator` |
| Claude の資産を Codex へ移す | Codex の `migrate-to-codex` スキル（`$skill-installer` で導入）。Claude 側のファイルは触らない |
| skills を両方へ配る | dotfiles の plugin に置き、Codex でも `codex plugin marketplace add <dotfiles>` と `codex plugin add` で入れる。Codex は `.claude-plugin/marketplace.json` を読み、`CLAUDE_PLUGIN_ROOT` も設定する |
| MCP | `claude mcp add|remove`、`codex mcp add|remove` |
| Codex の feature flag | `codex features enable|disable <name>` |
| plugin の更新・無効化 | `claude plugin update|disable|uninstall`、`codex plugin remove`、`codex plugin marketplace upgrade` |

直したあとの確認：

1. dotfiles の plugin を変えたら `pwsh -File <dotfiles>/tools/Test-ClaudeMods.ps1` を実行し、`plugin.json` の `version` を上げる
2. `claude doctor` と `codex doctor --summary` を再実行し、対象の warn / fail が消えたことを確かめる。参照切れを直したときは、参照先が実在することも確かめる
3. Codex の hooks を書き換えたら、`config.toml` の `[hooks.state]` に記録された承認（`trusted_hash`）が外れる。次回 Codex を起動したときに承認し直すよう伝える
4. skill の効き目を確かめたいときは `claude plugin eval` を案内する

## 守ること

- check では何も書き換えない
- 削除（skills、subagents、MCP、hooks の除去）は対象を列挙してから確認を取る
- 他のツールやアプリが書き込む設定は、doctor が warn を出しても消さず、テンプレートでも上書きしない。例：Codex の `computer_use.*`（アプリの許可リスト）と `[hooks.state]`、`[projects.*]` の trust、Orca や agent-dashboard が登録した hooks。直すなら持ち主のツールの UI やコマンドを使う
- 秘密情報（`auth.json`、`.credentials.json`、MCP の env や URL にあるトークン）は読まない・表示しない。`codex doctor --json` は伏せ字済みなのでそれを使う
