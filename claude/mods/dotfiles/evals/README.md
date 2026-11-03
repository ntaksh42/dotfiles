# request-user-check の評価

リポジトリルートから実行する（モデル呼び出しを伴う）。発動テストは20件、出力テストは2件ある。

## 発動テスト

発動テストは `tool_used: Skill` で `request-user-check` の呼び出し有無を検査する。既定の `with-without` ではこの grader が採点対象から外れるため、`--ablation none` を必ず指定する。

```powershell
claude plugin eval ./claude/mods/dotfiles --ablation none --no-publish --tag request-user-check
```

未知の言い回しを使った holdout ケースだけ実行する場合：

```powershell
claude plugin eval ./claude/mods/dotfiles --ablation none --no-publish --tag holdout
```

## 出力テスト

出力テストは `tool_used: Write` で、HTMLファイルへの書き込み有無のみを確認する。HTMLの内容、ブラウザ表示、承認後の動作は検査しない。`Write` は実行側でも許可が必要。

```powershell
claude plugin eval ./claude/mods/dotfiles --ablation none --no-publish --tag request-user-check-output --allow-tools Write
```

結果は `evals/results/` に出力され、Git の管理対象外となる。
