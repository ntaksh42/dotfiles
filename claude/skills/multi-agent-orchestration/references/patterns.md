# マルチエージェント協調パターン（設計の参照用）

対象に効く topology を1つ選ぶ。全部を機械的に並べない。

## 目次
- [1. 判断ゲートの根拠](#1-判断ゲートの根拠)
- [2. topology カタログ](#2-topology-カタログ)
- [3. 協調機構](#3-協調機構)
- [4. 失敗モードと対策](#4-失敗モードと対策)
- [5. 一次情報源](#5-一次情報源)

## 1. 判断ゲートの根拠

**肯定（Anthropic「How we built our multi-agent research system」）**
- Opus リード + Sonnet サブエージェントが単体 Opus を 90.2% 上回った（社内ベンチ）。
- ただしコスト: エージェントはチャットの約4倍、マルチエージェントは約15倍トークン。
  性能分散の80%をトークン量が説明 → 経済性がタスク選定の生命線。
- 効くのは breadth-first（並列探索）・単一コンテキスト超過・高価値タスク。

**否定（Cognition「Don't Build Multi-Agents」）**
- 並列サブエージェントは context を共有せず、各々の暗黙の前提で動く → 矛盾した成果が
  出て統合不能（Flappy Bird の例）。
- 2原則: ①コンテキストを共有せよ（個別メッセージでなくフルのエージェントトレース）
  ②行動は暗黙の決定を含む。衝突する決定は悪い結果を生む。
- 推奨: 単一スレッド線形エージェント。コンテキスト溢れは「圧縮モデル」で履歴を要約。

→ **結論**: 並列で分割でき・相互依存が低く・高価値、の3つが揃わなければ単一を選ぶ。
「分割できるが相互依存が高い」が最も危険。

## 2. topology カタログ

| topology | 構造 | いつ使う | 協調機構 | 主な失敗 |
|---|---|---|---|---|
| **orchestrator-worker** | 中央LLMが動的に分解・委譲・統合 | サブタスクが事前予測不能。breadth-first調査 | worker は目的/出力形式/境界を受け、凝縮サマリを返す | 委譲が曖昧で重複作業・サブ乱発 |
| **parallel-sectioning** | 独立サブタスクを並列実行（バリア統合） | サブタスクが事前に分かり独立 | 各々独立、最後に統合 | 暗黙の前提衝突で統合不能 |
| **parallel-voting** | 同一タスクを多重実行し多数決 | 確信度を上げたい・検証 | 複数視点を集約 | コスト増、視点が冗長だと無駄 |
| **supervisor** | 各 worker が単一の supervisor とだけ通信 | 中央集権的に制御したい | supervisor が次に呼ぶ worker を決定 | supervisor がボトルネック |
| **supervisor (tool-calling)** | worker を「ツール」として表現 | LLM のツール選択に委ねたい | tool-calling LLM が agent-tool を呼ぶ | ツール記述が悪いと誤選択 |
| **handoff-network** | 任意エージェントが次を選び制御移譲 | 明確な階層や順序がない | Command で state更新＋遷移（LangGraph）/ handoff（OpenAI） | 制御の所在が追えなくなる |
| **hierarchical** | supervisor の supervisor（チーム化） | エージェントが多くチーム編成が要る | 上位が下位チームを束ねる | 階層が深く遅延・コスト増 |

補足:
- **handoff vs agent-as-tool**（OpenAI Agents SDK）:
  - *handoff* = 制御を完全移譲（専門家に丸ごと委ねる。triage→billing 等）
  - *agent-as-tool* = 呼ぶが制御は手放さない（中央が統合する並列サブタスク向き）
- **LLM主導 vs コード主導のオーケストレーション**（OpenAI）:
  - LLM主導 = 柔軟・開放的タスク向き、予測可能性は低い
  - コード主導 = 速い・安い・予測可能、明示的な実装が要る
  - 実運用は両者のブレンド（決定的な足場 + 知的な判断点）

## 3. 協調機構

**コンテキスト共有**
- サブエージェントはクリーンな文脈で focused に作業し、**1,000-2,000トークンの凝縮サマリ**を
  coordinator に返す（Anthropic context engineering）。詳細な探索と高レベル統合を分離。
- ただし Cognition は「決定の理由（フルトレース）」の共有不足が衝突を生むと警告。
  → 独立性が高いタスクはサマリ返し、相互依存が高いなら共有を厚くする（or 単一に倒す）。

**委譲（delegation）**（Anthropic）
- 各 worker に **目的・出力形式・使うツール・タスク境界** を明示的に与える。
- **スケーリング規則を埋め込む**: 簡単なクエリ=1体、複雑な調査=10体以上。effort を複雑さに合わせる。
- 並列ツール呼び出しで調査時間を最大90%短縮しうる。

**コンテキスト戦略**（context engineering、協調の土台）
- context rot: トークンが増えるほど劣化。高シグナルな最小トークン集合を狙う。
- compaction（要約して新コンテキストへ）/ structured note-taking（外部メモリ）/
  just-in-time retrieval（識別子保持→必要時ロード）。
- 使い分け: 密な対話→compaction / 反復開発→note-taking / 並列調査→マルチエージェント。

## 4. 失敗モードと対策

Anthropic の実戦知見:
- 単純クエリへのサブエージェント乱発 → スケーリング規則を明示。
- 存在しない情報の無限検索 → 停止条件（例: トップヒット収束で進む）。
- 曖昧な指示による重複作業 → 委譲を明示的に教える。
- SEO最適化コンテンツを権威ある情報源より優先 → ツール記述・指示で誘導。
- 対策基盤: 本番トレーシング、再開可能チェックポイント、段階デプロイ、決定的セーフガード併用。
- 「軽微な変更が大きな挙動変化に連鎖する」→ 観測性と密なフィードバックループが必須。

Cognition の核心:
- inter-agent misalignment（暗黙の前提衝突）が最大の構造的リスク。
- 共有context・依存・リアルタイム調整が多いほど危険 → そういうタスクは単一スレッドに倒す。

## 5. 一次情報源

- Anthropic「How we built our multi-agent research system」(2025)
- Anthropic「Building Effective Agents」（workflow/agent パターン）
- Anthropic「Effective context engineering for AI agents」
- Cognition「Don't Build Multi-Agents」（cognition.com/blog/dont-build-multi-agents）
- LangGraph Multi-Agent（network/supervisor/hierarchical/handoff）
- OpenAI Agents SDK Multi-Agent（LLM vs code orchestration、handoff、agents-as-tools）
