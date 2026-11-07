// Stop hook: 長い・構造のある返信を会話にそのまま出したら止めて、request-user-check のシートにまとめ直させる。
// plugin や mod に依存しない単体スクリプト。~/.claude/settings.json の Stop に登録して使う（tools/Install-ReplyCheckHook.ps1）。
// 判定は機械的な数え上げだけ: 空行を除いた行数 > 6、Markdown の表、箇条書き 3 つ以上のどれか。
// 止めるのは 1 ターンに 1 回（stop_hook_active のとき・このターンで skill を呼んだとき・シートを出したときは通す）。
// 環境変数 REPLY_CHECK=off で無効にできる。失敗したときは何もしない（hook で作業を止めない）。
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const MAX_LINES = 6
const MAX_BULLETS = 2
const SKILL_NAME = 'request-user-check'

export function measure(message) {
  const text = String(message ?? '').replace(/```[\s\S]*?```/g, '')
  const lines = text.split('\n').filter(l => l.trim() !== '')
  const table = lines.some(l => /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$/.test(l) && l.includes('|'))
  const bullets = lines.filter(l => /^\s*([-*•]|\d+[.)])\s+\S/.test(l)).length
  return { lines: lines.length, table, bullets }
}

export function violations(message) {
  const { lines, table, bullets } = measure(message)
  const out = []
  if (lines > MAX_LINES) out.push(`${lines} 行 (上限 ${MAX_LINES} 行)`)
  if (table) out.push('Markdown の表')
  if (bullets > MAX_BULLETS) out.push(`箇条書き ${bullets} 個 (上限 ${MAX_BULLETS} 個)`)
  return out
}

// このターン (最後の本物のユーザー入力より後) に request-user-check を使っていたか
export function calledSkillThisTurn(transcriptLines) {
  const entries = []
  for (const l of transcriptLines) {
    try {
      entries.push(JSON.parse(l))
    } catch {
      // 壊れた行は読み飛ばす
    }
  }
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
  // skill を呼んだか、HTML のシートを書いた (skill は一度読み込めば呼び直さない) ターンなら使ったとみなす
  const usedSkill = b => b?.name === 'Skill' && String(b.input?.skill ?? '').includes(SKILL_NAME)
  const wroteSheet = b => b?.name === 'Write' && /\.html?$/i.test(String(b.input?.file_path ?? ''))
  return entries.slice(start).some(
    e => e.type === 'assistant' && Array.isArray(e.message?.content) &&
      e.message.content.some(b => b?.type === 'tool_use' && (usedSkill(b) || wroteSheet(b))),
  )
}

export function decide(input, transcriptText) {
  if (process.env.REPLY_CHECK === 'off') return undefined
  if (input.stop_hook_active || input.agent_id !== undefined) return undefined
  const message = String(input.last_assistant_message ?? '')
  if (message.includes('::orca-visual')) return undefined
  const found = violations(message)
  if (found.length === 0) return undefined
  if (transcriptText && calledSkillThisTurn(transcriptText.split('\n'))) return undefined
  return {
    decision: 'block',
    reason:
      `返信が会話に書く基準を超えています (${found.join('、')})。request-user-check を呼び、中身を報告シートにまとめて見せてください。` +
      '会話には結論 1 文・シートの場所・注意点・[判断] だけを書きます。',
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
