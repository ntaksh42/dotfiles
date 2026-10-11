import type { Register } from 'claude-code'

const MAX_LEN = 40
const MAX_PROMPT_CHARS = 500
// 最初のプロンプトで付け、以降はこの回数ごとに会話全体から付け直す
const RENAME_EVERY = 5
const RECENT_PROMPTS = 5

const SYSTEM = 'Reply with only a short Japanese title (at most 30 characters) summarizing the user request below. Always write the title in Japanese, even if the request is in another language. No quotes, no trailing punctuation.'
const RENAME_SYSTEM = 'Reply with only a short Japanese title (at most 30 characters) for the whole session, judging from the requests below. Keep the current title if it still fits. Always write the title in Japanese. No quotes, no trailing punctuation.'

type Session = { count: number; first: string; recent: string[] }

export const register: Register = on => {
  // /clear で session_id が変わっても前のタイトルが引き継がれるため、セッション単位で管理する
  const sessions = new Map<string, Session>()
  const ownTitles = new Set<string>()

  on('classic.UserPromptSubmit', async ($, e, next) => {
    const ran = await next(e)
    if ((e.source ?? 'user') !== 'user') return ran
    // 手動で付けた名前（自分が付けたもの以外）は上書きしない
    if (e.session_title && !ownTitles.has(e.session_title)) return ran

    const prompt = e.prompt.trim().slice(0, MAX_PROMPT_CHARS)
    if (!prompt || prompt.startsWith('/')) return ran
    const s = sessions.get(e.session_id) ?? { count: 0, first: prompt, recent: [] }
    sessions.set(e.session_id, s)
    s.count += 1
    s.recent = [...s.recent, prompt].slice(-RECENT_PROMPTS)
    if ((s.count - 1) % RENAME_EVERY !== 0) return ran

    const isFirst = s.count === 1
    const r = await $.model.complete({
      model: 'haiku',
      effort: 'low',
      maxTokens: 60,
      timeoutMs: 8000,
      system: isFirst ? SYSTEM : RENAME_SYSTEM,
      prompt: isFirst
        ? prompt
        : [`Current title: ${e.session_title ?? ''}`, `First request: ${s.first}`, 'Recent requests:', ...s.recent.map(p => `- ${p}`)].join('\n'),
    })
    const summary = r.isAnswered ? (r.text.trim().split('\n')[0] ?? '') : ''
    // 付け直しに失敗したら今のタイトルのままにする
    if (!summary && !isFirst) return ran
    const title = (summary || (prompt.split('\n')[0] ?? '')).slice(0, MAX_LEN)
    ownTitles.add(title)

    return { ...ran, sessionTitle: title }
  })
}
