import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Links, WorkItemDetails } from '../types'
import { cut, findMentions, parseWorkItem, remember, textOf, transcriptTexts, workItemRef } from './links'

const links = atom({ plugin: 'ado-link-bar', key: 'links' } as const, { prs: [], workItems: [] })
const details = atom({ plugin: 'ado-link-bar', key: 'details' } as const, {} as WorkItemDetails)

const EMPTY: Links = { prs: [], workItems: [] }
// How much of a resumed transcript to read back: the recent end only.
const TAIL_CHARS = 4 * 1024 * 1024
// A transcript larger than this is not read back at all.
const MAX_READ_BYTES = 64 * 1024 * 1024

// Module variables start over on a reload; register sets them again from the settings.
const cfg = { organization: '', prs: 5, workItems: 5 }
// Work items whose title was already asked for, so each is fetched once.
const requested = new Set<string>()

// az.cmd only starts through a shell, so Windows goes through cmd.
async function az($: EngineInterface, args: string[]) {
  const isWindows = (await $.env.get('OS')) === 'Windows_NT'
  const argv = isWindows ? ['cmd', '/d', '/c', 'az', ...args] : ['az', ...args]
  return $.process.run(argv, { timeoutMs: 30_000 })
}

// Looks up a work item's title and state; on failure the link keeps its bare #id.
async function fetchDetails($: EngineInterface, url: string) {
  const ref = workItemRef(url)
  if (!ref) return
  const ran = await az($, ['boards', 'work-item', 'show', '--id', ref.id, '--org', ref.orgUrl, '--fields', 'System.Title,System.State', '--expand', 'none', '-o', 'json'])
  const info = ran.exitCode === 0 ? parseWorkItem(ran.stdout) : null
  if (!info) {
    await $.ui.log(`ado-link-bar: no title for ${url}: ${ran.stderr.trim().split('\n')[0] ?? `az exited ${ran.exitCode}`}`, { to: 'debug' })
    return
  }
  await update($, details, prev => ({ ...(prev ?? {}), [url]: info }))
}

// Asks for the titles not asked for yet. They arrive later; the row redraws when they land.
function requestDetails($: EngineInterface, urls: readonly string[]) {
  for (const url of urls) {
    if (requested.has(url)) continue
    requested.add(url)
    fetchDetails($, url).catch(error => $.ui.log(`ado-link-bar: ${String(error)}`, { to: 'debug' }))
  }
}

// Adds what one message mentions to the front of the lists.
async function note($: EngineInterface, text: string) {
  const found = findMentions(text, cfg.organization)
  if (found.length === 0) return
  await update($, links, prev => {
    const cur = prev ?? EMPTY
    return {
      prs: remember(cur.prs, found.filter(f => f.kind === 'pr'), cfg.prs),
      workItems: remember(cur.workItems, found.filter(f => f.kind === 'workItem'), cfg.workItems),
    }
  })
  requestDetails($, found.filter(f => f.kind === 'workItem').map(f => f.url))
}

export const register: Register = (on, options) => {
  if (options.enabled === false) return

  cfg.organization = String(options.organization ?? '').trim()
  cfg.prs = Math.max(0, Math.floor(Number(options.pullRequests ?? 5)))
  cfg.workItems = Math.max(0, Math.floor(Number(options.workItems ?? 5)))

  // The lists outlive a reload; their titles are asked for again.
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    const l = (await read($, links)) ?? EMPTY
    const known = (await read($, details)) ?? {}
    requestDetails($, l.workItems.map(m => m.url).filter(url => !(url in known)))
    return started
  })

  // The person's prompts and the model's replies count as mentions; tool
  // output, reminders and subagents' rows do not.
  on('session.append', async ($, e, next) => {
    const isMention =
      e.agentId === undefined && !e.message.isMeta && (e.door === 'prompt' || e.door === 'response')
    if (isMention) await note($, textOf(e.message.content))
    return next(e)
  })

  // A resumed session's rows are loaded, not appended: read them back from
  // the transcript. /clear starts the lists over.
  on('classic.SessionStart', async ($, e, next) => {
    const result = await next(e)
    if (e.source === 'clear') {
      await update($, links, () => EMPTY)
    } else if (e.source === 'resume' || e.source === 'fork') {
      const stat = await $.fs.stat(e.transcript_path).catch(() => null)
      if (stat?.kind === 'file' && stat.size <= MAX_READ_BYTES) {
        const text = await $.fs.read(e.transcript_path).catch(() => '')
        if (typeof text === 'string') await note($, transcriptTexts(text.slice(-TAIL_CHARS)).join('\n'))
      }
    }
    return result
  })

  // The band above the prompt: one row of links. The hint line under the
  // prompt keeps a single row on the terminal, so a second row there never shows.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const l = (await read($, links)) ?? EMPTY
    if (l.prs.length === 0 && l.workItems.length === 0) return next(e)
    const info = (await read($, details)) ?? {}

    const { Box, Text, Link } = $.ui.resolve(e)
    const group = (title: string, items: Links['prs']) => [
      <Text dimColor>{`${title} `}</Text>,
      ...items.flatMap((m, i) => {
        const wi = info[m.url]
        return [
          ...(i > 0 ? [<Text dimColor>{' · '}</Text>] : []),
          <Link href={m.url}>{m.label}</Link>,
          ...(wi ? [<Text>{` ${cut(wi.title)}`}</Text>] : []),
          ...(wi?.state ? [<Text dimColor>{` ${wi.state}`}</Text>] : []),
        ]
      }),
    ]
    const groups = [
      ...(l.prs.length ? [group('PRs', l.prs)] : []),
      ...(l.workItems.length ? [group('WIs', l.workItems)] : []),
    ]
    const row = groups.flatMap((g, i) => [...(i > 0 ? [<Text dimColor>{'   '}</Text>] : []), ...g])

    return (
      <Box flexDirection="row" paddingLeft={2}>
        {row}
      </Box>
    )
  })
}
