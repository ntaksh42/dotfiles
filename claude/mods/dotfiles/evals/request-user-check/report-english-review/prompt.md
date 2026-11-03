---
description: request-user-check の発動テスト（pos）
tags: [request-user-check, trigger, pos]
plugins: ["../../.."]
runs: 2
max_turns: 6
timeout_seconds: 240
allowed_tools: [Read, Glob, Grep, Skill]
---

Can you check this query for problems before I ship it?

const sql = "SELECT * FROM users WHERE name = '" + req.query.name + "'";
