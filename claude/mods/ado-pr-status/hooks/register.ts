import type { EngineInterface, Register } from 'claude-code'

import { parseAdoRemote, summarize } from './ado'
import type { StatusFile } from './ado'

/** ブランチの切り替えを見る間隔と、同じブランチで PR を取り直す間隔 */
const CHECK_MS = 15_000
const PR_TTL_MS = 120_000

// 直前に取得したリモートとブランチ。リロードで初期化されるが、そのときは取り直すだけ
let lastKey = ''
let lastFetchedAt = 0

async function git($: EngineInterface, args: string[], cwd: string): Promise<string> {
  const ran = await $.process.run(['git', ...args], { cwd })

  return ran.exitCode === 0 ? ran.stdout.trim() : ''
}

/** az.cmd はシェル経由でないと起動できないので、Windows では cmd を挟む */
async function az($: EngineInterface, args: string[]) {
  const isWindows = (await $.env.get('OS')) === 'Windows_NT'
  const argv = isWindows ? ['cmd', '/d', '/c', 'az', ...args] : ['az', ...args]

  return $.process.run(argv, { timeoutMs: 30_000 })
}

async function statusPath($: EngineInterface): Promise<string> {
  const home = (await $.env.get('USERPROFILE')) ?? (await $.env.get('HOME')) ?? '.'

  return `${home.replace(/\\/g, '/')}/.claude/ado-pr-status/${await $.session.id()}.json`
}

async function refresh($: EngineInterface, isForced: boolean): Promise<void> {
  const cwd = await $.session.cwd()
  const branch = await git($, ['rev-parse', '--abbrev-ref', 'HEAD'], cwd)
  const remote = await git($, ['remote', 'get-url', 'origin'], cwd)
  const key = `${remote}|${branch}`
  const now = await $.clock.now()
  if (!isForced && key === lastKey && now - lastFetchedAt < PR_TTL_MS) {
    return
  }
  lastKey = key
  lastFetchedAt = now

  const repo = parseAdoRemote(remote)
  let status: StatusFile = { updatedAt: now, branch, pr: null }
  if (repo !== null && branch !== '' && branch !== 'HEAD') {
    const ran = await az($, [
      'repos', 'pr', 'list',
      '--organization', repo.orgUrl,
      '--project', repo.project,
      '--repository', repo.repo,
      '--source-branch', `refs/heads/${branch}`,
      '--status', 'active',
      '--top', '1',
      '-o', 'json',
    ])
    if (ran.exitCode === 0) {
      const list = JSON.parse(ran.stdout) as Parameters<typeof summarize>[1][]
      status = { ...status, pr: list[0] === undefined ? null : summarize(repo, list[0]) }
    } else {
      status = { ...status, error: ran.stderr.trim().split('\n')[0] ?? `az exited ${ran.exitCode}` }
    }
  }
  await $.fs.write(await statusPath($), JSON.stringify(status))
}

function refreshSafely($: EngineInterface, isForced: boolean): void {
  refresh($, isForced).catch(error => $.ui.log(`ado-pr-status: ${String(error)}`, { to: 'debug' }))
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    refreshSafely($, true)
    $.clock.every(CHECK_MS, () => refreshSafely($, false))

    return started
  })

  // Claude がブランチを切ったり PR を作ったりした直後に追従する
  on('turn.complete', async ($, e, next) => {
    const done = await next(e)
    refreshSafely($, true)

    return done
  })
}
