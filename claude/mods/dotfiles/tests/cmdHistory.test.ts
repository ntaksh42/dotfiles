import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { matches, parseHistory } from '../hooks/cmdHistory/register'

test('新しい順・重複なしで、複数行の項目をまとめる', () => {
  const text = 'git pull\r\nls\r\nfoo `\r\n| bar\r\n\r\ngit pull\r\n'
  expect(parseHistory(text)).toEqual(['git pull', 'foo \n| bar', 'ls'])
})

test('空白区切りの語をすべて含む項目に絞る', () => {
  const list = ['git pull', 'git push origin main', 'Get-ChildItem']
  expect(matches(list, 'GIT pu')).toEqual(['git pull', 'git push origin main'])
  expect(matches(list, 'git main')).toEqual(['git push origin main'])
  expect(matches(list, '')).toEqual(list)
})

// エンジン側の応答。履歴ファイルを返し、入力欄に入れたテキストを記録する
const HISTORY = 'C:/Users/me/AppData/Roaming/Microsoft/Windows/PowerShell/PSReadLine/ConsoleHost_history.txt'

const engine = (on: On, filled: string[], history = 'git pull\r\nls\r\ngit push origin main\r\n') => {
  mock.env(on, { APPDATA: 'C:/Users/me/AppData/Roaming' })
  // エンジンは区切りを \ に正規化して渡す
  on('fs.exists', (_$, e) => ({ value: e.path.replaceAll('\\', '/') === HISTORY }) as never)
  on('fs.read', () => ({ value: history }) as never)
  on('command.register', () => ({ value: undefined }) as never)
  on('ui.open', () => ({ value: { isPlaced: true } }) as never)
  on('ui.close', () => ({ value: undefined }) as never)
  on('prompt.fill', (_$, e) => {
    filled.push(e.text)
    return { isFilled: true, text: e.text, cursor: e.text.length } as never
  })
}

const PANE = {
  component: 'Pane',
  requestId: 'cmd-history',
  props: { title: 'PowerShell history', isFocused: true, bodyColumns: 80, placement: 'dock', scroll: { offset: 0, bodyRows: 16 }, view: {} },
} as const

const run = (args: string) =>
  ({ command: 'cmdHistory', args, origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 120 } }) as never

test('引数で絞り込み、選んだ項目を ! 付きで入力欄に入れる', async ($, on) => {
  const filled: string[] = []
  engine(on, filled)
  await $.command.run(run('git'))
  const ui = await $.ui.mount({ plugin: 'dotfiles', surface: 'terminal', ...PANE })
  expect((await ui.find({ key: 'row:0' }))?.text).toContain('git push origin main')
  expect(await ui.find({ key: 'row:2' })).toBeUndefined()
  await ui.input({ key: 'filter', text: 'pull', kind: 'change' })
  await ui.press({ key: 'row:0' })
  expect(filled).toEqual([])
  expect(await ui.find({ type: 'Text', text: 'git pull' })).toBeDefined()
  await ui.press({ key: 'insert' })
  expect(filled).toEqual(['!git pull'])
  await ui.unmount()
})

test('ページ移動で隠れた項目を選び、検索を変えると先頭ページに戻る', async ($, on) => {
  engine(on, [], Array.from({ length: 30 }, (_, i) => `command-${i}`).join('\n'))
  await $.command.run(run(''))
  const ui = await $.ui.mount({ plugin: 'dotfiles', surface: 'terminal', ...PANE })
  expect((await ui.find({ key: 'row:0' }))?.text).toBe('command-29')
  await ui.press({ key: 'next' })
  expect((await ui.find({ key: 'row:0' }))?.text).toBe('command-17')
  await ui.press({ key: 'next' })
  expect((await ui.find({ key: 'row:0' }))?.text).toBe('command-5')
  expect(await ui.find({ key: 'next' })).toBeUndefined()
  await ui.press({ key: 'previous' })
  expect((await ui.find({ key: 'row:0' }))?.text).toBe('command-17')
  await ui.input({ key: 'filter', text: 'command-29', kind: 'change' })
  expect((await ui.find({ key: 'row:0' }))?.text).toBe('command-29')
  expect(await ui.find({ key: 'previous' })).toBeUndefined()
  await ui.unmount()
})

test('複数行の全文を確認してからそのまま挿入し、一覧にも戻れる', async ($, on) => {
  const filled: string[] = []
  const command = `Write-Output '${'x'.repeat(100)}'\n| Out-String`
  engine(on, filled, command.replace('\n', '`\r\n') + '\r\n')
  await $.command.run(run(''))
  const ui = await $.ui.mount({ plugin: 'dotfiles', surface: 'terminal', ...PANE })
  await ui.press({ key: 'row:0' })
  expect(await ui.find({ type: 'Text', text: command })).toBeDefined()
  await ui.press({ key: 'back' })
  expect(await ui.find({ key: 'filter' })).toBeDefined()
  expect(filled).toEqual([])
  await ui.press({ key: 'row:0' })
  await ui.press({ key: 'insert' })
  expect(filled).toEqual([`!${command}`])
  await ui.unmount()
})
