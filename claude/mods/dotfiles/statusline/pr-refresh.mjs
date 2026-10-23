// pr-line.mjs が裏で起動する。現在のブランチの Azure DevOps PR を取得し、pr-line.mjs が読むファイルに書き出す。
// 使い方: node pr-refresh.mjs <session_id> <cwd>
import { execFile } from 'node:child_process'
import { existsSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'

import { parseAdoRemote, summarize } from './ado.ts'

const run = promisify(execFile)
const [sessionId, cwd] = process.argv.slice(2)
if (!sessionId || !/^[\w-]+$/.test(sessionId) || !cwd) process.exit(0)

const dir = join(homedir(), '.claude', 'ado-pr-status')
const lock = join(dir, `${sessionId}.lock`)

const git = async args => {
  try {
    return (await run('git', args, { cwd })).stdout.trim()
  } catch {
    return ''
  }
}

/**
 * パイプ時の az は ANSI コードページ (日本語環境では cp932) で JSON を出す。MSI 版の az.cmd は
 * python を -I で起動するため PYTHONUTF8 が効かない。そこで Windows では az.cmd と同じ
 * ..\python.exe を -X utf8 付きで直接起動する（しないとタイトルが文字化けする）。
 * 見つからなければ cmd 経由で az.cmd を起動する。
 */
const azBase = async () => {
  if (process.platform !== 'win32') return ['az']
  try {
    const cmd = (await run('where', ['az.cmd'])).stdout.split(/\r?\n/)[0]?.trim() ?? ''
    const python = cmd.replace(/[\\/][^\\/]+[\\/][^\\/]+$/, '\\python.exe')
    if (cmd !== '' && existsSync(python)) return [python, '-X', 'utf8', '-IBm', 'azure.cli']
  } catch {
    // az.cmd が見つからない
  }
  return ['cmd', '/d', '/c', 'az']
}

// cmd reads & | < > ^ % " ( ) itself. A branch name or remote URL may carry them, so they never go through cmd.
const CMD_UNSAFE = /[&|<>^%"!()\r\n]/

mkdirSync(dir, { recursive: true })
try {
  const branch = await git(['rev-parse', '--abbrev-ref', 'HEAD'])
  const remote = await git(['remote', 'get-url', 'origin'])
  const repo = parseAdoRemote(remote)
  const status = { updatedAt: Date.now(), branch, pr: null }
  if (repo !== null && branch !== '' && branch !== 'HEAD') {
    const [file, ...head] = await azBase()
    const args = [
      'repos', 'pr', 'list',
      '--organization', repo.orgUrl,
      '--project', repo.project,
      '--repository', repo.repo,
      '--source-branch', `refs/heads/${branch}`,
      '--status', 'active',
      '--top', '1',
      '-o', 'json',
    ]
    try {
      if (file === 'cmd' && args.some(a => CMD_UNSAFE.test(a))) throw new Error('branch or remote has characters cmd would run')
      const { stdout } = await run(file, [...head, ...args], { timeout: 30_000, maxBuffer: 8 * 1024 * 1024 })
      const first = JSON.parse(stdout)[0]
      status.pr = first === undefined ? null : summarize(repo, first)
    } catch (error) {
      status.error = String(error.stderr ?? error.message).trim().split('\n')[0]
    }
  }
  writeFileSync(join(dir, `${sessionId}.json`), JSON.stringify(status))
} finally {
  rmSync(lock, { force: true })
}
