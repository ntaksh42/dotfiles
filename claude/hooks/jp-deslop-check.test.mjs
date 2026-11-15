// 実行: node --test claude/hooks/jp-deslop-check.test.mjs
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { decide, isMultilineCommit, loadedSkill, needsSkill } from './jp-deslop-check.mjs'

const user = text => JSON.stringify({ type: 'user', message: { role: 'user', content: [{ type: 'text', text }] } })
const skillCall = name => JSON.stringify({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', name: 'Skill', input: { skill: name } }] } })
const slash = name => JSON.stringify({ type: 'user', message: { role: 'user', content: `<command-message>${name}</command-message>\n<command-name>/${name}</command-name>` } })

const writeMd = { tool_name: 'Write', tool_input: { file_path: 'E:/x/README.md', content: '# 見出し\n\n説明を書きます。' } }

test('日本語の .md への Write は、未読なら止める', () => {
  assert.equal(decide(writeMd, user('README を書いて')).hookSpecificOutput.permissionDecision, 'deny')
})

test('Skill で読み込んだ後と /jp-deslop の後は通す', () => {
  assert.equal(decide(writeMd, [user('書いて'), skillCall('jp-deslop')].join('\n')), undefined)
  assert.equal(decide(writeMd, [user('書いて'), skillCall('dotfiles:jp-deslop')].join('\n')), undefined)
  assert.equal(decide(writeMd, slash('jp-deslop')), undefined)
})

test('別のスキルを読んでいても止める', () => {
  assert.ok(decide(writeMd, skillCall('report-to-user')))
  assert.equal(loadedSkill([user('jp-deslop を使って')]), false)
})

test('対象外のファイルや英語だけの文章は通す', () => {
  assert.equal(needsSkill('Write', { file_path: 'a.ts', content: '// 日本語のコメント' }), false)
  assert.equal(needsSkill('Write', { file_path: 'sheet.html', content: '<p>報告です</p>' }), false)
  assert.equal(needsSkill('Write', { file_path: 'a.md', content: '# English only' }), false)
  // 漢字だけ（中国語や固有名詞）は日本語の文章とみなさない
  assert.equal(needsSkill('Write', { file_path: 'a.md', content: '中文' }), false)
})

test('Edit と MultiEdit は書き足す側を見る', () => {
  assert.equal(needsSkill('Edit', { file_path: 'docs/a.md', old_string: 'x', new_string: '追記します' }), true)
  assert.equal(needsSkill('Edit', { file_path: 'docs/a.md', old_string: '削除します', new_string: '' }), false)
  assert.equal(needsSkill('MultiEdit', { file_path: 'a.txt', edits: [{ new_string: 'a' }, { new_string: 'メモ' }] }), true)
})

test('PR・Issue の本文と複数行のコミットメッセージは止め、1 行のコミットは通す', () => {
  assert.equal(needsSkill('Bash', { command: 'gh pr create --title "修正" --body "変更点です"' }), true)
  assert.equal(needsSkill('PowerShell', { command: 'az repos pr create --description "説明です"' }), true)
  assert.equal(needsSkill('Bash', { command: 'git commit -m "fix: 直す" -m "理由を書きます"' }), true)
  assert.equal(needsSkill('Bash', { command: 'git commit -m "$(cat <<\'EOF\'\nfix: 直す\n\n理由です\nEOF\n)"' }), true)
  assert.equal(needsSkill('Bash', { command: 'git commit -m "fix: 直す"' }), false)
  assert.equal(needsSkill('Bash', { command: 'gh pr view 1  # 確認する' }), false)
})

test('isMultilineCommit は git commit より前の改行を数えない', () => {
  assert.equal(isMultilineCommit('cd x\ngit commit -m "a"'), false)
})

test('サブエージェント・無効化・transcript なしは通す', () => {
  assert.equal(decide({ ...writeMd, agent_id: 'a1' }, ''), undefined)
  assert.equal(decide(writeMd, undefined), undefined)
  process.env.JP_DESLOP_CHECK = 'off'
  try {
    assert.equal(decide(writeMd, ''), undefined)
  } finally {
    delete process.env.JP_DESLOP_CHECK
  }
})
