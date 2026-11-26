import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'

function git(cwd, args) {
  try {
    return execFileSync('git', ['--no-optional-locks', ...args], {
      cwd,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
      timeout: 2000,
      windowsHide: true,
    }).trimEnd()
  } catch {
    return undefined
  }
}

function gitContext(cwd) {
  if (typeof cwd !== 'string' || !cwd || git(cwd, ['rev-parse', '--is-inside-work-tree']) !== 'true') return []

  const context = []
  const branch = git(cwd, ['symbolic-ref', '--quiet', '--short', 'HEAD'])
  const status = git(cwd, ['status', '--short'])
  const log = git(cwd, ['log', '--oneline', '-5'])
  if (branch) context.push('現在の Git ブランチは ' + branch + ' です。')
  if (status === '') context.push('Git の作業ツリーに変更はありません。')
  if (status) context.push('git status --short の先頭 20 行です。\n' + status.split(/\r?\n/).slice(0, 20).join('\n'))
  if (log) context.push('直近の Git コミットです（最大 5 件）。\n' + log)
  return context
}

function skillNames(path) {
  if (typeof path !== 'string' || !path) return []

  let transcript
  try {
    transcript = readFileSync(path, 'utf8')
  } catch {
    return []
  }

  const skills = new Set()
  for (const line of transcript.split('\n')) {
    let entry
    try {
      entry = JSON.parse(line)
    } catch {
      continue
    }
    if (entry?.type !== 'assistant' || entry.isSidechain || !Array.isArray(entry.message?.content)) continue
    for (const block of entry.message.content) {
      const name = block?.input?.skill
      if (block?.type === 'tool_use' && block.name === 'Skill' && typeof name === 'string' && /^\S+$/.test(name)) {
        skills.add(name)
      }
    }
  }
  return [...skills]
}

try {
  const input = JSON.parse(readFileSync(0, 'utf8'))
  if (input?.hook_event_name === 'SessionStart' && input.source === 'compact') {
    const context = gitContext(input.cwd)
    const skills = skillNames(input.transcript_path)
    if (skills.length) {
      context.push(
        'compaction 後に残る skill 本文は先頭部分です。手順を確認するときは、Skill ツールで再度読み込めます。\n' +
        'このセッションで Skill ツールが呼び出した skill は次のとおりです。\n' + skills.join('\n'),
      )
    }
    if (context.length) {
      process.stdout.write(JSON.stringify({
        hookSpecificOutput: {
          hookEventName: 'SessionStart',
          additionalContext: context.join('\n\n').slice(0, 9999),
        },
      }))
    }
  }
} catch {
  // 入力を読めない場合は出力しない。
}
