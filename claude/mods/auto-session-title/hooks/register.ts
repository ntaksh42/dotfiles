import type { Register } from 'claude-code'

const MAX_LEN = 40
const MAX_PROMPT_CHARS = 500

export const register: Register = on => {
  // /clear で session_id が変わっても前のタイトルが引き継がれるため、セッション単位で管理する
  const namedSessions = new Set<string>()
  const ownTitles = new Set<string>()

  on('classic.UserPromptSubmit', async ($, e, next) => {
    const ran = await next(e)
    if (namedSessions.has(e.session_id) || (e.source ?? 'user') !== 'user') return ran
    // 手動で付けた名前（自分が付けたもの以外）は上書きしない
    if (e.session_title && !ownTitles.has(e.session_title)) return ran

    const prompt = e.prompt.trim()
    if (!prompt || prompt.startsWith('/')) return ran
    namedSessions.add(e.session_id)

    const r = await $.model.complete({
      model: 'haiku',
      effort: 'low',
      maxTokens: 60,
      timeoutMs: 8000,
      system: 'Reply with only a short Japanese title (at most 30 characters) summarizing the user request below. Always write the title in Japanese, even if the request is in another language. No quotes, no trailing punctuation.',
      prompt: prompt.slice(0, MAX_PROMPT_CHARS),
    })
    const summary = r.isAnswered ? r.text.trim().split('\n')[0] : ''
    const title = (summary || prompt.split('\n')[0]).slice(0, MAX_LEN)
    ownTitles.add(title)

    return { ...ran, sessionTitle: title }
  })
}
