---
description: report-to-user の報告シートのテスト（長い報告）
tags: [report-to-user-output]
plugins: ["../../.."]
runs: 2
max_turns: 8
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill, Write]
---

次の 6 つのシェル関数がそれぞれ何をするか、危ない点があるかを一覧にして。報告シートを作るなら、作業ディレクトリに保存して。

bk() { cp "$1" "$1.bak"; }
clean() { rm -rf ./tmp/*; }
port() { lsof -i :"$1"; }
gpush() { git push -f origin HEAD; }
envload() { export $(cat .env | xargs); }
mkcd() { mkdir -p "$1" && cd "$1"; }
