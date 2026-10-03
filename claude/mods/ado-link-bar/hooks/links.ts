import type { Mention, WorkItemInfo } from '../types'

export type Kind = 'pr' | 'workItem'

export type Found = Mention & { kind: Kind }

// dev.azure.com/<org> or the older <org>.visualstudio.com
const HOST = String.raw`https:\/\/(?:dev\.azure\.com\/([^\/\s]+)|([\w-]+)\.visualstudio\.com(?:\/DefaultCollection)?)`
const PR = new RegExp(String.raw`^${HOST}\/([^\/\s]+)\/_git\/([^\/\s?#]+)\/pullrequest\/(\d+)`, 'i')
const WORK_ITEM = new RegExp(String.raw`^${HOST}(?:\/[^\/\s]+)?\/_workitems\/edit\/(\d+)`, 'i')
const URL_RE = /https:\/\/[^\s<>()[\]{}"'`|\\]+/g
// AB#1234: Azure Boards' own notation for a work item.
const AB_RE = /\bAB#(\d+)\b/g

// What a URL is, its canonical form and its label: `repo!12` for a pull
// request (Azure DevOps' own notation), `#1234` for a work item.
export const classify = (url: string): Found | null => {
  const pr = PR.exec(url)
  if (pr) return { kind: 'pr', url: pr[0], label: `${decodeURIComponent(pr[4] ?? '')}!${pr[5]}` }
  const wi = WORK_ITEM.exec(url)
  if (wi) {
    // One URL per work item, whichever project path the mention carried.
    const base = wi[1] ? `https://dev.azure.com/${wi[1]}` : `https://${wi[2]}.visualstudio.com`
    return { kind: 'workItem', url: `${base}/_workitems/edit/${wi[3]}`, label: `#${wi[3]}` }
  }
  return null
}

// Every pull request and work item in a message, in the order written.
// AB#1234 counts only when `organization` is set.
export const findMentions = (text: string, organization = ''): Found[] => {
  const hits: { at: number; found: Found }[] = []
  for (const m of text.matchAll(URL_RE)) {
    const found = classify(m[0])
    if (found) hits.push({ at: m.index ?? 0, found })
  }
  if (organization) {
    for (const m of text.matchAll(AB_RE)) {
      const url = `https://dev.azure.com/${organization}/_workitems/edit/${m[1]}`
      hits.push({ at: m.index ?? 0, found: { kind: 'workItem', url, label: `#${m[1]}` } })
    }
  }
  return hits.sort((a, b) => a.at - b.at).map(h => h.found)
}

// The organization URL and id `az boards work-item show` needs for a work
// item link as `classify` writes it.
export const workItemRef = (url: string): { orgUrl: string; id: string } | null => {
  const m = /^https:\/\/(?:dev\.azure\.com\/([^\/]+)|([\w-]+)\.visualstudio\.com)\/_workitems\/edit\/(\d+)$/.exec(url)
  if (!m || !m[3]) return null
  return { orgUrl: `https://dev.azure.com/${m[1] ?? m[2]}`, id: m[3] }
}

// The title and state in `az boards work-item show -o json` output.
export const parseWorkItem = (json: string): WorkItemInfo | null => {
  try {
    const fields = (JSON.parse(json) as { fields?: Record<string, unknown> }).fields ?? {}
    const title = fields['System.Title']
    const state = fields['System.State']
    return typeof title === 'string' ? { title, state: typeof state === 'string' ? state : '' } : null
  } catch {
    return null
  }
}

// Shortens a title to fit the band.
export const cut = (s: string, max = 20) => {
  const t = s.replace(/\s+/g, ' ').trim()
  return t.length <= max ? t : `${t.slice(0, max - 1).trimEnd()}…`
}

// Moves each found link to the front, the last one written ending up first,
// and keeps `max`.
export const remember = (list: readonly Mention[], found: readonly Found[], max: number): Mention[] => {
  let next = [...list]
  for (const f of found) next = [{ url: f.url, label: f.label }, ...next.filter(m => m.url !== f.url)]
  return next.slice(0, Math.max(0, max))
}

// The text a transcript row carries: a string, or its text blocks.
export const textOf = (content: unknown): string => {
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return ''
  return content
    .map(b => (b && typeof b === 'object' && (b as { type?: unknown }).type === 'text' ? String((b as { text?: unknown }).text ?? '') : ''))
    .join('\n')
}

// The person's prompts and the model's replies in a transcript file's JSONL,
// oldest first; meta rows, tool results and subagent rows are left out.
export const transcriptTexts = (jsonl: string): string[] => {
  const out: string[] = []
  for (const line of jsonl.split('\n')) {
    if (!line.startsWith('{')) continue
    let row: { type?: string; isMeta?: boolean; isSidechain?: boolean; message?: { content?: unknown } }
    try {
      row = JSON.parse(line)
    } catch {
      continue
    }
    if ((row.type !== 'user' && row.type !== 'assistant') || row.isMeta || row.isSidechain) continue
    const text = textOf(row.message?.content)
    if (text) out.push(text)
  }
  return out
}
