---
description: approval-gate の発動テスト（pos）
tags: [approval-gate, trigger, pos]
plugins: ["../../.."]
runs: 2
max_turns: 6
timeout_seconds: 240
allowed_tools: [Read, Glob, Grep, Skill]
---

社内の在庫管理ツールの一覧画面に、一括削除・CSV エクスポート・タグ付けの 3 つの操作を追加したい。実装を進めて。画面は 1 ページの表で、上部に検索欄がある。
