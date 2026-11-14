import { describe, expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { firstLine, formatDuration } from '../hooks/toast-notify/register'

type Toast = { title: string; body: string; session?: string; level?: string }

// エンジン側の応答。process.run で出したトーストを記録し、コマンドは runMs だけ時計を進める
const engine = (on: On, toasts: Toast[], runMs = 0, isError = false, env: Record<string, string> = {}) => {
  let now = 0
  on('env.get', (_$, e) => ({ value: env[e.name] }) as never)
  on('session.cwd', () => ({ value: 'E:\\work\\shop' }) as never)
  on('command.register', () => ({ value: undefined }) as never)
  on('ui.log', () => ({ value: undefined }) as never)
  on('clock.now', () => ({ value: now }) as never)
  on('process.run', (_$, e) => {
    const env = e.init?.env ?? {}
    // 同じ plugin の他の mod（ado-pr-status の git / az など）の呼び出しは記録しない
    if (env.TOAST_NOTIFY_TITLE !== undefined) toasts.push({ title: env.TOAST_NOTIFY_TITLE ?? '', body: env.TOAST_NOTIFY_BODY ?? '', session: env.TOAST_NOTIFY_SESSION })
    return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } } as never
  })
  on('turn.complete', () => ({ text: '' }))
  on('classic.Notification', () => ({}))
  on('tool.call', { tool: 'Bash' }, () => {
    now += runMs
    return { result: {}, text: '', isError } as never
  })
}

const settle = () => new Promise(r => setTimeout(r, 0))

const turn = (durationMs: number, extra: object = {}) =>
  ({ answer: '修正しました。\n詳細…', durationMs, isAborted: false, turnId: 't1', reason: 'answer', ...extra }) as never

describe('helpers', () => {
  test('所要時間の表記', () => {
    expect(formatDuration(42_000)).toBe('42秒')
    expect(formatDuration(120_000)).toBe('2分')
    expect(formatDuration(125_000)).toBe('2分5秒')
  })

  test('最初の空でない行を本文にする', () => {
    expect(firstLine('\n  foo \nbar')).toBe('foo')
    expect(firstLine('x'.repeat(300))).toHaveLength(200)
  })
})

describe('turn.complete', () => {
  test('長いターンは通知する', async ($, on) => {
    const toasts: Toast[] = []
    engine(on, toasts)
    await $.turn.complete(turn(45_000))
    await settle()
    expect(toasts).toEqual([{ title: 'Claude: 完了 (45秒) - shop', body: '修正しました。', session: '' }])
  })

  test('短いターン・中断・サブエージェントは通知しない', async ($, on) => {
    const toasts: Toast[] = []
    engine(on, toasts)
    await $.turn.complete(turn(5_000))
    await $.turn.complete(turn(60_000, { isAborted: true, reason: 'aborted' }))
    await $.turn.complete(turn(60_000, { agentId: 'a1' }))
    await settle()
    expect(toasts).toEqual([])
  })

  test('エラーは短くても通知する', async ($, on) => {
    const toasts: Toast[] = []
    engine(on, toasts)
    await $.turn.complete(turn(1_000, { reason: 'error', answer: '' }))
    await settle()
    expect(toasts).toEqual([{ title: 'Claude: エラーで停止 - shop', body: 'API エラー', session: '' }])
  })

  test('しきい値は設定で変えられる', { options: { toastMinTurnSeconds: 3 } }, async ($, on) => {
    const toasts: Toast[] = []
    engine(on, toasts)
    await $.turn.complete(turn(5_000))
    await settle()
    expect(toasts).toHaveLength(1)
  })

  test('無効化すると何もしない', { options: { toastEnabled: false } }, async ($, on) => {
    const toasts: Toast[] = []
    engine(on, toasts)
    await $.turn.complete(turn(600_000))
    await settle()
    expect(toasts).toEqual([])
  })
})

describe('classic.Notification', () => {
  test('許可待ちは通知し、idle_prompt は通知しない', async ($, on) => {
    const toasts: Toast[] = []
    engine(on, toasts)
    await $.classic.Notification({ message: 'Claude needs your permission to use Bash', notification_type: 'permission_prompt' })
    await $.classic.Notification({ message: 'Claude is waiting for your input', notification_type: 'idle_prompt' })
    await settle()
    expect(toasts).toEqual([{ title: 'Claude: 入力待ち - shop', body: 'Claude needs your permission to use Bash', session: '' }])
  })
})

