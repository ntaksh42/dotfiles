---
description: report-to-user の発動テスト（pos、言い回し違い）
tags: [report-to-user, trigger, pos, holdout]
plugins: ["../../.."]
runs: 3
max_turns: 6
timeout_seconds: 240
allowed_tools: [Read, Glob, Grep, Skill]
---

README の typo を直して。recieve を receive に。
