// mod が使えない環境（組織の allowManagedModsOnly など）向けの代替。plugin の hooks/hooks.json から
// settings hook として呼ばれ、toast-notify と auto-session-title の主な機能を肩代わりする。
// mod が動いているセッションでは、mod が DOTFILES_MOD_TOAST / DOTFILES_MOD_TITLE を設定するので何もしない。
// 使い方: node lite-hook.mjs <prompt|stop|stop-failure|notification|post-tool>（標準入力は hook の JSON）
import { spawn } from 'node:child_process'
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const MIN_TURN_MS = 30_000
const MIN_COMMAND_MS = 60_000
const MAX_BODY = 200
const TITLE_MAX = 40
// Windows PowerShell 5.1 の AppUserModelID（mod 側と同じ）
const APP_ID = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\\WindowsPowerShell\\v1.0\\powershell.exe'
const SEND = join(dirname(fileURLToPath(import.meta.url)), 'toast-send.ps1')
const STATE = join(tmpdir(), 'dotfiles-lite')

const formatDuration = ms => {
  const s = Math.round(ms / 1000)
  return s < 60 ? `${s}秒` : `${Math.floor(s / 60)}分${s % 60 ? `${s % 60}秒` : ''}`
}

const firstLine = text => {
  const line = String(text ?? '').split('\n').map(l => l.trim()).find(l => l !== '') ?? ''
  return line.length > MAX_BODY ? `${line.slice(0, MAX_BODY - 1)}…` : line
}

const safeId = id => (typeof id === 'string' && /^[\w-]+$/.test(id) ? id : 'unknown')
const stateFile = (kind, id) => join(STATE, `${kind}-${safeId(id)}`)
const remember = (kind, id, value) => {
  mkdirSync(STATE, { recursive: true })
  writeFileSync(stateFile(kind, id), String(value))
}
const recall = (kind, id) => {
  try {
    return readFileSync(stateFile(kind, id), 'utf8')
  } catch {
    return undefined
  }
}

// 通知は表示を待たずに戻る（hook を止めない）
const toast = (input, title, body, level = 'info') => {
  const env = {
    ...process.env,
    TOAST_NOTIFY_TITLE: `${title} - ${basename(input.cwd ?? '') || input.cwd || ''}`,
    TOAST_NOTIFY_BODY: body,
    TOAST_NOTIFY_SESSION: '',
    TOAST_NOTIFY_LEVEL: level,
    TOAST_NOTIFY_APP: APP_ID,
  }
  spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-File', SEND], { env, detached: true, stdio: 'ignore', windowsHide: true }).unref()
}

const handlers = {
  // 最初のプロンプトの先頭行をセッション名にする（手動の /rename は上書きしない: 付けるのは一度だけ）
  prompt(input) {
    if (!process.env.DOTFILES_MOD_TOAST) remember('turn', input.session_id, Date.now())
    if (input.source !== undefined && input.source !== 'user') return
    if (process.env.DOTFILES_MOD_TITLE || recall('titled', input.session_id) !== undefined) return
    const text = String(input.prompt ?? '').trim()
    if (!text || text.startsWith('/')) return
    remember('titled', input.session_id, 1)
    const title = (text.split('\n')[0] ?? '').slice(0, TITLE_MAX)
    process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'UserPromptSubmit', sessionTitle: title } }))
  },
  stop(input) {
    if (input.agent_id !== undefined) return
    const started = Number(recall('turn', input.session_id))
    if (!started) return
    rmSync(stateFile('turn', input.session_id), { force: true })
    const elapsed = Date.now() - started
    if (elapsed >= MIN_TURN_MS) {
      toast(input, `Claude: 完了 (${formatDuration(elapsed)})`, firstLine(input.last_assistant_message) || '応答が完了しました')
    }
  },
  'stop-failure'(input) {
    toast(input, 'Claude: エラーで停止', firstLine(input.error_details) || 'API エラー', 'warn')
  },
  // 許可・質問ダイアログ。idle_prompt はターン完了通知と重なるので出さない
  notification(input) {
    if (input.agent_id !== undefined || input.notification_type === 'idle_prompt' || input.notification_type === 'auth_success') return
    toast(input, 'Claude: 入力待ち', firstLine(input.message), 'warn')
  },
  'post-tool'(input) {
    if (Number(input.duration_ms) >= MIN_COMMAND_MS) {
      toast(input, `コマンド完了 (${formatDuration(input.duration_ms)})`, firstLine(input.tool_input?.command))
    }
  },
}

const mode = process.argv[2] ?? ''
const isToastMode = mode !== 'prompt'
// mod が動いている間は mod に任せる。prompt はタイトルと所要時間の記録を別々に判定する
if (handlers[mode] && !(isToastMode && process.env.DOTFILES_MOD_TOAST)) {
  let raw = ''
  process.stdin.setEncoding('utf8')
  process.stdin.on('data', chunk => (raw += chunk))
  process.stdin.on('end', () => {
    try {
      handlers[mode](JSON.parse(raw || '{}'))
    } catch {
      // 通知の失敗で hook を失敗させない
    }
  })
}
