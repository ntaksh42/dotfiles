// Stop hook: 長い・構造のある返信を会話にそのまま出したら止めて、report-to-user のシートにまとめ直させる。
// plugin や mod に依存しない単体スクリプト。~/.claude/settings.json の Stop に登録して使う（tools/Install-ReplyCheckHook.ps1）。
// 判定は機械的な数え上げだけ: 空行を除いた行数から結論の 1 行目を除いて > 7、空白を除いた字数 > 400、Markdown の表、箇条書き 6 つ以上のどれか。
// 行数だけだと、1 行に詰め込んだ長い箇条書きをすり抜けるので字数も見る。
// 字数には URL・リンク先と Markdown の記号を入れない（読み手が読む文の長さではないので、数えると短い返信まで止める）。
// 止めるのは 1 ターンに 1 回（stop_hook_active のとき・このターンで skill を呼んだとき・シートを出したときは通す）。
// UserPromptSubmit にも登録し、毎ターンの入力時に基準を短く差し込む（書いてから止められる前に形を決めさせる）。
// 長い作業ではターン冒頭の差し込みが返信を書く時点まで届かないので、PostToolUse でコミット・push・PR 作成の直後
// （作業の報告を書く直前）にも同じ基準を差し込む。
// 環境変数 REPLY_CHECK=off で無効にできる。失敗したときは何もしない（hook で作業を止めない）。
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const MAX_LINES = 7
const MAX_BULLETS = 5
const MAX_CHARS = 400
// 会話の目安。上の上限より狭く取る (見積もりの誤差で止められないように)。共通ルール (claude/CLAUDE.global.md) と
// report-to-user の choose-form.py の CHAT_LINES / CHAT_CHARS も同じ値にする
const TARGET_LINES = 3
const TARGET_CHARS = 200
// モデルは書きながら字数を数えられないので、目安は文の数で伝え、合格する返信の実例を添える
const TARGET_SENTENCES = 2
const EXAMPLE = '原因は、候補を検索順に並べて 8 件で切っていることです。メンション履歴を上位に混ぜれば直ります。実装しますか？'
const SKILL_NAME = 'report-to-user'
// 作業の区切り (この後に報告を書くことが多い) とみなすコマンド
const WRAP_UP_COMMAND = /\bgit\s+(?:-[Cc]\s+\S+\s+|-\S+\s+)*(?:commit|push)\b|\bgh\s+pr\s+(?:create|edit)\b/
const GUIDE =
  `会話に書く返信は、結論 1 文と補足 ${TARGET_SENTENCES} 文までにする。字数は数えず、文の数で守る。` +
  'ファイルパス・行番号は会話に書かない（要るならシートに書く）。' +
  `例:「${EXAMPLE}」` +
  `（結論 1 文と ${TARGET_LINES} 行・${TARGET_CHARS} 字までを目安にする。hook の上限は結論 + ${MAX_LINES} 行・${MAX_CHARS} 字、箇条書き ${MAX_BULLETS} 個、表は不可）。` +
  '変更したファイルの一覧・実行したコマンド・経緯は書かない（差分・PR・ログにある）。検証は件数と結果だけ書く。' +
  `それでも超えそうなら、返信を書く前に ${SKILL_NAME} を呼んでシートにする。`

