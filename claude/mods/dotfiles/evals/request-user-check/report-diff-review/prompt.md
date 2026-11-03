---
description: request-user-check の発動テスト（pos）
tags: [request-user-check, trigger, pos]
plugins: ["../../.."]
runs: 2
max_turns: 6
timeout_seconds: 240
allowed_tools: [Read, Glob, Grep, Skill]
---

この差分をレビューして。

```diff
-  const timeout = 3000;
+  const timeout = process.env.TIMEOUT || 3000;
   const res = await fetch(url, { signal: AbortSignal.timeout(timeout) });
```
