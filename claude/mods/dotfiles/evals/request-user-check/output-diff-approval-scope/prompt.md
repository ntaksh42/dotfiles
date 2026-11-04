---
description: request-user-check の出力テスト（書いたコードのコミット前確認で、最初に見る行と触っていない範囲を示す）
tags: [request-user-check-output]
plugins: ["../../.."]
runs: 2
max_turns: 8
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill, Write]
---

src/config.js を新しく作り、JSON の設定ファイルを読む関数 loadConfig(path) を書いて。ファイルが無いときは既定値 { timeout: 3000 } を返すこと。書いたら、コミットする前に確認させて。
