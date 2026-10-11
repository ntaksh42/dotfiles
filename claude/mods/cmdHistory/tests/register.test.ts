import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { matches, parseHistory } from '../hooks/register'

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

const engine = (on: On, filled: string[]) => {
  mock.env(on, { APPDATA: 'C:/Users/me/AppData/Roaming' })
  // エンジンは区切りを \ に正規化して渡す
  on('fs.exists', (_$, e) => ({ value: e.path.replaceAll('\\', '/') === HISTORY }) as never)
  on('fs.read', () => ({ value: 'git pull\r\nls\r\ngit push origin main\r\n' }) as never)
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
  const ui = await $.ui.mount({ plugin: 'cmdHistory', surface: 'terminal', ...PANE })
  expect((await ui.find({ key: 'row:0' }))?.text).toContain('git push origin main')
  expect(await ui.find({ key: 'row:2' })).toBeUndefined()
  await ui.input({ key: 'filter', text: 'pull', kind: 'change' })
  await ui.press({ key: 'row:0' })
  expect(filled).toEqual(['!git pull'])
})
