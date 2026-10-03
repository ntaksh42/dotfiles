import { describe, expect, mock, test } from 'claude-code/testing'
import type { Args, On } from 'claude-code'
import type { Engine, Mounted } from 'claude-code/testing'

import { cut, findMentions, parseWorkItem, remember, transcriptTexts, workItemRef } from '../hooks/links'

const BAND = {
  plugin: 'ado-link-bar',
  component: 'AbovePrompt',
  props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 120, scroll: { offset: 0, bodyRows: 10 }, view: {} },
} as const

const START = { cwd: '/tmp', surface: 'terminal', isInteractive: true } as const

const PR = (n: number, repo = 'web') => `https://dev.azure.com/contoso/Shop/_git/${repo}/pullrequest/${n}`
const WI = (n: number) => `https://dev.azure.com/contoso/_workitems/edit/${n}`

// What the engine answers beneath the plugins: a marker standing for the empty band.
const engine = (on: On) => {
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('classic.SessionStart', () => ({}))
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine band</Text>
  })
}

// A test cannot stand in for the store beneath session.append, so the bottom
// throws once the plugins have run.
const append = ($: Engine, row: Args<'session.append'>) => $.session.append(row).catch(() => undefined)

let n = 0
const say = (role: 'user' | 'assistant', text: string, extra: Partial<Args<'session.append'>> = {}): Args<'session.append'> => ({
  message: { type: role, role, content: [{ type: 'text', text }] },
  door: role === 'user' ? 'prompt' : 'response',
  origin: role === 'user' ? { kind: 'composer' } : { kind: 'model', model: 'm' },
  uuid: `u${++n}`,
  ...extra,
})

describe('helpers', () => {
  test('finds pull requests and work items in the order written', async () => {
    const found = findMentions(
      `See ${PR(12)}?_a=files, https://dev.azure.com/contoso/Shop/_workitems/edit/345/ and https://github.com/a/b/pull/1 and ${PR(13, 'my%20repo')}`,
    )
    expect(found.map(f => [f.kind, f.url, f.label])).toEqual([
      ['pr', PR(12), 'web!12'],
      ['workItem', WI(345), '#345'],
      ['pr', PR(13, 'my%20repo'), 'my repo!13'],
    ])
  })

  test('visualstudio.com links count too', async () => {
    const found = findMentions(
      'https://contoso.visualstudio.com/DefaultCollection/Shop/_git/web/pullRequest/7 https://contoso.visualstudio.com/Shop/_workitems/edit/8',
    )
    expect(found.map(f => [f.url, f.label])).toEqual([
      ['https://contoso.visualstudio.com/DefaultCollection/Shop/_git/web/pullRequest/7', 'web!7'],
      ['https://contoso.visualstudio.com/_workitems/edit/8', '#8'],
    ])
  })

  test('AB#1234 counts only with an organization', async () => {
    expect(findMentions('fixes AB#99')).toEqual([])
    expect(findMentions(`fixes AB#99 after ${WI(5)}`, 'contoso').map(f => f.url)).toEqual([WI(99), WI(5)])
  })

  test('newest first, deduplicated, cut to the max', async () => {
    let list = remember([], findMentions(`${WI(1)} ${WI(2)}`), 3)
    list = remember(list, findMentions(`${WI(1)} ${WI(3)} ${WI(4)}`), 3)
    expect(list.map(m => m.label)).toEqual(['#4', '#3', '#1'])
  })

  test('reads prompts and replies back from a transcript', async () => {
    const jsonl = [
      JSON.stringify({ type: 'user', message: { content: `look at ${PR(3)}` } }),
      JSON.stringify({ type: 'user', isMeta: true, message: { content: PR(4) } }),
      JSON.stringify({ type: 'assistant', message: { content: [{ type: 'text', text: WI(5) }] } }),
      JSON.stringify({ type: 'assistant', isSidechain: true, message: { content: [{ type: 'text', text: PR(6) }] } }),
      'not json',
    ].join('\n')
    expect(transcriptTexts(jsonl)).toEqual([`look at ${PR(3)}`, WI(5)])
  })
})

