import { expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'

// 依頼を送り、バックグラウンドの命名が /rename まで届くのを待つ。付けなければ undefined
const engine = (on: On, systems: string[] = [], prompts: string[] = []) => {
  const renames: string[] = []
  let wake = () => {}
  on('prompt.submit', (_$, e) => ({ text: e.text }))
  on('session.id', () => ({ value: 's1' }) as never)
  on('model.complete', (_$, e) => {
    systems.push(e.system ?? '')
    prompts.push(e.prompt)
    return { value: { isAnswered: true, text: `タイトル${prompts.length}`, usage: { input_tokens: 0, output_tokens: 0 } } } as never
  })
  on('command.run', (_$, e) => {
    renames.push(e.args)
    wake()
    return { text: '' }
  })
  return async ($: Parameters<Parameters<typeof test>[1]>[0], text: string) => {
    const before = renames.length
    const renamed = new Promise<void>(resolve => { wake = resolve })
    await $.prompt.submit({ text })
    await Promise.race([renamed, new Promise(resolve => setTimeout(resolve, 200))])
    return renames.length > before ? renames.at(-1) : undefined
  }
}

test('英語の依頼でも日本語で付けるよう指示する', async ($, on) => {
  const systems: string[] = []
  const send = engine(on, systems)
  expect(await send($, 'fix the login bug')).toBe('タイトル1')
  expect(systems[0]).toContain('Japanese')
})

test('手動で付けた名前は上書きしない', async ($, on) => {
  const send = engine(on)
  await $.command.run({ command: 'rename', args: '手動の名前' })
  expect(await send($, '依頼')).toBeUndefined()
})

test('5 ターンごとに会話全体から付け直す', async ($, on) => {
  const prompts: string[] = []
  const send = engine(on, [], prompts)
  const titles: (string | undefined)[] = []
  for (let i = 1; i <= 11; i++) titles.push(await send($, `依頼${i}`))
  expect(titles.map((t, i) => (t ? i + 1 : 0)).filter(Boolean)).toEqual([1, 6, 11])
  expect(prompts[1]).toContain('Current title: タイトル1')
  expect(prompts[1]).toContain('First request: 依頼1')
  expect(prompts[1]).toContain('- 依頼6')
  expect(prompts[1]).not.toContain('- 依頼1\n')
})

test('スラッシュコマンドは数えない', async ($, on) => {
  const send = engine(on)
  await send($, '依頼')
  for (let i = 0; i < 5; i++) expect(await send($, '/status')).toBeUndefined()
})

for (const change of ['rename', 'clear', 'newer'] as const) {
  test(`生成中の ${change} を古い結果で上書きしない`, async ($, on) => {
    let id = 's1'
    const renames: string[] = []
    let release!: () => void
    let started!: () => void
    const pending = new Promise<void>(resolve => { release = resolve })
    const generating = new Promise<void>(resolve => { started = resolve })
    let calls = 0
    on('prompt.submit', (_$, e) => ({ text: e.text }))
    on('session.id', () => ({ value: id }) as never)
    on('model.complete', async () => {
      const first = ++calls === 1
      if (first) {
        started()
        await pending
      }
      return { value: { isAnswered: true, text: first ? '古いタイトル' : '新しいタイトル', usage: { input_tokens: 0, output_tokens: 0 } } } as never
    })
    on('command.run', (_$, e) => {
      renames.push(e.args)
      return { text: '' }
    })
    await $.prompt.submit({ text: '最初の依頼' })
    await generating
    if (change === 'rename') await $.command.run({ command: 'rename', args: '手動の名前' })
    else if (change === 'clear') id = 's2'
    else for (let i = 2; i <= 6; i++) await $.prompt.submit({ text: `依頼${i}` })
    release()
    await new Promise(resolve => setTimeout(resolve, 50))
    expect(renames).toEqual(change === 'rename' ? ['手動の名前'] : change === 'newer' ? ['新しいタイトル'] : [])
  })
}
