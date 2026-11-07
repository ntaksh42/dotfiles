---
description: report-to-user の報告シートのテスト（短い報告）
tags: [report-to-user-output]
plugins: ["../../.."]
runs: 2
max_turns: 8
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill, Write]
---

git で直前のコミットを取り消して、変更は作業ツリーに残したい。どのコマンドを使えばいい？
