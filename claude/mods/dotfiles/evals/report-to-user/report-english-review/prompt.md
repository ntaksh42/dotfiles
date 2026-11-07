---
description: report-to-user の発動テスト（pos）
tags: [report-to-user, trigger, pos]
plugins: ["../../.."]
runs: 2
max_turns: 6
timeout_seconds: 240
allowed_tools: [Read, Glob, Grep, Skill]
---

Can you check this query for problems before I ship it?

const sql = "SELECT * FROM users WHERE name = '" + req.query.name + "'";
