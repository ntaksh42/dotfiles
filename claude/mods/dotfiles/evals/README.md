# approval-gate の発動テスト

リポジトリルートから実行する（モデル呼び出しを伴う）。

```powershell
claude plugin eval ./claude/mods/dotfiles --ablation none --no-publish
```

全ケースの grader は `tool_used: Skill` で、`approval-gate` の呼び出し有無を検査する。既定の `with-without` ではこの grader が採点対象から外れるため、`--ablation none` を必ず指定する。Crit の起動や承認後の動作は検査しない。

未知の言い回しを使った holdout ケースだけ実行する場合：

```powershell
claude plugin eval ./claude/mods/dotfiles --ablation none --no-publish --tag holdout
```

結果は `evals/results/` に出力され、Git の管理対象外となる。
