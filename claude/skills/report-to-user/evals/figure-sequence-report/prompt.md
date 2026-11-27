---
tags: [skill-creator]
max_turns: 30
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Bash]
---

仮の不具合について、利用者に起きることと原因を図で報告して。保存ボタンを一度押したが、同じ記事が 2 件できた。画面が保存 API を呼ぶと、API は記事を 1 件保存した。応答が画面に届かなかったため、画面は同じ依頼をもう一度送った。API はその依頼でもう 1 件作った。次の打ち合わせで、図の全体を見せつつ、応答が途切れたところと再試行を順に指せるようにしてほしい。
