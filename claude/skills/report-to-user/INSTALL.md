# report-to-user — 報告・相談・HTMLレポート

Claude Code / Codex共通のスキルです。短い報告は会話で、詳しい調査・レビューはHTMLレポートで、見た目を比べる相談は比較シートで返します。

## 導入

このリポジトリでは `claude/skills/report-to-user/` が管理元です。通常の配布はpush後の `Install-DevTools` で行います。単体導入はこのフォルダを利用するエージェントのskillsディレクトリへコピーします。配置後はエージェントを再起動してください。

報告シートの生成と比較シートの機械検査にはPython 3、詳細レポートの生成にはPowerShell 7 (`pwsh`) を使います。パスはスキルの配置先から相対で解決するため、Claude / Codexのどちらにも配置できます。

## 使い方

- 長くなる作業報告・相談: `scripts/new-sheet.py` で報告シートを作り、会話には結論とシートの場所だけを書く。
- 「結果をHTMLにまとめて」: `output-config.toml` の保存先へ種別別・自動採番で保存。
- 「作る前にUIの2案を見せて」: 比較シートに論点ごとの推奨を書いて見せ、答えを会話で受ける。
- 短い完了報告: 行数・テスト件数だけでHTML化せず、会話で返す。

必要な承認は返答を待ちます。無回答を推奨案への同意とは扱いません。承認済みの範囲内で確認を繰り返しません。

## 構成と検証

`SKILL.md` が入口、`references/` が用途別の手順です。報告シートは `scripts/new-sheet.py` (Python 3) が `templates/sheet.html` に流し込み、`assets/check-sheet.py` で検査します。詳細レポートは `scripts/New-HtmlReport.ps1` と `templates/base.html` で作ります。比較シートは `assets/sheet-template.html` を埋めて `assets/check-sheet.py` で検査します。

```powershell
python -m unittest tests/test_new_sheet.py
pwsh -NoProfile -File tests/Test-Parser.ps1
pwsh -NoProfile -File tests/Test-Generator.ps1
```

Mermaidを使う場合だけCDNへの接続が必要です。オフラインで図も残す場合はSVGを使います。

License: MIT