describe('Orca 上のセッション', () => {
  const ORCA = { ORCA_AGENT_SESSION_ID: 'claude_x' }

  test('完了と入力待ちは Orca に任せて通知しない', async ($, on) => {
    const toasts: Toast[] = []
    engine(on, toasts, 0, false, ORCA)
    await $.turn.complete(turn(45_000))
    await $.classic.Notification({ message: 'Claude needs your permission to use Bash', notification_type: 'permission_prompt' })
    await settle()
    expect(toasts).toEqual([])
  })

  test('エラーと長いコマンドは通知する', async ($, on) => {
    const toasts: Toast[] = []
    engine(on, toasts, 90_000, false, ORCA)
    await $.turn.complete(turn(1_000, { reason: 'error', answer: '' }))
    await $.tool.call({ tool: 'Bash', command: 'npm test' } as never)
    await settle()
    expect(toasts.map(t => t.title)).toEqual(['Claude: エラーで停止 - shop', 'コマンド完了 (1分30秒) - shop'])
  })
})

describe('tool.call', () => {
  test('長いコマンドの完了を通知する', async ($, on) => {
    const toasts: Toast[] = []
    engine(on, toasts, 90_000)
    await $.tool.call({ tool: 'Bash', command: 'npm test\n--watch=false' } as never)
    await settle()
    expect(toasts).toEqual([{ title: 'コマンド完了 (1分30秒) - shop', body: 'npm test', session: '' }])
  })

  test('失敗したコマンドは失敗として通知する', async ($, on) => {
    const toasts: Toast[] = []
    engine(on, toasts, 90_000, true)
    await $.tool.call({ tool: 'Bash', command: 'npm test' } as never)
    await settle()
    expect(toasts[0]?.title).toBe('コマンド失敗 (1分30秒) - shop')
  })

  test('短いコマンドは通知しない', async ($, on) => {
    const toasts: Toast[] = []
    engine(on, toasts, 2_000)
    await $.tool.call({ tool: 'Bash', command: 'ls' } as never)
    await settle()
    expect(toasts).toEqual([])
  })
})

