// 実行: node --test claude/hooks/verify-check.test.mjs
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { claimsDone, decide, isVerifyCommand } from './verify-check.mjs'

const user = text => JSON.stringify({ type: 'user', message: { role: 'user', content: [{ type: 'text', text }] } })
const tool = (name, input) => JSON.stringify({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', name, input }] } })
const result = () => JSON.stringify({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', content: 'ok' }] } })

const edit = tool('Edit', { file_path: 'a.ts', old_string: 'a', new_string: 'b' })
const done = { last_assistant_message: '修正しました。' }

test('ファイルを変え、検証せずに完了と書いたら止める', () => {
  assert.equal(decide(done, [user('直して'), edit, result()].join('\n')).decision, 'block')
})

test('検証コマンドを実行したか、verify-before-done を読み込んだら通す', () => {
  assert.equal(decide(done, [user('直して'), edit, result(), tool('Bash', { command: 'node --test "claude/hooks/*.test.mjs"' })].join('\n')), undefined)
  assert.equal(decide(done, [user('直して'), edit, tool('Skill', { skill: 'verify-before-done' })].join('\n')), undefined)
})

test('検証が前のターンだけなら止める', () => {
  const t = [user('テストして'), tool('Bash', { command: 'npm test' }), user('直して'), edit].join('\n')
  assert.equal(decide(done, t).decision, 'block')
})

test('このターンにファイルを変えていなければ通す', () => {
  assert.equal(decide(done, [user('状況は？'), tool('Read', { file_path: 'a.ts' })].join('\n')), undefined)
})

test('未検証と断っていれば通す', () => {
  assert.equal(claimsDone('修正しました。実機では未検証です。'), false)
  assert.equal(claimsDone('追加しました。発火するかは試していません。'), false)
})

test('完了の言い方が無ければ通す', () => {
  assert.equal(claimsDone('どちらの案にしますか。'), false)
  assert.equal(claimsDone('```\nfixed\n```\n差分を見てください。'), false)
})

test('stop_hook_active とサブエージェントは通す', () => {
  const t = [user('直して'), edit].join('\n')
  assert.equal(decide({ ...done, stop_hook_active: true }, t), undefined)
  assert.equal(decide({ ...done, agent_id: 'x' }, t), undefined)
})

test('検証らしいコマンドの判定', () => {
  for (const c of ['pytest -q', 'python -m pytest tests', 'pnpm run build', 'cargo test', 'pwsh -File tools/Test-ClaudeMods.ps1', 'claude plugin validate x'])
    assert.equal(isVerifyCommand(c), true, c)
  for (const c of ['git status', 'ls', 'cat test.txt'])
    assert.equal(isVerifyCommand(c), false, c)
})
