---
description: report-to-user の発動テスト（pos）
tags: [report-to-user, trigger, pos]
plugins: ["../../.."]
runs: 2
max_turns: 6
timeout_seconds: 240
allowed_tools: [Read, Glob, Grep, Skill]
---

git で直前のコミットを取り消して、変更は作業ツリーに残したい。どのコマンドを使えばいい？
