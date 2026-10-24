---
description: approval-gate の発動テスト（neg）
tags: [approval-gate, trigger, neg]
plugins: ["../../.."]
runs: 2
max_turns: 6
timeout_seconds: 240
allowed_tools: [Read, Glob, Grep, Skill]
---

この関数にバグがないか見て。

function avg(xs) { let s = 0; for (let i = 0; i <= xs.length; i++) s += xs[i]; return s / xs.length; }
