# report-to-user の評価

リポジトリルートから実行する（モデル呼び出しを伴う）。発動テストは20件、出力テストは4件ある。

## 発動テスト

発動テストは `tool_used: Skill` で `report-to-user` の呼び出し有無を検査する。既定の `with-without` ではこの grader が採点対象から外れるため、`--ablation none` を必ず指定する。

```powershell
claude plugin eval ./claude/mods/dotfiles --ablation none --no-publish --tag report-to-user
```

未知の言い回しを使った holdout ケースだけ実行する場合：

```powershell
claude plugin eval ./claude/mods/dotfiles --ablation none --no-publish --tag holdout
```

## 出力テスト

出力テストは2種類の grader で確かめる。`tool_used: Write` は HTML ファイルへの書き込み有無を見る。`llm` は最終応答の形（[判断] で推奨を先に書くか、会話でシートの中身を繰り返さないか、差分の確認で最初に見る行と触っていない範囲を示すか）を採点する。HTML の中身、ブラウザ表示、承認後の動作は検査しない。`Write` は実行側でも許可が必要。

```powershell
claude plugin eval ./claude/mods/dotfiles --ablation none --no-publish --tag report-to-user-output --allow-tools Write
```

結果は `evals/results/` に出力され、Git の管理対象外となる。
