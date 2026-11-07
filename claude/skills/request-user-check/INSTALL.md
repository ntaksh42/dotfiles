# request-user-check — 報告・相談・HTMLレポート

Claude Code / Codex共通のスキルです。短い報告は会話で、詳しい調査・レビューはHTMLレポートで、見た目を比べる相談は比較シートで返します。

## 導入

このリポジトリでは `claude/skills/request-user-check/` が管理元です。通常の配布はpush後の `Install-DevTools` で行います。単体導入はこのフォルダを利用するエージェントのskillsディレクトリへコピーします。配置後はエージェントを再起動してください。

詳細レポートの生成にはPowerShell 7 (`pwsh`)、比較シートの機械検査にはPython 3を使います。パスはスキルの配置先から相対で解決するため、Claude / Codexのどちらにも配置できます。

## 使い方

- 「結果をHTMLにまとめて」: `output-config.toml` の保存先へ種別別・自動採番で保存。
- 「作る前にUIの2案を見せて」: 比較シートを作り、推奨付きの [判断] を会話で聞く。
- 短い完了報告: 行数・テスト件数だけでHTML化せず、会話で返す。

必要な承認は返答を待ちます。無回答を推奨案への同意とは扱いません。承認済みの範囲内で確認を繰り返しません。

## 構成と検証

`SKILL.md` が入口、`references/` が用途別手順、`scripts/` と `templates/` が詳細レポート生成器、`assets/` が比較・簡易シートと検査器です。旧 `html-report` / `save-report` の機能を統合しています。既存スキルが併存していても同じ報告を重複生成しません。

```powershell
pwsh -NoProfile -File tests/Test-Parser.ps1
pwsh -NoProfile -File tests/Test-Generator.ps1
```

Mermaidを使う場合だけCDNへの接続が必要です。オフラインで図も残す場合はSVGを使います。

License: MIT
