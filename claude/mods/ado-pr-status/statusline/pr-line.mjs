// ccstatusline の custom-command ウィジェットから呼ばれる。
// 標準入力の statusLine JSON から session_id を取り、ado-pr-status mod が書いたファイルを 1 行に整形する。
// PR が無いときは何も出さない（ウィジェットごと消える）。
import { readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const TITLE_MAX = 40

// OSC 8 の終端は ST(ESC \) ではなく BEL を使う。ccstatusline 経由だと ESC \ の後半が
// 途中で落ちて、エスケープ列の残骸がリンク文字として表示される（文字化け）ため。
const link = (url, text) => `\x1b]8;;${url}\x07${text}\x1b]8;;\x07`

const format = status => {
  const pr = status.pr
  if (!pr) {
    return status.error ? 'PR: az error' : ''
  }
  const title = pr.title.length > TITLE_MAX ? `${pr.title.slice(0, TITLE_MAX - 1)}…` : pr.title
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
    const { session_id: sessionId } = JSON.parse(input || '{}')
    if (typeof sessionId !== 'string' || !/^[\w-]+$/.test(sessionId)) {
      return
    }
    const status = JSON.parse(readFileSync(join(homedir(), '.claude', 'ado-pr-status', `${sessionId}.json`), 'utf8'))
    process.stdout.write(format(status))
  } catch {
    // ファイルがまだ無い（mod が未取得）などは表示しない
  }
})
