import { atom, read, update } from 'claude-code'
import type { Args, EngineInterface, Next, Register } from 'claude-code'

const PANE = 'cmd-history'
const MAX_ENTRIES = 3000
const entries = atom({ plugin: 'dotfiles', key: 'entries' } as const, [])
const filter = atom({ plugin: 'dotfiles', key: 'filter' } as const, '')

// PSReadLine の履歴ファイルを新しい順・重複なしの項目にする。複数行の項目は最終行以外の行末がバッククォート
export const parseHistory = (text: string) => {
  const items: string[] = []
  let pending: string[] = []
  for (const line of text.split(/\r?\n/)) {
    if (line.endsWith('`')) {
      pending.push(line.slice(0, -1))
      continue
    }
    const item = [...pending, line].join('\n').trim()
    pending = []
    if (item !== '') items.push(item)
  }
  return [...new Set(items.reverse())].slice(0, MAX_ENTRIES)
}

// 空白区切りの語をすべて含む項目（大文字小文字は区別しない）
export const matches = (list: readonly string[], query: string) => {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean)
  return list.filter(item => words.every(w => item.toLowerCase().includes(w)))
}

async function loadHistory($: EngineInterface) {
  const appData = await $.env.get('APPDATA')
  if (appData === undefined) return []
  const path = `${appData}/Microsoft/Windows/PowerShell/PSReadLine/ConsoleHost_history.txt`
  if (!(await $.fs.exists(path))) return []
  return parseHistory(await $.fs.read(path))
}

// ペインを閉じてから入力欄に入れる（ペインがキーを持っている間は入力欄が受け付けない）
async function pick($: EngineInterface, command: string) {
  await $.ui.close({ id: PANE })
  const filled = await $.prompt.fill({ text: `!${command}` })
  if (!filled.isFilled) $.ui.toast('cmdHistory: 入力欄に入れられませんでした')
}

export async function sessionStart($: EngineInterface, e: Args<'session.start'>, next: Next<'session.start'>) {
  await $.command.register({
    name: 'cmdHistory',
    description: 'PowerShell の履歴から選んで ! コマンドとして入力欄に入れる',
    argumentHint: '[絞り込む語]',
  })
  return next(e)
}

export const register: Register = on => {

  on('command.run', { command: 'cmdHistory' }, async ($, e) => {
    await update($, entries, () => [])
    await update($, filter, () => e.args.trim())
    const list = await loadHistory($)
    if (list.length === 0) return { text: 'PowerShell の履歴が見つかりませんでした。' }
    await update($, entries, () => list)
    await $.ui.open({ id: PANE, title: 'PowerShell history', focus: true, closeOnEscape: true, rows: 16 })
    return {}
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    // mobile には Input がない
    if (e.surface === 'mobile') {
      const { Text } = $.ui.resolve(e)
      return <Text dimColor>端末で開いてください</Text>
    }
    const { Box, Text, Input, Button } = $.ui.resolve(e)
    const query = await read($, filter)
    const hits = matches(await read($, entries), query)
    const room = Math.max(1, (e.props.scroll?.bodyRows ?? 16) - 2)
    const width = Math.max(10, (e.props.bodyColumns ?? 80) - 2)
    const label = (item: string) => {
      const one = item.replace(/\n/g, ' ⏎ ')
      return one.length > width ? `${one.slice(0, width - 1)}…` : one
    }

    return (
      <Box flexDirection="column">
        <Input
          key="filter"
          label="> "
          placeholder="絞り込む語（空白区切り）"
          value={query}
          submitLabel="先頭を選ぶ"
          autoFocus
          onInput={(value: string) => void update($, filter, () => value)}
          onSubmit={() => {
            if (hits[0] !== undefined) void pick($, hits[0])
          }}
        />
        {hits.length === 0 && <Text dimColor>一致する履歴がありません</Text>}
        {hits.slice(0, room).map((item, i) => (
          <Button key={`row:${i}`} plain onPress={() => void pick($, item)}>
            {label(item)}
          </Button>
        ))}
        {hits.length > room && <Text dimColor>ほか {hits.length - room} 件</Text>}
      </Box>
    )
  })
}
