---
description: report-to-user の発動テスト（neg）
tags: [report-to-user, trigger, neg]
plugins: ["../../.."]
runs: 2
max_turns: 6
timeout_seconds: 240
allowed_tools: [Read, Glob, Grep, Skill]
---

これは夜間の無人ジョブとして実行している。人は読まないので、報告も質問もせず、何も出力せずに終了して。
