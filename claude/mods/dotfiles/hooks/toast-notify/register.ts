import type { Args, EngineInterface, Next, Register } from 'claude-code'

// Windows PowerShell 5.1 の AppUserModelID。pwsh 7 は WinRT を読めないため powershell.exe を使う
const APP_ID = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\\WindowsPowerShell\\v1.0\\powershell.exe'
// 送信は scripts/toast-send.ps1（タイトル・本文は環境変数で渡し、スクリプト側で XML エスケープする）。settings hook 版の scripts/lite-hook.mjs と共有する
const MAX_BODY = 200
// 停滞判定の間隔。活動の記録は同期的にフラグを立てるだけにし、時刻はここで読む
const STALL_TICK_MS = 15_000

// リロードで初期化されるため register で設定し直す
const cfg = { enabled: true, minTurnMs: 30_000, minCommandMs: 60_000, stallMs: 300_000 }
// メインのターン中に、最後に進捗（モデル出力・ツール呼び出し）があった時刻
const stall = { active: false, last: 0, dirty: false, notified: false }
const touch = () => { stall.dirty = true }
// セッション名。/rename や auto-session-title の命名はプロンプト送信・セッション開始の入出力で拾う
// 組織管理下では classic.* が個人インストールの mod に回ってこないため、/rename の実行からも拾う
let sessionTitle = ''

export const formatDuration = (ms: number) => {
  const s = Math.round(ms / 1000)
  return s < 60 ? `${s}秒` : `${Math.floor(s / 60)}分${s % 60 ? `${s % 60}秒` : ''}`
}

export const firstLine = (text: string) => {
  const line = text.split('\n').map(l => l.trim()).find(l => l !== '') ?? ''
  return line.length > MAX_BODY ? `${line.slice(0, MAX_BODY - 1)}…` : line
}

async function project($: EngineInterface) {
  const cwd = await $.session.cwd()
  return cwd.split(/[\\/]/).filter(Boolean).pop() ?? cwd
}

type Level = 'info' | 'warn'

async function toast($: EngineInterface, title: string, body: string, level: Level) {
  const ran = await $.process.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-File', `${$.plugin.root}/scripts/toast-send.ps1`], {
    env: { TOAST_NOTIFY_TITLE: `${title} - ${await project($)}`, TOAST_NOTIFY_BODY: body, TOAST_NOTIFY_SESSION: sessionTitle, TOAST_NOTIFY_LEVEL: level, TOAST_NOTIFY_APP: APP_ID },
    timeoutMs: 15_000,
  })
  if (ran.exitCode !== 0) await $.ui.log(`toast-notify: ${ran.stderr.trim().split('\n')[0]}`, { to: 'debug' })
}

// 通知の失敗でフックを止めない。表示を待たずに戻る
function notify($: EngineInterface, title: string, body: string, level: Level = 'info') {
  toast($, title, body, level).catch(error => $.ui.log(`toast-notify: ${String(error)}`, { to: 'debug' }))
}

export async function sessionStart($: EngineInterface, e: Args<'session.start'>, next: Next<'session.start'>) {
  if (!cfg.enabled) return next(e)
  // settings hook 版（scripts/lite-hook.mjs）は、この環境変数があれば通知しない
  await $.env.set('DOTFILES_MOD_TOAST', '1')
  const started = await next(e)
  if (cfg.stallMs <= 0) return started
  $.clock.every(STALL_TICK_MS, () => {
    $.clock.now().then(now => {
      if (!stall.active) return
      if (stall.dirty) Object.assign(stall, { last: now, dirty: false, notified: false })
      else if (!stall.notified && now - stall.last >= cfg.stallMs) {
        stall.notified = true
        notify($, 'Claude: 停止の可能性', `${formatDuration(cfg.stallMs)}間進捗がありません`, 'warn')
      }
    }, error => $.ui.log(`toast-notify: ${String(error)}`, { to: 'debug' }))
  })
  return started
}

export async function turnComplete($: EngineInterface, e: Args<'turn.complete'>, next: Next<'turn.complete'>) {
  if (!cfg.enabled) return next(e)
  const done = await next(e)
  if (e.agentId === undefined) stall.active = false
  if (e.agentId !== undefined || e.isAborted) return done
  if (e.reason === 'error' || e.reason === 'refusal') {
    const detail = e.reason === 'refusal' ? e.refusal.explanation ?? '' : firstLine(e.answer)
    notify($, 'Claude: エラーで停止', detail || (e.reason === 'refusal' ? 'リクエストが拒否されました' : 'API エラー'), 'warn')
  } else if (e.durationMs >= cfg.minTurnMs) {
    notify($, `Claude: 完了 (${formatDuration(e.durationMs)})`, firstLine(e.answer) || '応答が完了しました')
  }
  return done
}

export async function classicSessionStart($: EngineInterface, e: Args<'classic.SessionStart'>, next: Next<'classic.SessionStart'>) {
  if (!cfg.enabled) return next(e)
  const ran = await next(e)
  sessionTitle = ran.sessionTitle ?? e.session_title ?? sessionTitle
  return ran
}

export async function commandRunRename($: EngineInterface, e: Args<'command.run'>, next: Next<'command.run'>) {
  if (!cfg.enabled) return next(e)
  const ran = await next(e)
  sessionTitle = e.args.trim() || sessionTitle
  return ran
}

export const register: Register = (on, options) => {
  cfg.enabled = options.toastEnabled !== false
  if (!cfg.enabled) return
  cfg.minTurnMs = Math.max(0, Number(options.toastMinTurnSeconds ?? 30)) * 1000
  cfg.minCommandMs = Math.max(0, Number(options.toastMinCommandSeconds ?? 60)) * 1000
  cfg.stallMs = Math.max(0, Number(options.toastStallSeconds ?? 300)) * 1000

  if (cfg.stallMs > 0) {

    on('turn.start', async ($, e, next) => {
      Object.assign(stall, { active: true, last: await $.clock.now(), dirty: false, notified: false })
      return next(e)
    })

    // サブエージェントの出力も進捗とみなす
    on('turn.step', async function* ($, e, next) {
      const stream = next(e)
      for await (const chunk of stream) {
        touch()
        yield chunk
      }
      return await stream.result
    })
  }


  on('classic.UserPromptSubmit', async ($, e, next) => {
    const ran = await next(e)
    sessionTitle = ran.sessionTitle ?? e.session_title ?? sessionTitle
    return ran
  })

  // 許可・質問ダイアログ。idle_prompt はターン完了通知と重なるので出さない
  on('classic.Notification', async ($, e, next) => {
    const done = await next(e)
    if (e.agent_id === undefined && e.notification_type !== 'idle_prompt' && e.notification_type !== 'auth_success') {
      notify($, 'Claude: 入力待ち', e.message, 'warn')
    }
    return done
  })

  // ツールの開始・終了も進捗とみなす（実行中のまま 5 分黙ったコマンドは停滞として通知する）
  on('tool.call', async ($, e, next) => {
    touch()
    try {
      return await next(e)
    } finally {
      touch()
    }
  })

  for (const tool of ['Bash', 'PowerShell'] as const) {
    on('tool.call', { tool }, async ($, e, next) => {
      const started = await $.clock.now()
      const ran = await next(e)
      const elapsed = (await $.clock.now()) - started
      if (ran.deny === undefined && elapsed >= cfg.minCommandMs) {
        const failed = ran.isError === true
        notify($, `${failed ? 'コマンド失敗' : 'コマンド完了'} (${formatDuration(elapsed)})`, firstLine(e.command), failed ? 'warn' : 'info')
      }
      return ran
    })
  }
}
