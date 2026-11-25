// request-user-check を毎回使わせるための settings hook。mod の有無に関係なく動く。
//   prompt: ユーザーの依頼ごとに、返答前に request-user-check を読み込むよう注意書きを足す
//   stop:   このターンで request-user-check を呼ばずに長い返答 (空行を除き MAX_LINES 行超) を出したら、1 回だけ差し戻す
// 使い方: node report-guard.mjs <prompt|stop>（標準入力は hook の JSON）
import { readFileSync } from 'node:fs'
import { basename } from 'node:path'

export const MAX_LINES = 10
const SKILL = 'dotfiles:request-user-check'
const isSkill = name => /(^|:)request-user-check$/.test(String(name ?? ''))

export const REMINDER =
  `ユーザーへ返すときは、短い相槌・挨拶への返事を除き、返答を書く前に Skill ツールで ${SKILL} を読み込み、その型で返す。` +
  `質問への回答や確認を求めない報告も対象。会話で ${MAX_LINES} 行を超える内容は HTML の報告シートに移す。`

export const countLines = text => String(text ?? '').split('\n').filter(l => l.trim() !== '').length

const blocks = entry => {
  const content = entry?.message?.content
  return typeof content === 'string' ? [{ type: 'text', text: content }] : Array.isArray(content) ? content : []
}

// ユーザーが打った依頼か（ツール結果・スキル本文などの自動挿入は除く）
const isUserPrompt = entry =>
  entry?.type === 'user' && !entry.isMeta && !entry.isCompactSummary &&
  blocks(entry).some(b => b.type === 'text') && !blocks(entry).some(b => b.type === 'tool_result')

// transcript (JSONL) のうち、最後の依頼以降のエントリ
export const currentTurn = jsonl => {
  const entries = String(jsonl ?? '').split('\n').flatMap(line => {
    try {
      return line.trim() ? [JSON.parse(line)] : []
    } catch {
      return []
    }
  })
  let start = entries.length - 1
  while (start >= 0 && !isUserPrompt(entries[start])) start--
  return start < 0 ? entries : entries.slice(start)
}

export const usedSkill = turn =>
  turn.some(entry =>
    blocks(entry).some(b =>
      (entry.type === 'assistant' && b.type === 'tool_use' && b.name === 'Skill' && isSkill(b.input?.skill)) ||
      // /dotfiles:request-user-check と打たれたとき
      (isUserPrompt(entry) && b.type === 'text' && String(b.text).includes('request-user-check'))))

const lastAssistantText = turn => {
  for (let i = turn.length - 1; i >= 0; i--) {
    if (turn[i].type !== 'assistant') continue
    const text = blocks(turn[i]).filter(b => b.type === 'text').map(b => b.text).join('\n')
    if (text.trim()) return text
  }
  return ''
}

// 差し戻すなら理由を返す。差し戻さないなら undefined
export const blockReason = (input, transcript) => {
  if (input.stop_hook_active || input.agent_id !== undefined) return undefined
  const turn = currentTurn(transcript)
  if (usedSkill(turn)) return undefined
  const lines = countLines(input.last_assistant_message ?? lastAssistantText(turn))
  if (lines <= MAX_LINES) return undefined
  return `この返答は ${lines} 行あるが、${SKILL} を使っていない。Skill ツールで ${SKILL} を読み込み、その型で返し直す` +
    `（${MAX_LINES} 行を超える報告は HTML の報告シートにまとめ、会話には結論 1 文と [判断] だけを書く）。`
}

const handlers = {
  prompt(input) {
    if (input.source !== undefined && input.source !== 'user') return
    process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: REMINDER } }))
  },
  stop(input) {
    // claude -p などの無人実行では差し戻さない
    if (String(process.env.CLAUDE_CODE_ENTRYPOINT ?? '').startsWith('sdk')) return
    let transcript = ''
    try {
      transcript = input.transcript_path ? readFileSync(input.transcript_path, 'utf8') : ''
    } catch {
      return
    }
    const reason = blockReason(input, transcript)
    if (reason) process.stdout.write(JSON.stringify({ decision: 'block', reason }))
  },
}

const mode = process.argv[2] ?? ''
// テストから import されたときは動かさない
if (basename(process.argv[1] ?? '') === 'report-guard.mjs' && handlers[mode]) {
  let raw = ''
  process.stdin.setEncoding('utf8')
  process.stdin.on('data', chunk => (raw += chunk))
  process.stdin.on('end', () => {
    try {
      handlers[mode](JSON.parse(raw || '{}'))
    } catch {
      // hook の失敗で会話を止めない
    }
  })
}
