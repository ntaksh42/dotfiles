---
description: request-user-check の発動テスト（pos）
tags: [request-user-check, trigger, pos]
plugins: ["../../.."]
runs: 2
max_turns: 6
timeout_seconds: 240
allowed_tools: [Read, Glob, Grep, Skill]
---

次の 6 つのシェル関数がそれぞれ何をするか、危ない点があるかを一覧にして。

bk() { cp "$1" "$1.bak"; }
clean() { rm -rf ./tmp/*; }
port() { lsof -i :"$1"; }
gpush() { git push -f origin HEAD; }
envload() { export $(cat .env | xargs); }
mkcd() { mkdir -p "$1" && cd "$1"; }