describe('停滞検知', () => {
  // mock.clock で時計を進める。process.run で出したトーストを記録する
  const stallEngine = (on: On, toasts: Toast[], runTool?: () => Promise<void>) => {
    const clock = mock.clock(on)
    on('session.cwd', () => ({ value: 'E:/work/shop' }) as never)
    on('command.register', () => ({ value: undefined }) as never)
    on('env.set', () => ({ value: {} }) as never)
    on('env.get', () => ({ value: undefined }) as never)
    on('ui.log', () => ({ value: undefined }) as never)
    on('process.run', (_$, e) => {
      const env = e.init?.env ?? {}
      if (env.TOAST_NOTIFY_TITLE !== undefined) toasts.push({ title: env.TOAST_NOTIFY_TITLE, body: env.TOAST_NOTIFY_BODY ?? '', level: env.TOAST_NOTIFY_LEVEL })
      return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } } as never
    })
    on('session.start', (_$, e) => ({ cwd: e.cwd }))
    on('turn.start', (_$, e) => ({ turnId: e.turnId }))
    on('turn.complete', () => ({ text: '' }))
    on('classic.Notification', () => ({}))
    on('tool.call', async () => {
      await runTool?.()
      return { result: {}, text: '' } as never
    })
    return clock
  }

  const STALL = { title: 'Claude: 停止の可能性 - shop', body: '5分間進捗がありません', level: 'warn' }

  test('ターン中に 5 分進捗がなければ一度だけ通知する', async ($, on) => {
    const toasts: Toast[] = []
    const clock = stallEngine(on, toasts)
    await $.session.start({ cwd: 'E:/work/shop', surface: 'terminal', isInteractive: true })
    await $.turn.start({ text: 'fix', turnId: 't1' })
    await clock.settle()
    await clock.advance(4 * 60_000)
    expect(toasts).toEqual([])
    await clock.advance(90_000)
    expect(toasts).toEqual([STALL])
    await clock.advance(10 * 60_000)
    expect(toasts).toEqual([STALL])
  })

  test('ツール呼び出しがあればタイマーをリセットする', async ($, on) => {
    const toasts: Toast[] = []
    const clock = stallEngine(on, toasts)
    await $.session.start({ cwd: 'E:/work/shop', surface: 'terminal', isInteractive: true })
    await $.turn.start({ text: 'fix', turnId: 't1' })
    await clock.settle()
    await clock.advance(4 * 60_000)
    await $.tool.call({ tool: 'Read', file_path: 'E:/work/shop/a.ts' } as never)
    await clock.advance(4 * 60_000)
    expect(toasts).toEqual([])
    await clock.advance(90_000)
    expect(toasts).toEqual([STALL])
  })

  test('ターン完了後は通知しない', async ($, on) => {
    const toasts: Toast[] = []
    const clock = stallEngine(on, toasts)
    await $.session.start({ cwd: 'E:/work/shop', surface: 'terminal', isInteractive: true })
    await $.turn.start({ text: 'fix', turnId: 't1' })
    await clock.settle()
    await $.turn.complete(turn(1_000))
    await clock.advance(10 * 60_000)
    expect(toasts).toEqual([])
  })

  test('長時間のコマンドは停滞警告ではなく実行中として一度通知する', async ($, on) => {
    const toasts: Toast[] = []
    let finish!: () => void
    const clock = stallEngine(on, toasts, () => new Promise<void>(resolve => { finish = resolve }))
    await $.session.start({ cwd: 'E:/work/shop', surface: 'terminal', isInteractive: true })
    await $.turn.start({ text: 'fix', turnId: 't1' })
    const pending = $.tool.call({ tool: 'Bash', command: 'npm test' } as never)
    await settle()
    expect(typeof finish).toBe('function')
    await clock.settle()
    await clock.advance(6 * 60_000)
    expect(toasts).toEqual([{ title: 'Claude: コマンド実行中 - shop', body: 'npm test', level: 'info' }])
    await clock.advance(6 * 60_000)
    expect(toasts).toHaveLength(1)
    finish()
    await pending
    await clock.settle()
    toasts.length = 0
    await clock.advance(6 * 60_000)
    expect(toasts).toEqual([STALL])
  })

  test('入力待ちの間は停滞警告を出さず、ツール完了後は検知を再開する', async ($, on) => {
    const toasts: Toast[] = []
    const clock = stallEngine(on, toasts)
    await $.session.start({ cwd: 'E:/work/shop', surface: 'terminal', isInteractive: true })
    await $.turn.start({ text: 'fix', turnId: 't1' })
    await $.classic.Notification({ message: 'Permission needed', notification_type: 'permission_prompt' })
    await clock.settle()
    expect(toasts[0]?.title).toBe('Claude: 入力待ち - shop')
    await clock.advance(10 * 60_000)
    expect(toasts).toHaveLength(1)
    await $.tool.call({ tool: 'Read', file_path: 'a.ts' } as never)
    await clock.advance(6 * 60_000)
    expect(toasts[1]).toEqual(STALL)
  })

  test('サブエージェントの開始でメインの停滞タイマーをリセットしない', async ($, on) => {
    const toasts: Toast[] = []
    const clock = stallEngine(on, toasts)
    await $.session.start({ cwd: 'E:/work/shop', surface: 'terminal', isInteractive: true })
    await $.turn.start({ text: 'fix', turnId: 't1' })
    await clock.settle()
    await clock.advance(4 * 60_000)
    await $.turn.start({ text: 'subtask', turnId: 'sub', agentId: 'a1' } as never)
    await clock.advance(90_000)
    expect(toasts).toEqual([STALL])
  })

  test('0 秒にすると無効になる', { options: { toastStallSeconds: 0 } }, async ($, on) => {
    const toasts: Toast[] = []
    const clock = stallEngine(on, toasts)
    await $.session.start({ cwd: 'E:/work/shop', surface: 'terminal', isInteractive: true })
    await $.turn.start({ text: 'fix', turnId: 't1' })
    await clock.settle()
    await clock.advance(10 * 60_000)
    expect(toasts).toEqual([])
  })
})

describe('セッション名', () => {
  test('プロンプト送信時のセッション名をトーストに載せる', async ($, on) => {
    const toasts: Toast[] = []
    engine(on, toasts)
    on('classic.UserPromptSubmit', () => ({}))
    on('classic.SessionStart', () => ({ sessionTitle: '決済画面の修正' }))
    await $.turn.complete(turn(45_000))
    await settle()
    await $.classic.SessionStart({ source: 'startup' } as never)
    await $.turn.complete(turn(45_000))
    await settle()
    await $.classic.UserPromptSubmit({ prompt: 'x', session_title: 'リネーム後' } as never)
    await $.turn.complete(turn(45_000))
    await settle()
    expect(toasts.map(t => t.session)).toEqual(['', '決済画面の修正', 'リネーム後'])
  })

  test('/rename で付けた名前をトーストに載せる', async ($, on) => {
    const toasts: Toast[] = []
    engine(on, toasts)
    on('command.run', () => ({ text: '' }))
    await $.command.run({ command: 'rename', args: '組織環境での命名' })
    await $.turn.complete(turn(45_000))
    await settle()
    expect(toasts.map(t => t.session)).toEqual(['組織環境での命名'])
  })
})
