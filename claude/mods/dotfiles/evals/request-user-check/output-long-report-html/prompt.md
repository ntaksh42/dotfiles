---
description: request-user-check の報告シートのテスト（長い報告）
tags: [request-user-check-output]
plugins: ["../../.."]
runs: 2
max_turns: 8
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill, Write]
---

次の 6 つのシェル関数がそれぞれ何をするか、危ない点があるかを一覧にして。

bk() { cp "$1" "$1.bak"; }
clean() { rm -rf ./tmp/*; }
port() { lsof -i :"$1"; }
gpush() { git push -f origin HEAD; }
envload() { export $(cat .env | xargs); }
mkcd() { mkdir -p "$1" && cd "$1"; }
