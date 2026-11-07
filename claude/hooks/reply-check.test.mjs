// 実行: node --test claude/hooks/reply-check.test.mjs
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { calledSkillThisTurn, decide, measure } from './reply-check.mjs'

const user = text => JSON.stringify({ type: 'user', message: { role: 'user', content: [{ type: 'text', text }] } })
const skillCall = name => JSON.stringify({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', name: 'Skill', input: { skill: name } }] } })
const meta = text => JSON.stringify({ type: 'user', isMeta: true, message: { role: 'user', content: [{ type: 'text', text }] } })
const toolResult = () => JSON.stringify({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', content: 'ok' }] } })

const long = Array.from({ length: 8 }, (_, i) => `行${i + 1}`).join('\n')

test('短い返信は通す', () => {
  assert.equal(decide({ last_assistant_message: '結論です。\n続きです。' }, ''), undefined)
})

test('7 行以上は止める', () => {
  assert.equal(decide({ last_assistant_message: long }, '').decision, 'block')
})

test('表は短くても止める', () => {
  assert.equal(decide({ last_assistant_message: '| a | b |\n|---|---|\n| 1 | 2 |' }, '').decision, 'block')
})

test('箇条書き 3 つで止める、2 つは通す', () => {
  assert.equal(decide({ last_assistant_message: '- a\n- b\n- c' }, '').decision, 'block')
  assert.equal(decide({ last_assistant_message: '- a\n- b' }, ''), undefined)
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
  const transcript = [user('調べて'), skillCall('dotfiles:request-user-check'), meta('Base directory for this skill'), toolResult()].join('\n')
  assert.equal(calledSkillThisTurn(transcript.split('\n')), true)
  assert.equal(decide({ last_assistant_message: long }, transcript), undefined)
})

test('HTML のシートを書いたターンは、skill を呼び直さなくても通す', () => {
  const write = JSON.stringify({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', name: 'Write', input: { file_path: 'C:/tmp/report.html' } }] } })
  const transcript = [user('調べて'), write].join('\n')
  assert.equal(decide({ last_assistant_message: long }, transcript), undefined)
})

test('前のターンで呼んだだけなら止める', () => {
  const transcript = [user('前の依頼'), skillCall('dotfiles:request-user-check'), user('次の依頼')].join('\n')
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
