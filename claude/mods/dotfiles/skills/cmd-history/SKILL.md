---
name: cmd-history
description: PowerShell（PSReadLine）のコマンド履歴を新しい順に一覧し、語で絞り込む。「PowerShell の履歴」「さっき打ったコマンド」「あのコマンドなんだっけ」「cmdHistory」と言われたとき、/dotfiles:cmd-history で使う。mod が使えない環境向けの /cmdHistory の代替。
argument-hint: "[絞り込む語]"
---

# cmd-history

PowerShell の履歴ファイルを新しい順・重複なしで一覧する。

1. 次のコマンドを実行する。引数があれば絞り込む語として渡す（空白区切りの語をすべて含む項目、大文字小文字は区別しない）。

   ```
   pwsh -NoProfile -File <skill-dir>/scripts/history.ps1 [語...]
   ```

   `pwsh` が無い環境では `powershell.exe -NoProfile -File ...` を使う。

2. 出力をそのまま番号付きで見せる。件数が多いときは先頭 30 件に留め、絞り込む語を足すよう案内する。
3. ユーザーが番号を選んだら、そのコマンドを `!` を付けずにコードブロックで見せる。実行はユーザーの依頼があってからにする。
