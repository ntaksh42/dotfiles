import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'

import { blockReason, countLines, currentTurn, usedSkill } from '../report-guard.mjs'

const SCRIPT = join(dirname(fileURLToPath(import.meta.url)), '..', 'report-guard.mjs')
const jsonl = entries => entries.map(e => JSON.stringify(e)).join('\n')
const user = text => ({ type: 'user', message: { role: 'user', content: text } })
const toolResult = () => ({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't', content: 'ok' }] } })
const meta = text => ({ type: 'user', isMeta: true, message: { role: 'user', content: [{ type: 'text', text }] } })
const assistant = (...content) => ({ type: 'assistant', message: { role: 'assistant', content } })
const skillCall = skill => ({ type: 'tool_use', id: 't', name: 'Skill', input: { skill } })
const text = t => ({ type: 'text', text: t })
const long = Array.from({ length: 12 }, (_, i) => `行${i}`).join('\n')

test('空行は数えない', () => {
  assert.equal(countLines('a\n\n b \n\n'), 2)
})

test('現在のターンは最後の依頼から始まる (ツール結果とスキル本文は依頼とみなさない)', () => {
  const turn = currentTurn(jsonl([user('前'), assistant(skillCall('dotfiles:request-user-check')), user('今'), toolResult(), meta('skill body')]))
  assert.equal(turn.length, 3)
  assert.equal(usedSkill(turn), false)
})

test('このターンでスキルを呼んでいれば差し戻さない', () => {
  const t = jsonl([user('調べて'), assistant(skillCall('dotfiles:request-user-check')), toolResult(), meta('skill body'), assistant(text(long))])
  assert.equal(blockReason({ last_assistant_message: long }, t), undefined)
})

test('スキルを呼ばずに長い返答なら差し戻す', () => {
  const t = jsonl([user('調べて'), assistant(text(long))])
  assert.match(blockReason({ last_assistant_message: long }, t), /12 行/)
})

test('last_assistant_message が無ければ transcript の最後の返答で数える', () => {
  assert.ok(blockReason({}, jsonl([user('調べて'), assistant(text(long))])))
})

test('短い返答・差し戻し後・subagent は差し戻さない', () => {
  const t = jsonl([user('ありがとう'), assistant(text('どういたしまして'))])
  assert.equal(blockReason({ last_assistant_message: 'どういたしまして' }, t), undefined)
  assert.equal(blockReason({ last_assistant_message: long, stop_hook_active: true }, t), undefined)
  assert.equal(blockReason({ last_assistant_message: long, agent_id: 'a1' }, t), undefined)
})

test('/dotfiles:request-user-check と打たれたターンは差し戻さない', () => {
  const t = jsonl([user('<command-name>/dotfiles:request-user-check</command-name>'), assistant(text(long))])
  assert.equal(blockReason({ last_assistant_message: long }, t), undefined)
})

const run = (mode, input, env = {}) =>
  execFileSync(process.execPath, [SCRIPT, mode], { input: JSON.stringify(input), env: { ...process.env, CLAUDE_CODE_ENTRYPOINT: 'cli', ...env } }).toString()

test('prompt はユーザーの依頼にだけ注意書きを足す', () => {
  const out = JSON.parse(run('prompt', { prompt: 'こんにちは' }))
  assert.match(out.hookSpecificOutput.additionalContext, /request-user-check/)
  assert.equal(run('prompt', { prompt: 'x', source: 'task' }), '')
})

test('stop は CLI 経由で差し戻し、無人実行では何もしない', () => {
  const path = join(mkdtempSync(join(tmpdir(), 'report-guard-')), 't.jsonl')
  writeFileSync(path, jsonl([user('調べて'), assistant(text(long))]))
  assert.equal(JSON.parse(run('stop', { transcript_path: path, last_assistant_message: long })).decision, 'block')
  assert.equal(run('stop', { transcript_path: path, last_assistant_message: long }, { CLAUDE_CODE_ENTRYPOINT: 'sdk-cli' }), '')
})
