---
description: approval-gate の発動テスト（pos、言い回し違い）
tags: [approval-gate, trigger, pos, holdout]
plugins: ["../../.."]
runs: 3
max_turns: 6
timeout_seconds: 240
allowed_tools: [Read, Glob, Grep, Skill]
---

スマホアプリの下部タブ（今は ホーム・検索・通知・設定 の 4 つ）に「お気に入り」を足したい。いい感じに組み込んで実装して。
