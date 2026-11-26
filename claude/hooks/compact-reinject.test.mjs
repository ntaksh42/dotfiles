// 実行: node --test claude/hooks/compact-reinject.test.mjs
import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'

const script = fileURLToPath(new URL('./compact-reinject.mjs', import.meta.url))
const skill = name => JSON.stringify({
  type: 'assistant',
  message: { content: [{ type: 'tool_use', name: 'Skill', input: { skill: name } }] },
})

function workspace(t) {
  const dir = mkdtempSync(join(tmpdir(), 'compact-reinject-'))
  t.after(() => rmSync(dir, { recursive: true, force: true }))
  return dir
}

function run(input) {
  const result = spawnSync(process.execPath, [script], {
    input: JSON.stringify({ hook_event_name: 'SessionStart', source: 'compact', ...input }),
    encoding: 'utf8',
  })
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.stderr, '')
  if (!result.stdout) return undefined
  const { hookSpecificOutput } = JSON.parse(result.stdout)
  assert.equal(hookSpecificOutput.hookEventName, 'SessionStart')
  assert.ok(hookSpecificOutput.additionalContext.length < 10000)
  return hookSpecificOutput.additionalContext
}

test('Git リポジトリでもなく transcript もなければ出力しない', t => {
  const cwd = workspace(t)
  assert.equal(run({ cwd }), undefined)
  assert.equal(run({ cwd, transcript_path: join(cwd, 'missing.jsonl') }), undefined)
})

test('Git 状態を返し、status は先頭 20 行までにする', t => {
  const cwd = workspace(t)
  const git = (...args) => execFileSync('git', args, { cwd, stdio: 'pipe' })
  git('init', '-b', 'hook-test')
  git('-c', 'user.name=Hook Test', '-c', 'user.email=hook@example.invalid',
    '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=' + cwd,
    'commit', '--allow-empty', '-m', 'Fixture commit')
  for (let i = 10; i < 33; i++) writeFileSync(join(cwd, 'file-' + i), '')

  const context = run({ cwd, transcript_path: join(cwd, 'missing.jsonl') })
  assert.match(context, /hook-test/)
  assert.match(context, /\?\? file-10/)
  assert.match(context, /\?\? file-29/)
  assert.doesNotMatch(context, /file-30/)
  assert.match(context, /[0-9a-f]+ Fixture commit/)
})

test('transcript の Skill 呼び出しを重複なく返し、壊れた行は飛ばす', t => {
  const cwd = workspace(t)
  const transcript = join(cwd, 'transcript.jsonl')
  writeFileSync(transcript, [skill('jp-deslop'), '{', skill('team:check'), skill('jp-deslop')].join('\n'))
  const context = run({ cwd, transcript_path: transcript })
  assert.match(context, /再度読み込めます/)
  assert.deepEqual(context.split('\n').slice(-2), ['jp-deslop', 'team:check'])
  assert.doesNotMatch(context, /Git/)
  assert.equal(run({ cwd, transcript_path: transcript, source: 'startup' }), undefined)
})

test('skill 名が多い場合も 10,000 字未満に収める', t => {
  const cwd = workspace(t)
  const transcript = join(cwd, 'transcript.jsonl')
  const lines = Array.from({ length: 500 }, (_, i) => skill('long-skill-name-for-transcript-' + i))
  writeFileSync(transcript, lines.join('\n'))
  assert.equal(run({ cwd, transcript_path: transcript }).length, 9999)
})
