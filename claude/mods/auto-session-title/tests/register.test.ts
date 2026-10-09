import { expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const engine = (on: On, prompts: string[] = []) => {
  on('classic.UserPromptSubmit', () => ({}))
  on('model.complete', (_$, e) => {
    prompts.push(e.system ?? '')
    return { value: { isAnswered: true, text: '日本語タイトル', usage: { input_tokens: 0, output_tokens: 0 } } } as never
  })
}

test('英語の依頼でも日本語で付けるよう指示する', async ($, on) => {
  const systems: string[] = []
  engine(on, systems)
  const r = await $.classic.UserPromptSubmit({ prompt: 'fix the login bug', source: 'user', session_id: 's1' })
  expect(r.sessionTitle).toBe('日本語タイトル')
  expect(systems[0]).toContain('Japanese')
})

test('/clear 後の新セッションでは引き継いだタイトルを付け直す', async ($, on) => {
  engine(on)
  const first = await $.classic.UserPromptSubmit({ prompt: '最初の依頼', source: 'user', session_id: 's1' })
  expect(first.sessionTitle).toBe('日本語タイトル')

  const again = await $.classic.UserPromptSubmit({ prompt: '次の依頼', source: 'user', session_id: 's1', session_title: '日本語タイトル' })
  expect(again.sessionTitle).toBeUndefined()

  const cleared = await $.classic.UserPromptSubmit({ prompt: '別の依頼', source: 'user', session_id: 's2', session_title: '日本語タイトル' })
  expect(cleared.sessionTitle).toBe('日本語タイトル')
})

test('手動で付けた名前は上書きしない', async ($, on) => {
  engine(on)
  const r = await $.classic.UserPromptSubmit({ prompt: '依頼', source: 'user', session_id: 's1', session_title: '手動の名前' })
  expect(r.sessionTitle).toBeUndefined()
})
