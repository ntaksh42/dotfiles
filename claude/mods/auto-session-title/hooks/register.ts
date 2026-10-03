import type { Register } from 'claude-code'

const MAX_LEN = 40
const MAX_PROMPT_CHARS = 500

export const register: Register = on => {
  let isNamed = false

  on('classic.UserPromptSubmit', async ($, e, next) => {
    const ran = await next(e)
    if (isNamed || e.session_title || (e.source ?? 'user') !== 'user') return ran

    const prompt = e.prompt.trim()
    if (!prompt || prompt.startsWith('/')) return ran
    isNamed = true

    const r = await $.model.complete({
      model: 'haiku',
      effort: 'low',
      maxTokens: 60,
      timeoutMs: 8000,
      system: 'Reply with only a short title (at most 30 characters) summarizing the user request below, in the same language as the request. No quotes, no trailing punctuation.',
      prompt: prompt.slice(0, MAX_PROMPT_CHARS),
    })
    const summary = r.isAnswered ? r.text.trim().split('\n')[0] : ''
    const title = (summary || prompt.split('\n')[0]).slice(0, MAX_LEN)

    return { ...ran, sessionTitle: title }
  })
}
