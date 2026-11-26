---
name: second-opinion
description: 設計の選択、障害原因の特定、コードレビューの結論に自信が持てないとき、または別のエージェントの意見を求められたときに使う。同じ問いを読み取り専用の Codex に渡し、根拠を突き合わせる。実装計画や担当分けだけを求められたとき、障害の再現やログの確認で原因を絞れる段階では使わない。
---

# second-opinion

設計判断、原因の特定、レビューの結論を出す前に、Codex に同じ問いを渡す。障害の再現やログの確認は `root-cause-debug` の手順で進め、調べても残った論点を渡す。実装計画や通常の査読には `plan-and-delegate` の手順を使う。

## 1. 問いをファイルに書く

自分の暫定結論は手元に控える。一時ディレクトリに UTF-8 の Markdown ファイルを作り、次の内容を書く。

- 元の問い、前提と制約、分かっている事実
- 対象のファイルや差分、再現条件など、Codex が根拠を確認するために必要な情報
- 確かめてほしい点。結論と根拠の `file:line`、判断に足りない情報を返すよう頼む

独立した答えを得るため、自分の暫定結論は問いに含めない。ファイルや外部サービスを変更せず、ローカルの読み取りで調べるよう指示する。

## 2. Codex に渡す

対象の worktree で実行する。PowerShell 7 では問いのファイルのパスを `$questionPath` に入れ、標準入力で渡す。

```powershell
Get-Content -LiteralPath $questionPath -Raw -Encoding utf8 |
    codex --ask-for-approval never exec --sandbox read-only --disable hooks --ephemeral -
```

`--sandbox read-only`（短縮形 `-s read-only`）で Codex のシェルを読み取り専用にする。実行に失敗したら理由を伝え、書き込み権限を広げずに進める。

## 3. 自分の結論と突き合わせる

自分と Codex が一致した点、結論や根拠が異なる点、Codex だけが指摘した点を分けて報告する。差があれば指摘された箇所を自分で読み、元の仕様やログに照らす。採用する結論と根拠を示し、確かめられない点は未確認として残す。
