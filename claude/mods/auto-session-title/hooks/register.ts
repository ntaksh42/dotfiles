import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { TitleSession } from '../types'

const PLUGIN = 'auto-session-title'
const MAX_LEN = 40
const MAX_PROMPT_CHARS = 500
// 最初のプロンプトで付け、以降はこの回数ごとに会話全体から付け直す
const RENAME_EVERY = 5
const RECENT_PROMPTS = 5

const SYSTEM = 'Reply with only a short Japanese title (at most 30 characters) summarizing the user request below. Always write the title in Japanese, even if the request is in another language. No quotes, no trailing punctuation.'
const RENAME_SYSTEM = 'Reply with only a short Japanese title (at most 30 characters) for the whole session, judging from the requests below. Keep the current title if it still fits. Always write the title in Japanese. No quotes, no trailing punctuation.'

// mod の再読み込みで消えないよう $.state に持つ。/clear で session_id が変わっても前のタイトルが引き継がれるため、セッション単位で管理する
const sessions = atom({ plugin: 'auto-session-title', key: 'sessions' } as const, {})
// 今のタイトル。手動の /rename で付いたものなら manual。/clear 後も引き継がれるのでセッションをまたいで持つ
const current = atom({ plugin: 'auto-session-title', key: 'current' } as const, { title: '', manual: false })

// 組織管理下では classic.UserPromptSubmit が個人インストールの mod に回ってこないため、
// prompt.submit で数えて /rename で付ける。/rename はセッションが空いてから走るのでフックでは待たない
async function retitle($: EngineInterface, id: string, s: TitleSession, prompt: string) {
  const isFirst = s.count === 1
  const { title: now } = await read($, current)
  const r = await $.model.complete({
    model: 'haiku',
    effort: 'low',
    maxTokens: 60,
    timeoutMs: 8000,
    system: isFirst ? SYSTEM : RENAME_SYSTEM,
    prompt: isFirst
      ? prompt
      : [`Current title: ${now}`, `First request: ${s.first}`, 'Recent requests:', ...s.recent.map(p => `- ${p}`)].join('\n'),
  })
  const summary = r.isAnswered ? (r.text.trim().split('\n')[0] ?? '') : ''
  // 付け直しに失敗したら今のタイトルのままにする
  if (!summary && !isFirst) return
  const title = (summary || (prompt.split('\n')[0] ?? '')).slice(0, MAX_LEN)
  if (!title || title === now) return
  // 生成を待つ間の /rename・/clear や、後から始まった命名を上書きしない
  if ((await read($, current)).manual || await $.session.id() !== id) return
  const latest = (await read($, sessions))[id]
  if (latest && Math.floor((latest.count - 1) / RENAME_EVERY) !== Math.floor((s.count - 1) / RENAME_EVERY)) return
  await $.command.run({ command: 'rename', args: title })
  await update($, current, () => ({ title, manual: false }))
}

export const register: Register = on => {
  on('prompt.submit', async ($, e, next) => {
    const ran = await next(e)
    if (ran.drop !== undefined || e.command || e.isMeta) return ran
    // origin が無いものは本人の入力として扱う
    const kind = e.origin?.kind ?? 'composer'
    if (kind !== 'composer' && kind !== 'bridge') return ran
    // 手動で付けた名前は上書きしない
    if ((await read($, current)).manual) return ran

    const prompt = e.text.trim().slice(0, MAX_PROMPT_CHARS)
    if (!prompt || prompt.startsWith('/')) return ran
    const id = await $.session.id()
    const all = await update($, sessions, map => {
      const cur: TitleSession = map[id] ?? { count: 0, first: prompt, recent: [] }
      return { ...map, [id]: { ...cur, count: cur.count + 1, recent: [...cur.recent, prompt].slice(-RECENT_PROMPTS) } }
    })
    const s = all[id]
    if (!s || (s.count - 1) % RENAME_EVERY !== 0) return ran

    retitle($, id, s, prompt).catch(error => $.ui.log(`${PLUGIN}: ${String(error)}`, { to: 'debug' }))
    return ran
  })

  // 自分の $.command.run はこのフックを通らないので、ここに来るのは手動の /rename
  on('command.run', { command: 'rename' }, async ($, e, next) => {
    const ran = await next(e)
    const title = e.args.trim()
    if (title && !(e.origin?.kind === 'plugin' && e.origin.name === PLUGIN)) await update($, current, () => ({ title, manual: true }))
    return ran
  })
}