export function measure(message) {
  const text = String(message ?? '').replace(/```[\s\S]*?```/g, '')
  const lines = text.split('\n').filter(l => l.trim() !== '')
  const table = lines.some(l => /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$/.test(l) && l.includes('|'))
  const bullet = /^\s*([-*•]|\d+[.)])\s+(?=\S)/
  const bullets = lines.filter(l => bullet.test(l)).length
  // 字数は読み手が読む文だけを数える: リンク先・URL・行頭の記号 (箇条書き・見出し・引用)・強調やコードの記号は除く
  const prose = lines
    .map(l => l.replace(bullet, '').replace(/^\s*(#{1,6}|>)\s*/, ''))
    .join('\n')
    .replace(/\]\(<?[^)\s]*>?\)/g, ']')
    .replace(/<?https?:\/\/[^\s<>)\]]+>?/g, '')
    .replace(/[`*[\]]/g, '')
  const chars = prose.replace(/\s/g, '').length
  return { lines: lines.length, chars, table, bullets }
}

export function violations(message) {
  const { lines, chars, table, bullets } = measure(message)
  const out = []
  if (lines - 1 > MAX_LINES) out.push(`${lines} 行 (上限: 結論の 1 行 + ${MAX_LINES} 行)`)
  if (chars > MAX_CHARS) out.push(`${chars} 字 (上限 ${MAX_CHARS} 字)`)
  if (table) out.push('Markdown の表')
  if (bullets > MAX_BULLETS) out.push(`箇条書き ${bullets} 個 (上限 ${MAX_BULLETS} 個)`)
  return out
}

// このターン (最後の本物のユーザー入力より後) に report-to-user を使っていたか
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
  const wroteSheet = b =>
    (b?.name === 'Write' && /\.html?$/i.test(String(b.input?.file_path ?? ''))) ||
    (/^(Bash|PowerShell)$/.test(String(b?.name)) && String(b.input?.command ?? '').includes('new-sheet.py'))
  return entries.slice(start).some(
    e => e.type === 'assistant' && Array.isArray(e.message?.content) &&
      e.message.content.some(b => b?.type === 'tool_use' && (usedSkill(b) || wroteSheet(b))),
  )
}

// UserPromptSubmit: 返信を書く前に基準を思い出させる文を additionalContext で返す
export function remind(input) {
  if (process.env.REPLY_CHECK === 'off') return undefined
  if (input.agent_id !== undefined) return undefined
  return {
    hookSpecificOutput: {
      hookEventName: 'UserPromptSubmit',
      additionalContext: `[reply-check] ${GUIDE}一覧・比較・手順・コマンド集を求められたら最初からシートにする。`,
    },
  }
}

// PostToolUse: コミット・push・PR 作成の直後 (作業の報告を書く直前) に同じ基準を差し込む
export function isWrapUp(toolName, toolInput) {
  const name = String(toolName ?? '')
  if (/^mcp__.*__(create_pull_request|update_pull_request)$/.test(name)) return true
  return /^(Bash|PowerShell)$/.test(name) && WRAP_UP_COMMAND.test(String(toolInput?.command ?? ''))
}

export function remindAtWrapUp(input) {
  if (process.env.REPLY_CHECK === 'off') return undefined
  if (input.agent_id !== undefined) return undefined
  if (!isWrapUp(input.tool_name, input.tool_input)) return undefined
  return {
    hookSpecificOutput: {
      hookEventName: 'PostToolUse',
      additionalContext: `[reply-check] この後に報告を書くなら: ${GUIDE}`,
    },
  }
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
      `返信が会話に書く基準を超えています (${found.join('、')})。report-to-user を呼び、今の返信の中身を scripts/new-sheet.py で報告シートにして見せてください。` +
      '会話には結論 1 文とシートの場所だけを書きます。[判断]・注意点・一覧はシートに入れます。次からは、長くなると分かった時点で返信を書く前にシートを作ります。',
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  let raw = ''
  process.stdin.setEncoding('utf8')
  process.stdin.on('data', chunk => (raw += chunk))
  process.stdin.on('end', () => {
    try {
      const input = JSON.parse(raw || '{}')
      if (input.hook_event_name === 'UserPromptSubmit') {
        const reminder = remind(input)
        if (reminder) process.stdout.write(JSON.stringify(reminder))
        return
      }
      if (input.hook_event_name === 'PostToolUse') {
        const reminder = remindAtWrapUp(input)
        if (reminder) process.stdout.write(JSON.stringify(reminder))
        return
      }
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
