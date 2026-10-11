import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { bangCommand, historyEntry } from '../hooks/register'

const text = (t: string) => [{ type: 'text', text: t }] as never

// 追記に使った履歴行を記録する
const engine = (on: On, lines: string[]) => {
  on('ui.log', () => ({ value: undefined }) as never)
  on('process.run', (_$, e) => {
    lines.push(e.init?.env?.BANG_HISTORY_LINE ?? '')
    return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } } as never
  })
}

// ユーザーが打った行として会話に追加する
const row = (t: string) => ({ message: { type: 'user', content: text(t) }, door: 'prompt', origin: { kind: 'composer' }, uuid: t }) as const

test('bash-input の行からコマンドを取り出す', () => {
  expect(bangCommand(text('<bash-input>git pull</bash-input>'))).toBe('git pull')
  expect(bangCommand(text('<bash-input>  </bash-input>'))).toBeUndefined()
  expect(bangCommand(text('git pull を実行して'))).toBeUndefined()
  expect(bangCommand(text('<bash-stdout>ok</bash-stdout>'))).toBeUndefined()
})

test('複数行は PSReadLine の形式で 1 項目にする', () => {
  expect(historyEntry('a\r\nb\nc')).toBe('a`\nb`\nc')
})

test('! のコマンドだけを履歴に追記する', async ($, on) => {
  const lines: string[] = []
  engine(on, lines)
  const clock = mock.clock(on)
  await $.session.append(row('<bash-input>git status</bash-input>'))
  await $.session.append(row('普通のプロンプト'))
  await clock.settle()
  expect(lines).toEqual(['git status'])
})
