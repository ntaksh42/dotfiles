// ccstatusline の custom-command ウィジェットから呼ばれる。
// 標準入力の statusLine JSON から session_id と cwd を取り、PR の情報を 1 行に整形する。
// 情報は pr-refresh.mjs が裏で取得してファイルに書く。ファイルが無い・古い・ブランチが変わったときは
// 古い内容を出したまま裏で取り直す（az は遅く、ウィジェットのタイムアウトは 1 秒）。
// PR が無いときは何も出さない（ウィジェットごと消える）。
import { execFileSync, spawn } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const TITLE_MAX = 40
const PR_TTL_MS = 120_000
const LOCK_TTL_MS = 60_000
const REFRESH = join(dirname(fileURLToPath(import.meta.url)), 'pr-refresh.mjs')

const currentBranch = cwd => {
  try {
    return execFileSync('git', ['rev-parse', '--abbrev-ref', 'HEAD'], { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 500 }).trim()
  } catch {
    return ''
  }
}

// 同時に 2 つ以上取りに行かないよう、ロックファイルで止める
const refreshInBackground = (dir, sessionId, cwd) => {
  const lock = join(dir, `${sessionId}.lock`)
  try {
    if (existsSync(lock) && Date.now() - statSync(lock).mtimeMs < LOCK_TTL_MS) return
    mkdirSync(dir, { recursive: true })
    writeFileSync(lock, '')
    spawn(process.execPath, [REFRESH, sessionId, cwd], { detached: true, stdio: 'ignore', windowsHide: true }).unref()
  } catch {
    // 取り直せなくても表示は続ける
  }
}

// OSC 8 の終端は ST(ESC \) ではなく BEL を使う。ccstatusline 経由だと ESC \ の後半が
// 途中で落ちて、エスケープ列の残骸がリンク文字として表示される（文字化け）ため。
const link = (url, text) => `\x1b]8;;${url}\x07${text}\x1b]8;;\x07`

const format = status => {
  const pr = status.pr
  if (!pr) {
    return status.error ? 'PR: az error' : ''
  }
  // PR タイトルは他人が書ける。エスケープシーケンスで表示やリンクを偽装されないよう制御文字を落とす
  const plain = String(pr.title).replace(/[\x00-\x1f\x7f-\x9f]/g, '')
  const title = plain.length > TITLE_MAX ? `${plain.slice(0, TITLE_MAX - 1)}…` : plain
  const marks = [
    pr.reviewers > 0 ? `✓${pr.approved}/${pr.reviewers}` : '',
    pr.isRejected ? '✗' : '',
    pr.isWaiting ? 'waiting' : '',
  ].filter(Boolean)

  return [link(pr.url, `PR !${pr.id}${pr.isDraft ? ' (draft)' : ''}`), title, ...marks].join(' ')
}

let input = ''
process.stdin.setEncoding('utf8')
process.stdin.on('data', chunk => (input += chunk))
process.stdin.on('end', () => {
  try {
    const data = JSON.parse(input || '{}')
    const sessionId = data.session_id
    if (typeof sessionId !== 'string' || !/^[\w-]+$/.test(sessionId)) {
      return
    }
    const cwd = data.workspace?.current_dir ?? data.cwd
    const dir = join(homedir(), '.claude', 'ado-pr-status')
    let status
    try {
      status = JSON.parse(readFileSync(join(dir, `${sessionId}.json`), 'utf8'))
    } catch {
      // まだ取得していない
    }
    if (typeof cwd === 'string' && (!status || Date.now() - status.updatedAt > PR_TTL_MS || status.branch !== currentBranch(cwd))) {
      refreshInBackground(dir, sessionId, cwd)
    }
    if (status) process.stdout.write(format(status))
  } catch {
    // 表示できなければ何も出さない
  }
})