describe('work item titles', () => {
  test('reads the org and id back from a work item link', async () => {
    expect(workItemRef(WI(5))).toEqual({ orgUrl: 'https://dev.azure.com/contoso', id: '5' })
    expect(workItemRef('https://contoso.visualstudio.com/_workitems/edit/8')).toEqual({ orgUrl: 'https://dev.azure.com/contoso', id: '8' })
    expect(workItemRef(PR(1))).toBeNull()
  })

  test('parses az output and shortens long titles', async () => {
    expect(parseWorkItem(JSON.stringify({ fields: { 'System.Title': 'Fix login', 'System.State': 'Active' } }))).toEqual({ title: 'Fix login', state: 'Active' })
    expect(parseWorkItem('not json')).toBeNull()
    expect(parseWorkItem('{}')).toBeNull()
    expect(cut('ログイン画面でパスワードを間違えると落ちる不具合', 10)).toBe('ログイン画面でパス…')
  })

  // Answers `az boards work-item show` with the given titles, counting each call.
  const boards = (on: On, titles: Record<string, string>, calls: string[]) =>
    on('process.run', (_$, e) => {
      const id = e.argv[e.argv.indexOf('--id') + 1] ?? ''
      calls.push(id)
      // az refuses --fields beside its default --expand.
      if (e.argv[e.argv.indexOf('--expand') + 1] !== 'none') throw new Error('--fields needs --expand none')
      const title = titles[id]
      return title === undefined
        ? { value: { exitCode: 1, stdout: '', stderr: 'ERROR: not found', isStdoutTruncated: false, isStderrTruncated: false } }
        : { value: { exitCode: 0, stdout: JSON.stringify({ fields: { 'System.Title': title, 'System.State': 'Active' } }), stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    })

  // The title lookup runs after the row is noted; wait until the band shows it.
  const waitForText = async (ui: Mounted<'terminal', 'AbovePrompt'>, text: string) => {
    for (let i = 0; i < 50 && !(await ui.find({ type: 'Text', text })); i++) await Promise.resolve()
    return ui.find({ type: 'Text', text })
  }

  test('a work item shows its title and state, fetched once', async ($, on) => {
    engine(on)
    const calls: string[] = []
    mock.env(on, {})
    boards(on, { '10': 'Fix login' }, calls)
    await $.session.start(START)
    const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
    await append($, say('user', WI(10)))
    expect(await waitForText(ui, ' Fix login')).toBeDefined()
    // Only the id is the link; the title and state are plain text beside it.
    expect(await ui.find({ type: 'Link', text: /#10$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: ' Active' })).toBeDefined()
    await append($, say('assistant', `again ${WI(10)}`))
    expect(calls).toEqual(['10'])
    await ui.unmount()
  })

  test('a failed lookup keeps the bare id', async ($, on) => {
    engine(on)
    const calls: string[] = []
    mock.env(on, {})
    on('ui.log', () => ({ value: undefined }))
    boards(on, {}, calls)
    await $.session.start(START)
    const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
    await append($, say('user', WI(11)))
    expect(await waitForText(ui, ' Active')).toBeUndefined()
    expect(await ui.find({ type: 'Link', text: /#11$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: ' Active' })).toBeUndefined()
    expect(calls).toEqual(['11'])
    await ui.unmount()
  })
})

describe('bar', () => {
  test('nothing added until a link is mentioned', async ($, on) => {
    engine(on)
    await $.session.start(START)
    await append($, say('user', 'hello'))
    const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
    expect(await ui.find({ type: 'Text', text: 'engine band' })).toBeDefined()
    expect(await ui.find({ type: 'Link' })).toBeUndefined()
    await ui.unmount()
  })

  test('pull requests and work items, most recent first', { options: { organization: 'contoso' } }, async ($, on) => {
    engine(on)
    await $.session.start(START)
    await append($, say('user', `${PR(1)} ${WI(10)}`))
    await append($, say('assistant', `${PR(2)} AB#11 and ${PR(1)}`))

    for (const surface of ['terminal', 'desktop'] as const) {
      const ui = await $.ui.mount({ ...BAND, surface })
      expect((await ui.findAll({ type: 'Link' })).map(l => l.props.href)).toEqual([PR(1), PR(2), WI(11), WI(10)])
      expect(await ui.find({ type: 'Link', text: 'web!2' })).toBeDefined()
      expect(await ui.find({ type: 'Link', text: '#11' })).toBeDefined()
      await ui.unmount()
    }
  })

  test('tool output, reminders and subagents do not count', async ($, on) => {
    engine(on)
    await $.session.start(START)
    await append($, say('user', PR(7), { message: { type: 'user', role: 'user', isMeta: true, content: [{ type: 'text', text: PR(7) }] } }))
    await append($, say('assistant', PR(8), { agentId: 'sub' }))
    await append($, say('user', WI(9), { door: 'tool-result' }))
    const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
    expect(await ui.find({ type: 'Link' })).toBeUndefined()
    await ui.unmount()
  })

  test('a resumed session reads its links back from the transcript', async ($, on) => {
    engine(on)
    const jsonl = [
      JSON.stringify({ type: 'user', message: { content: `review ${PR(11)}` } }),
      JSON.stringify({ type: 'assistant', message: { content: [{ type: 'text', text: `done: ${WI(12)}` }] } }),
    ].join('\n')
    on('fs.stat', () => ({ value: { kind: 'file', isLink: false, size: jsonl.length, mtimeMs: 0 } }))
    on('fs.read', () => ({ value: jsonl }))
    await $.session.start(START)
    await $.classic.SessionStart({ source: 'resume', transcript_path: '/t.jsonl' })
    const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
    expect((await ui.findAll({ type: 'Link' })).map(l => l.props.href)).toEqual([PR(11), WI(12)])

    await $.classic.SessionStart({ source: 'clear' })
    expect(await ui.find({ type: 'Link' })).toBeUndefined()
    await ui.unmount()
  })

  test('settings change how many', { options: { pullRequests: 1, workItems: 0 } }, async ($, on) => {
    engine(on)
    await $.session.start(START)
    await append($, say('assistant', `${WI(1)} ${PR(1)} ${PR(2)}`))
    const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
    expect((await ui.findAll({ type: 'Link' })).map(l => l.props.href)).toEqual([PR(2)])
    await ui.unmount()
  })

  test('a survey keeps the band', async ($, on) => {
    engine(on)
    await $.session.start(START)
    await append($, say('assistant', PR(1)))
    const ui = await $.ui.mount({ ...BAND, props: { ...BAND.props, hasSurvey: true }, surface: 'terminal' })
    expect(await ui.find({ type: 'Link' })).toBeUndefined()
    await ui.unmount()
  })

  test('off in /config: the bar is left alone', { options: { enabled: false } }, async ($, on) => {
    engine(on)
    await $.session.start(START)
    await append($, say('assistant', PR(1)))
    const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
    expect(await ui.find({ type: 'Link' })).toBeUndefined()
    await ui.unmount()
  })
})
