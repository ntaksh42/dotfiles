---
description: approval-gate の発動テスト（neg、言い回し違い）
tags: [approval-gate, trigger, neg, holdout]
plugins: ["../../.."]
runs: 3
max_turns: 6
timeout_seconds: 240
allowed_tools: [Read, Glob, Grep, Skill]
---

README の typo を直して。recieve を receive に。
