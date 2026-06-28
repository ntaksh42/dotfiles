# Claude Code でのマルチエージェント実行レシピ

設計（patterns.md）が決まったら、この環境で実際に協調を走らせる。
`Agent`（LLM主導）と `Workflow`（コードで決定的）を使い分ける。

## 目次
- [1. Agent と Workflow の使い分け](#1-agent-と-workflow-の使い分け)
- [2. Agent ツール（動的サブエージェント）](#2-agent-ツール動的サブエージェント)
- [3. Workflow ツール（決定的オーケストレーション）](#3-workflow-ツール決定的オーケストレーション)
- [4. topology 別レシピ](#4-topology-別レシピ)
- [5. ガードレール（書き込み範囲・隔離・予算）](#5-ガードレール書き込み範囲隔離予算)

## 1. Agent と Workflow の使い分け

| 状況 | 使う |
|---|---|
| 動的に分解、探索的、手順が事前に決まらない | `Agent` を1〜数体 spawn |
| 構造が決まっている（fan-out→verify→synthesize 等）、多数を並列/パイプライン | `Workflow` |
| 並列で同じファイル群を書き換える（衝突しうる） | `isolation: worktree`（Agent / Workflow 両対応） |
| 長時間・非同期で走らせ完了通知を受けたい | `run_in_background: true` |

注意:
- `Workflow` はトークン消費が大きく、**明示的オプトインが前提**。本スキルの指示で起動する形は
  許容されるが、spawn 数・概算トークンをユーザーに伝えてから実行する。
- `Agent` は1回ごとにコールドスタート。既存の context を引き継ぎたいなら `SendMessage` で
  同じエージェントに継続する（毎回 `Agent` で新規起動しない）。

## 2. Agent ツール（動的サブエージェント）

`Agent` を呼ぶとサブエージェントが起動し、**最終メッセージがツール結果として親に返る**
（ユーザーには表示されない。必要なら親が要約して伝える）。

主なパラメータ:
- `subagent_type`: `Explore`（読み取り探索）/ `Plan`（設計）/ `general-purpose` / `claude` 等
- `prompt`: タスク。目的・出力形式・境界を明示（委譲の原則）
- `model`: `sonnet` / `opus` / `haiku` 等（worker は安価モデルに倒すのが定石）
- `isolation: "worktree"`: 独立 git worktree で作業（並列書き込みの衝突回避）
- `run_in_background: true`: 非同期実行、完了時に通知

orchestrator-worker を Agent で手組みする例（concept）:
1. 親が調査軸を N 個に分解する。
2. 各軸を `Agent`（`subagent_type: "Explore"`, `model: "sonnet"`）に委譲。独立なら同一メッセージ内で
   複数 `Agent` を並列発行する。
3. 各サブエージェントは凝縮サマリ（1-2kトークン）を返す。
4. 親が統合し、必要なら追加の軸を spawn（動的拡張）。

## 3. Workflow ツール（決定的オーケストレーション）

構造が決まった協調は `Workflow` が向く。スクリプトは `export const meta = {...}`（純リテラル）で
始め、本体で `agent()` / `parallel()` / `pipeline()` / `phase()` / `log()` を使う。

要点（詳細は Workflow ツールの説明文が一次情報）:
- `agent(prompt, opts?)`: サブエージェントを起動。`schema`（JSON Schema）を渡すと構造化出力を
  検証して返す。`label` / `phase` / `model` / `effort` / `isolation` / `agentType` 指定可。
- `pipeline(items, stage1, stage2, ...)`: 各 item を全ステージに通す。**ステージ間バリアなし**
  （item A が stage3 の間 item B は stage1 でよい）。多段処理の既定。
- `parallel(thunks)`: 全 thunk を並列実行する**バリア**。全結果が要るときだけ。失敗は `null` に
  なるので `.filter(Boolean)`。
- `phase(title)` / `log(msg)`: 進捗表示。
- 同時実行は `min(16, cpu-2)` に自動制限。`budget` でトークン予算に応じてスケール可能。

**既定は `pipeline()`。** バリア（`parallel` をステージ間に挟む）が正しいのは、次ステージが
前ステージの全結果を必要とするとき（dedup/マージ、件数ゼロで早期終了、相互比較）だけ。

## 4. topology 別レシピ

**parallel-sectioning（独立サブタスクを並列 → 統合）**
```js
const results = await parallel(
  SECTIONS.map(s => () => agent(s.prompt, {label: s.key, schema: SECTION_SCHEMA}))
)
const merged = results.filter(Boolean) // バリア後に統合
```

**orchestrator-worker（fan-out → 各worker検証 → 統合、バリアなし）**
```js
const out = await pipeline(
  TOPICS,
  t => agent(`調査: ${t.q}`, {phase: 'Research', schema: FINDINGS}),
  findings => agent(`検証して凝縮: ${JSON.stringify(findings)}`, {phase: 'Verify', schema: SUMMARY})
)
```

**evaluator-optimizer（生成と評価のループ）**
```js
let draft = await agent('生成', {schema: DRAFT})
for (let i = 0; i < 3; i++) {
  const review = await agent(`評価: ${draft.text}`, {schema: VERDICT})
  if (review.ok) break
  draft = await agent(`修正: ${review.feedback}`, {schema: DRAFT})
}
```
> 生成役と評価役を分ける（自己評価は甘い）。

**adversarial verify（並列の懐疑者で検証）**
```js
const votes = await parallel(Array.from({length: 3}, () => () =>
  agent(`次を反証せよ（疑わしければ refuted=true）: ${claim}`, {schema: VERDICT})))
const survives = votes.filter(Boolean).filter(v => !v.refuted).length >= 2
```

## 5. ガードレール（書き込み範囲・隔離・予算）

**書き込み範囲の制限**（サブエージェントに触らせない領域を作る）
- 単純なパス禁止 → `settings.json` の `permissions.deny`:
  ```json
  { "permissions": { "deny": ["Write(./protected/**)", "Edit(./protected/**)"] } }
  ```
- 条件分岐が要る（既存有無で分岐・内容検査・Bash経由の作成も止める）→ PreToolUse フック:
  ```powershell
  <# .HOOK { "event": "PreToolUse", "matcher": "Write|Edit|MultiEdit" } #>
  $j = [Console]::In.ReadToEnd() | ConvertFrom-Json
  if ($j.tool_input.file_path -like "*\protected\*") {
      [Console]::Error.WriteLine("保護パスへの書き込み禁止"); exit 2
  }
  ```
  > `deny` は Bash 経由のファイル作成を別枠で許してしまう。完全に塞ぐならフック側で
  > `Bash` の matcher も足してコマンド文字列をパースする。

**並列書き込みの隔離**
- 複数エージェントが同じ作業ツリーを書き換えるなら `isolation: "worktree"`。
  変更が無ければ自動でクリーンアップされる。コストがあるので衝突する場合のみ。

**トークン予算**
- Workflow 内では `budget.total` / `budget.remaining()` で動的にスケール
  （例: `while (budget.total && budget.remaining() > 50_000) { ... }`）。
- マルチは単一の約15倍。実行前に概算を伝え、スケーリング規則（簡単=1体、複雑=多数）を守る。
