---
description: approval-gate の発動テスト（pos）
tags: [approval-gate, trigger, pos]
plugins: ["../../.."]
runs: 2
max_turns: 6
timeout_seconds: 240
allowed_tools: [Read, Glob, Grep, Skill]
---

README の新しい原稿を書いた。公開する前に、原稿に直接コメントする形で指摘がほしい。原稿は次のとおり。

# fastq-tools
FASTQ ファイルを高速に処理するためのツール群です。インストールは pip install fastq-tools で行えます。使い方は fastq-tools --help を見てください。
