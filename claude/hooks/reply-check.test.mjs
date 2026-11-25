// 実行: node --test claude/hooks/reply-check.test.mjs
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import { calledSkillThisTurn, decide, isWrapUp, measure, remind, remindAtWrapUp } from './reply-check.mjs'

const user = text => JSON.stringify({ type: 'user', message: { role: 'user', content: [{ type: 'text', text }] } })
const skillCall = name => JSON.stringify({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', name: 'Skill', input: { skill: name } }] } })
const meta = text => JSON.stringify({ type: 'user', isMeta: true, message: { role: 'user', content: [{ type: 'text', text }] } })
const toolResult = () => JSON.stringify({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', content: 'ok' }] } })

const long = Array.from({ length: 9 }, (_, i) => `行${i + 1}`).join('\n')

test('短い返信は通す', () => {
  assert.equal(decide({ last_assistant_message: '結論です。\n続きです。' }, ''), undefined)
})

test('結論 + 8 行は止める、結論 + 7 行は通す', () => {
  assert.equal(decide({ last_assistant_message: long }, '').decision, 'block')
  assert.equal(decide({ last_assistant_message: '結論\na\nb\nc\nd\ne\nf\ng\nh' }, '').decision, 'block')
  assert.equal(decide({ last_assistant_message: '結論\na\nb\nc\nd\ne\nf\ng' }, ''), undefined)
})

test('空白を除いて 400 字を超えたら止める、400 字は通す', () => {
  assert.equal(decide({ last_assistant_message: 'あ'.repeat(401) }, '').decision, 'block')
  assert.equal(decide({ last_assistant_message: `- ${'あ'.repeat(200)}\n- ${'い'.repeat(198)}` }, ''), undefined)
  assert.equal(measure('a b\n\n```\n' + 'x'.repeat(500) + '\n```').chars, 2)
})

test('表は短くても止める', () => {
  assert.equal(decide({ last_assistant_message: '| a | b |\n|---|---|\n| 1 | 2 |' }, '').decision, 'block')
})

test('箇条書き 6 つで止める、5 つは通す', () => {
  assert.equal(decide({ last_assistant_message: '- a\n- b\n- c\n- d\n- e\n- f' }, '').decision, 'block')
  assert.equal(decide({ last_assistant_message: '- a\n- b\n- c\n- d\n- e' }, ''), undefined)
})

test('コードブロックの中は数えない', () => {
  const code = '```\n' + long + '\n```\n結論です。'
  assert.equal(measure(code).lines, 1)
  assert.equal(decide({ last_assistant_message: code }, ''), undefined)
})

test('stop_hook_active とサブエージェントでは止めない', () => {
  assert.equal(decide({ last_assistant_message: long, stop_hook_active: true }, ''), undefined)
  assert.equal(decide({ last_assistant_message: long, agent_id: 'a1' }, ''), undefined)
})

test('シートを出した返信 (::orca-visual) は通す', () => {
  assert.equal(decide({ last_assistant_message: `${long}\n::orca-visual{file="a.html" title="t"}` }, ''), undefined)
})

test('このターンで skill を呼んでいれば通す', () => {
  const transcript = [user('調べて'), skillCall('report-to-user'), meta('Base directory for this skill'), toolResult()].join('\n')
  assert.equal(calledSkillThisTurn(transcript.split('\n')), true)
  assert.equal(decide({ last_assistant_message: long }, transcript), undefined)
})

test('HTML のシートを書いたターンは、skill を呼び直さなくても通す', () => {
  const write = JSON.stringify({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', name: 'Write', input: { file_path: 'C:/tmp/report.html' } }] } })
  const transcript = [user('調べて'), write].join('\n')
  assert.equal(decide({ last_assistant_message: long }, transcript), undefined)
})

test('生成器 (new-sheet.py) でシートを作ったターンは通す', () => {
  const run = JSON.stringify({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', name: 'Bash', input: { command: 'python "x/scripts/new-sheet.py" - --name a' } }] } })
  const transcript = [user('調べて'), run].join('\n')
  assert.equal(decide({ last_assistant_message: long }, transcript), undefined)
})

test('前のターンで呼んだだけなら止める', () => {
  const transcript = [user('前の依頼'), skillCall('report-to-user'), user('次の依頼')].join('\n')
  assert.equal(calledSkillThisTurn(transcript.split('\n')), false)
  assert.equal(decide({ last_assistant_message: long }, transcript).decision, 'block')
})

test('REPLY_CHECK=off で無効', () => {
  process.env.REPLY_CHECK = 'off'
  try {
    assert.equal(decide({ last_assistant_message: long }, ''), undefined)
  } finally {
    delete process.env.REPLY_CHECK
  }
})

test('UserPromptSubmit では基準を差し込む', () => {
  const out = remind({ hook_event_name: 'UserPromptSubmit' })
  assert.equal(out.hookSpecificOutput.hookEventName, 'UserPromptSubmit')
  assert.match(out.hookSpecificOutput.additionalContext, /3 行・200 字までを目安/)
  assert.match(out.hookSpecificOutput.additionalContext, /400 字/)
  assert.match(out.hookSpecificOutput.additionalContext, /report-to-user/)
})

test('会話の目安は共通ルール・choose-form.py・差し込み文で同じ値', () => {
  const root = new URL('../../', import.meta.url)
  const rules = readFileSync(new URL('claude/CLAUDE.global.md', root), 'utf8')
  const form = readFileSync(new URL('claude/skills/report-to-user/scripts/choose-form.py', root), 'utf8')
  const ctx = remind({ hook_event_name: 'UserPromptSubmit' }).hookSpecificOutput.additionalContext
  const [, lines, chars] = ctx.match(/結論 1 文と (\d+) 行・(\d+) 字までを目安/)
  assert.match(rules, new RegExp(`結論の 1 文と ${lines} 行・${chars} 字に収まる`))
  assert.match(form, new RegExp(`^CHAT_LINES = ${lines}$`, 'm'))
  assert.match(form, new RegExp(`^CHAT_CHARS = ${chars}$`, 'm'))
})

test('サブエージェントと REPLY_CHECK=off では差し込まない', () => {
  assert.equal(remind({ agent_id: 'a' }), undefined)
  process.env.REPLY_CHECK = 'off'
  try {
    assert.equal(remind({}), undefined)
  } finally {
    delete process.env.REPLY_CHECK
  }
})

test('URL・リンク先・Markdown の記号は字数に入れない', () => {
  assert.equal(measure('PR: https://github.com/o/r/pull/1').chars, 3)
  assert.equal(measure('[PR #1](https://github.com/o/r/pull/1) を出した').chars, 8)
  assert.equal(measure('**原因**は `a.mjs` です').chars, 10)
  assert.equal(measure('- あ\n1. い\n## う\n> え').chars, 4)
  // 字数で止まるのは本文が長いときだけ (URL が長くても止めない)
  const withUrl = `${'あ'.repeat(250)} https://example.com/${'x'.repeat(200)}`
  assert.equal(decide({ last_assistant_message: withUrl }, ''), undefined)
})

test('コミット・push・PR 作成の直後に基準を差し込む', () => {
  assert.equal(isWrapUp('Bash', { command: 'git commit -m "x"' }), true)
  assert.equal(isWrapUp('Bash', { command: 'git -C repo push -u origin b' }), true)
  assert.equal(isWrapUp('PowerShell', { command: 'gh pr create --fill' }), true)
  assert.equal(isWrapUp('mcp__github__create_pull_request', {}), true)
  assert.equal(isWrapUp('Bash', { command: 'git status' }), false)
  assert.equal(isWrapUp('Bash', { command: 'node --test' }), false)
  assert.equal(isWrapUp('Edit', { command: 'git commit' }), false)
  const out = remindAtWrapUp({ hook_event_name: 'PostToolUse', tool_name: 'Bash', tool_input: { command: 'git push' } })
  assert.equal(out.hookSpecificOutput.hookEventName, 'PostToolUse')
  assert.match(out.hookSpecificOutput.additionalContext, /3 行・200 字までを目安/)
  assert.match(out.hookSpecificOutput.additionalContext, /変更したファイルの一覧/)
  assert.equal(remindAtWrapUp({ tool_name: 'Bash', tool_input: { command: 'ls' } }), undefined)
  assert.equal(remindAtWrapUp({ agent_id: 'a', tool_name: 'Bash', tool_input: { command: 'git push' } }), undefined)
})
