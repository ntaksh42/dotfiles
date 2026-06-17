# ハーネス/Loop設計 観点チェックリスト（診断・設計の参照用）

対象に効く観点だけを選んで使う。全部を機械的に並べない。

## 1. ループパターン
- [ ] パターンが対象に合っているか（ReAct=逐次探索 / Plan-Execute=計画先行・低コスト / ReWOO=並列ツール / Reflexion=失敗からの自己改善 / 混成=検証失敗時リトライ）
- [ ] 1ステップ1責務になっているか（one-shotting・詰め込みすぎていないか）
- [ ] 失敗時のリプラン/リトライ経路があるか
- [ ] 無限ループ・同一クエリ反復・「十分なのに探索継続」を防ぐ停止条件があるか

## 2. コンテキストエンジニアリング
- [ ] 最小限の高シグナルトークンか（不要な履歴・冗長ツール出力を載せていないか → context rot）
- [ ] just-in-time検索（識別子保持→必要時ロード）か、全部前もって詰めていないか
- [ ] progressive disclosure（段階開示）になっているか
- [ ] compaction戦略: 上限接近で要約。アーキ決定/未解決バグ/最近のファイルは保持、冗長出力は破棄
- [ ] structured note-taking（NOTES.md等の外部メモリ）でリセット後も一貫性が保てるか
- [ ] 使い分け: 密な対話→compaction / 反復開発→note-taking / 並列調査→マルチエージェント

## 3. 長時間タスクの永続性
- [ ] 状態の外部化（進捗ファイル、JSON状態、git commit、init script）があるか
- [ ] セッション開始ルーチンが標準化されているか（状態の読み戻し）
- [ ] context reset + 構造化ハンドオフ成果物があるか（compaction単独に頼っていないか）
- [ ] 「記憶喪失で再開しても続行できる」設計か

## 4. ツール設計（agent ergonomics）
- [ ] 自己完結・エラーロバスト・意図明確か
- [ ] 命名が明確に区別され誤選択を招かないか
- [ ] 機能重複がないか
- [ ] deeply nested → フラット化、複雑ツール → atomic分解されているか
- [ ] 強い型/enum、検証済みデフォルト、有用なエラーメッセージがあるか
- [ ] トークン効率（verbosity可変 concise/detailed、human-readableフィールド、小さく多数の検索を促す）
- [ ] ツール記述（description/spec）自体をプロンプトエンジニアリングしているか

## 5. 検証ループ / eval
- [ ] 生成と評価が分離されているか（自己評価は甘い）
- [ ] 評価粒度: 最終出力 / trajectory（行動列）/ single-step を適切に使い分けているか
- [ ] LLM-as-judge を使う場合 golden dataset で人間と75-90%一致を確認したか
- [ ] rubric が三層・重み付けで、実トレースの失敗モードから逆算されているか
- [ ] E2E検証（人間並み）優先か（curl/unit testに偏っていないか）
- [ ] evalがCI/PRゲート化され regression-free 改善になっているか

## 6. オーケストレーション / マルチエージェント
- [ ] そもそもマルチエージェントが必要か（単一の~15倍トークン。並列独立の高価値タスク以外は単一推奨）
- [ ] topology（並列/順次/階層）が適切か
- [ ] inter-agent misalignment（失敗の32.3%）対策があるか（共有context・依存・リアルタイム調整が多いほど危険）
- [ ] サブエージェント結果が圧縮（1-2kトークン）して親に返るか

## 7. プロンプト/モデル制御
- [ ] reasoning_effort がタスク形状に合っているか（低=効率/高=複雑タスク）
- [ ] agentic eagerness制御（ツール予算固定、エスケープハッチ）
- [ ] 停止条件の明示（例: トップヒット70%収束で進む）
- [ ] 矛盾する指示を除去したか（推論トークンの浪費源）
- [ ] tool preambles（計画・進捗の言語化）／verbosity制御
- [ ] persistence（質問を最小化し最適仮定で継続）か、過度に確認を挟むか
- [ ] self-reflection rubric（内部反復）を使うべきタスクか

## 8. コスト・レイテンシ最適化
- [ ] prompt caching/KV cache を壊さないプロンプト設計か（安定prefix → 入力コスト50-90%減）
- [ ] 構造化出力/constrained decoding（JSON Schema強制）でパース失敗を防いでいるか

## 9. メモリ・状態管理
- [ ] 一時履歴 / 永続Plan文書 / クロスセッション状態 を区別しているか
- [ ] hibernation-and-wake チェックポイント、メモリ階層化（active vs on-demand）

## 10. 権限・セキュリティ・サンドボックス
- [ ] Lethal Trifecta チェック: private data + untrusted content + external comm の3つが揃っていないか
- [ ] Rule of Two: 無監督なら3要素中最大2つ。全部なら human-in-the-loop
- [ ] context isolation: untrusted入力を構造的に分離し「データ」として扱っているか
- [ ] capability reduction（exfiltration脚を削る）、ephemeral runner、firewall allowlist、output redaction
- [ ] 最小権限、deny>allow、permission hooks、subagent権限継承

## 11. 可観測性・DX
- [ ] 監査ログ、trajectory replay、token/latencyプロファイリングがあるか
- [ ] schema検証、regression検出、設定の移植性（.agent/相当）

## 横断原理
- ハーネスは暫定的補完。モデル進化で簡素化する前提で組む。
- 「最も単純に機能するもの」から始める。過剰な足場を組まない。
- 構成変更（prompt/param/topology）はモデル交換と同等の性能向上をもたらす。
- 「人間エンジニアが実際にやる業務慣行」からの着想。

## 一次情報源
- Anthropic「Effective harnesses for long-running agents」
- Anthropic「Effective context engineering for AI agents」
- Anthropic「Writing effective tools for AI agents」
- Anthropic マルチエージェントリサーチシステム（June 2025）
- OpenAI GPT-5 prompting guide
- awesome-harness-engineering (GitHub: ai-boost)
- Simon Willison: Lethal Trifecta / Rule of Two
