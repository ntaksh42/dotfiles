// Stop hook: ファイルを変えたターンで、検証を実行しないまま「完了した」「通った」と返信したら止めて、verify-before-done に沿って検証させる。
// plugin や mod に依存しない単体スクリプト。~/.claude/settings.json の Stop に登録して使う（tools/Install-VerifyCheckHook.ps1）。
// 止めるのは次のすべてを満たすときだけ:
//   - このターン（最後の本物のユーザー入力より後）に Write / Edit / MultiEdit / NotebookEdit でファイルを変えた
//   - 返信に完了の言い方（完了しました、直りました、通りました、fixed など）がある
//   - 返信に未検証の断り（未検証、試していない など）が無い
//   - このターンに verify-before-done を読み込んでおらず、検証らしいコマンド（テスト・ビルド・lint）も実行していない
// stop_hook_active のとき（同じターンで既に止めた後）とサブエージェントは通す。
// 環境変数 VERIFY_CHECK=off で無効にできる。失敗したときは何もしない（hook で作業を止めない）。
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const SKILL_NAME = 'verify-before-done'
const EDIT_TOOLS = new Set(['Write', 'Edit', 'MultiEdit', 'NotebookEdit'])
const CLAIM = /完了しました|完了です|実装しました|直りました|直しました|修正しました|解消しました|通りました|通ります|通過しました|パスしました|成功しました|動きました|動作しました|動くようになりました|ビルドできました|\b(fixed|all tests pass(ed)?|tests pass|works now|done)\b/i
const UNVERIFIED = /未検証|検証していません|検証できていません|試していません|確かめていません|確認していません|実行していません|unverified|not (yet )?(tested|verified)/i
const VERIFY_COMMAND = new RegExp([
  String.raw`\b(pytest|vitest|jest|mocha|tsc|eslint|ruff|mypy|shellcheck|Invoke-Pester|msbuild)\b`,
  String.raw`\bnode\s+--test\b`,
  String.raw`\b(npm|pnpm|yarn|bun)\s+(run\s+)?(test|build|lint|check|typecheck)\b`,
  String.raw`\b(cargo|go|dotnet|gradle|mvn|make|deno)\s+(test|build|check|vet|lint)\b`,
  String.raw`\bpython\S*\s+(-\S+\s+)*-m\s+(pytest|unittest)\b`,
  String.raw`\bclaude\s+plugin\s+(validate|test)\b`,
  String.raw`\bTest-\w+`,
].join('|'), 'i')

function parse(lines) {
  const entries = []
  for (const l of lines) {
    try {
      entries.push(JSON.parse(l))
    } catch {
      // 壊れた行は読み飛ばす
    }
  }
  return entries
}

// 最後の本物のユーザー入力より後の、アシスタントのツール呼び出し
export function toolUsesThisTurn(transcriptLines) {
  const entries = parse(transcriptLines)
  const isRealPrompt = e => {
    if (e.type !== 'user' || e.isMeta || e.isSidechain) return false
    const c = e.message?.content
    if (typeof c === 'string') return c.trim() !== ''
    return Array.isArray(c) && c.some(b => b?.type === 'text' && String(b.text ?? '').trim() !== '') && !c.some(b => b?.type === 'tool_result')
  }
  let start = 0
  entries.forEach((e, i) => {
    if (isRealPrompt(e)) start = i
  })
  return entries.slice(start)
    .filter(e => e.type === 'assistant' && Array.isArray(e.message?.content))
    .flatMap(e => e.message.content.filter(b => b?.type === 'tool_use'))
}

export function isVerifyCommand(command) {
  return VERIFY_COMMAND.test(String(command ?? ''))
}

export function claimsDone(message) {
  const text = String(message ?? '').replace(/```[\s\S]*?```/g, '')
  return CLAIM.test(text) && !UNVERIFIED.test(text)
}

export function decide(input, transcriptText) {
  if (process.env.VERIFY_CHECK === 'off') return undefined
  if (input.stop_hook_active || input.agent_id !== undefined) return undefined
  if (!claimsDone(input.last_assistant_message)) return undefined
  if (transcriptText === undefined) return undefined
  const uses = toolUsesThisTurn(transcriptText.split('\n'))
  if (!uses.some(b => EDIT_TOOLS.has(b.name))) return undefined
  const verified = uses.some(b =>
    (b.name === 'Skill' && String(b.input?.skill ?? '').endsWith(SKILL_NAME)) ||
    (/^(Bash|PowerShell)$/.test(String(b.name)) && isVerifyCommand(b.input?.command)))
  if (verified) return undefined
  return {
    decision: 'block',
    reason:
      `ファイルを変えたのに、検証を実行しないまま完了と書いています。Skill ツールで ${SKILL_NAME} を読み込み、主張を裏付ける検証を実行して出力を読んでから返信を書き直してください。` +
      '検証できない項目は、未検証と理由を書きます。',
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  let raw = ''
  process.stdin.setEncoding('utf8')
  process.stdin.on('data', chunk => (raw += chunk))
  process.stdin.on('end', () => {
    try {
      const input = JSON.parse(raw || '{}')
      let transcript
      try {
        transcript = input.transcript_path ? readFileSync(input.transcript_path, 'utf8') : undefined
      } catch {
        transcript = undefined
      }
      const result = decide(input, transcript)
      if (result) process.stdout.write(JSON.stringify(result))
    } catch {
      // 失敗しても何もしない
    }
  })
}
