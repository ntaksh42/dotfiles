import type { EngineInterface, Register } from 'claude-code'

// Windows PowerShell 5.1 の AppUserModelID。pwsh 7 は WinRT を読めないため powershell.exe を使う
const APP_ID = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\\WindowsPowerShell\\v1.0\\powershell.exe'
// タイトル・本文は環境変数で渡し、スクリプト側で XML エスケープする（引数経由の注入を避ける）
// rdpmanager で RDP 接続中なら仮想チャネル CCNOTIF でクライアント側へ送り、届かなければローカルにトーストを出す
// （CCNOTIF の仕様は ntaksh42/rdp-manager の docs/remote-notifications.md）
const SCRIPT = [
  "$ErrorActionPreference = 'Stop'",
  '$sent = $false',
  'try { ' + [
    'Add-Type -Namespace ToastNotify -Name Wts -MemberDefinition \'[DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Ansi)] public static extern IntPtr WTSVirtualChannelOpen(IntPtr hServer, int sessionId, string name); [DllImport("wtsapi32.dll", SetLastError = true)] public static extern bool WTSVirtualChannelWrite(IntPtr h, byte[] buffer, int length, out int written); [DllImport("wtsapi32.dll")] public static extern bool WTSVirtualChannelClose(IntPtr h);\'',
    '$m = if ($env:TOAST_NOTIFY_SESSION) { $env:TOAST_NOTIFY_BODY + [Environment]::NewLine + $env:TOAST_NOTIFY_SESSION } else { $env:TOAST_NOTIFY_BODY }',
    '$j = @{ title = $env:TOAST_NOTIFY_TITLE; message = $m; level = $env:TOAST_NOTIFY_LEVEL } | ConvertTo-Json -Compress',
    '$p = [Text.Encoding]::ASCII.GetBytes([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($j)))',
    // 静的チャネルは 1 チャンク 1600 バイトを超えると分割され、受信側で捨てられる
    '$h = if ($p.Length -le 1500) { [ToastNotify.Wts]::WTSVirtualChannelOpen([IntPtr]::Zero, -1, \'CCNOTIF\') } else { [IntPtr]::Zero }',
    'if ($h -ne [IntPtr]::Zero) { try { $w = 0; $sent = [ToastNotify.Wts]::WTSVirtualChannelWrite($h, $p, $p.Length, [ref]$w) -and $w -eq $p.Length } finally { [void][ToastNotify.Wts]::WTSVirtualChannelClose($h) } }',
  ].join('; ') + ' } catch { }',
  'if ($sent) { exit 0 }',
  '[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]',
  '[void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]',
  '$t = [Security.SecurityElement]::Escape($env:TOAST_NOTIFY_TITLE)',
  '$b = [Security.SecurityElement]::Escape($env:TOAST_NOTIFY_BODY)',
  '$s = [Security.SecurityElement]::Escape($env:TOAST_NOTIFY_SESSION)',
  "$a = if ($s) { '<text placement=''attribution''>' + $s + '</text>' } else { '' }",
  '$x = New-Object Windows.Data.Xml.Dom.XmlDocument',
  "$x.LoadXml('<toast><visual><binding template=''ToastGeneric''><text>' + $t + '</text><text>' + $b + '</text>' + $a + '</binding></visual></toast>')",
  '[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($env:TOAST_NOTIFY_APP).Show([Windows.UI.Notifications.ToastNotification]::new($x))',
].join('; ')
const MAX_BODY = 200
// 停滞判定の間隔。活動の記録は同期的にフラグを立てるだけにし、時刻はここで読む
const STALL_TICK_MS = 15_000

// リロードで初期化されるため register で設定し直す
const cfg = { minTurnMs: 30_000, minCommandMs: 60_000, stallMs: 300_000 }
// メインのターン中に、最後に進捗（モデル出力・ツール呼び出し）があった時刻
const stall = { active: false, last: 0, dirty: false, notified: false }
const touch = () => { stall.dirty = true }
// セッション名。/rename や auto-session-title の命名はプロンプト送信・セッション開始の入出力で拾う
let sessionTitle = ''

export const formatDuration = (ms: number) => {
  const s = Math.round(ms / 1000)
  return s < 60 ? `${s}秒` : `${Math.floor(s / 60)}分${s % 60 ? `${s % 60}秒` : ''}`
}

export const firstLine = (text: string) => {
  const line = text.split('\n').map(l => l.trim()).find(l => l !== '') ?? ''
  return line.length > MAX_BODY ? `${line.slice(0, MAX_BODY - 1)}…` : line
}

const project = async ($: EngineInterface) => {
  const cwd = await $.session.cwd()
  return cwd.split(/[\\/]/).filter(Boolean).pop() ?? cwd
}

type Level = 'info' | 'warn'

async function toast($: EngineInterface, title: string, body: string, level: Level) {
  const ran = await $.process.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', SCRIPT], {
    env: { TOAST_NOTIFY_TITLE: `${title} - ${await project($)}`, TOAST_NOTIFY_BODY: body, TOAST_NOTIFY_SESSION: sessionTitle, TOAST_NOTIFY_LEVEL: level, TOAST_NOTIFY_APP: APP_ID },
    timeoutMs: 15_000,
  })
  if (ran.exitCode !== 0) await $.ui.log(`toast-notify: ${ran.stderr.trim().split('\n')[0]}`, { to: 'debug' })
}

// 通知の失敗でフックを止めない。表示を待たずに戻る
const notify = ($: EngineInterface, title: string, body: string, level: Level = 'info') => {
  toast($, title, body, level).catch(error => $.ui.log(`toast-notify: ${String(error)}`, { to: 'debug' }))
}

export const register: Register = (on, options) => {
  if (options.enabled === false) return
  cfg.minTurnMs = Math.max(0, Number(options.minTurnSeconds ?? 30)) * 1000
  cfg.minCommandMs = Math.max(0, Number(options.minCommandSeconds ?? 60)) * 1000
  cfg.stallMs = Math.max(0, Number(options.stallSeconds ?? 300)) * 1000

  if (cfg.stallMs > 0) {
    on('session.start', async ($, e, next) => {
      const started = await next(e)
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
    })

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

  on('turn.complete', async ($, e, next) => {
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
  })

  on('classic.SessionStart', async ($, e, next) => {
    const ran = await next(e)
    sessionTitle = ran.sessionTitle ?? e.session_title ?? sessionTitle
    return ran
  })
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
