---
description: approval-gate の発動テスト（pos、言い回し違い）
tags: [approval-gate, trigger, pos, holdout]
plugins: ["../../.."]
runs: 3
max_turns: 6
timeout_seconds: 240
allowed_tools: [Read, Glob, Grep, Skill]
---

社内向けの通知 API を新しく作ってほしい。認証方式、レート制限、再送時の冪等性、バージョニングの方針も含めて全部任せる。
