import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'
import { decideCodex } from './codex-check.mjs'

const stop = { hook_event_name: 'Stop', turn_id: 'turn-1', stop_hook_active: false }
const patch = {
  hook_event_name: 'PreToolUse',
  turn_id: 'turn-1',
  tool_name: 'apply_patch',
  tool_input: {
    command: [
      '*** Begin Patch',
      '*** Update File: examples/notes.txt',
      '@@',
      '-old text',
      '+手順を追加します。',
      '*** End Patch',
    ].join('\n'),
  },
}
const prompt = { type: 'event_msg', payload: { type: 'user_message', message: 'Please update the project' } }
const edit = { type: 'response_item', payload: { type: 'custom_tool_call', name: 'apply_patch', input: patch.tool_input.command } }
const shell = cmd => ({
  type: 'response_item',
  payload: { type: 'function_call', name: 'exec_command', arguments: JSON.stringify({ cmd }) },
})
const rollout = (...entries) => entries.map(entry => JSON.stringify(entry)).join('\n')

test('Codex Stop emits continuation JSON and defers when the turn created a sheet', () => {
  const input = { ...stop, last_assistant_message: 'a'.repeat(401) }
  const process = spawnSync('node', [fileURLToPath(new URL('./codex-check.mjs', import.meta.url)), 'reply-check'], {
    input: JSON.stringify(input),
    encoding: 'utf8',
  })
  assert.equal(process.status, 0)
  assert.equal(JSON.parse(process.stdout).decision, 'block')
  assert.equal(decideCodex('reply-check', input, rollout(prompt, shell('python scripts/new-sheet.py -'))), undefined)
  assert.equal(decideCodex('reply-check', { ...input, stop_hook_active: true }), undefined)
})

test('Codex Stop detects edits and verification in the current turn', () => {
  const input = { ...stop, last_assistant_message: '実装しました。' }
  assert.equal(decideCodex('verify-check', input, rollout(shell('node --test'), prompt, edit)).decision, 'block')
  assert.equal(decideCodex('verify-check', input, rollout(prompt, edit, shell('node --test'))), undefined)
  assert.equal(decideCodex('verify-check', input, rollout(prompt, edit, shell('Get-Content C:/skills/verify-before-done/SKILL.md'))), undefined)
  assert.equal(decideCodex('verify-check', input, rollout(prompt)), undefined)
})

test('Codex PreToolUse checks added Japanese text in each document patch', () => {
  const result = decideCodex('japanese-check', patch, rollout(prompt))
  assert.equal(result.hookSpecificOutput.hookEventName, 'PreToolUse')
  assert.equal(result.hookSpecificOutput.permissionDecision, 'deny')
  assert.match(result.hookSpecificOutput.permissionDecisionReason, /japanese の SKILL\.md/)
  assert.equal(decideCodex('japanese-check', patch, rollout(shell('cat /skills/japanese/SKILL.md'), prompt)), undefined)
  assert.equal(decideCodex('japanese-check', { ...patch, agent_id: 'child' }, rollout(prompt)), undefined)
  for (const command of [
    patch.tool_input.command.replace('notes.txt', 'notes.js'),
    patch.tool_input.command.replace('-old text\n+手順を追加します。', '-手順を追加します。\n+new text'),
  ]) {
    assert.equal(decideCodex('japanese-check', { ...patch, tool_input: { command } }, rollout(prompt)), undefined)
  }
})

test('Codex PreToolUse accepts Bash tool input for Japanese issue text', () => {
  const input = { ...patch, tool_name: 'Bash', tool_input: { command: 'gh issue edit 10 --body "手順を追加します。"' } }
  assert.equal(decideCodex('japanese-check', input, rollout(prompt)).hookSpecificOutput.permissionDecision, 'deny')
})
