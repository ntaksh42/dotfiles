import type { ApiContentBlock, Register } from 'claude-code'

// PSReadLine の既定の履歴ファイルへ追記する。コマンドは環境変数で渡す（引数経由の注入と stdin の文字コードを避ける）
const SCRIPT = [
  "$ErrorActionPreference = 'Stop'",
  "$p = Join-Path $env:APPDATA 'Microsoft/Windows/PowerShell/PSReadLine/ConsoleHost_history.txt'",
  // 既存の履歴に合わせて改行を CRLF にする
  '$nl = [Environment]::NewLine',
  '[IO.File]::AppendAllText($p, ($env:BANG_HISTORY_LINE -replace "`n", $nl) + $nl)',
].join('; ')

// `!` で実行したコマンドは `<bash-input>...</bash-input>` だけを持つ user 行として会話に追加される
export const bangCommand = (content: readonly ApiContentBlock[]) => {
  const text = content.map(b => (b.type === 'text' ? b.text : '')).join('')
  const m = /^<bash-input>([\s\S]*)<\/bash-input>$/.exec(text.trim())
  return m?.[1]?.trim() || undefined
}

// PSReadLine は複数行の項目を、最終行以外の行末にバッククォートを付けて保存する
export const historyEntry = (command: string) => command.split(/\r?\n/).join('`\n')

export const register: Register = on => {
  on('session.append', async ($, e, next) => {
    const result = await next(e)
    const command = e.agentId === undefined && e.message.type === 'user' ? bangCommand(e.message.content) : undefined
    if (command) {
      $.process.run(['pwsh', '-NoProfile', '-NonInteractive', '-Command', SCRIPT], { env: { BANG_HISTORY_LINE: historyEntry(command) }, timeoutMs: 15_000 })
        .then(r => r.exitCode !== 0 && $.ui.log(`bang-history: ${r.stderr.trim().split('\n')[0]}`, { to: 'debug' }))
        .catch(error => $.ui.log(`bang-history: ${String(error)}`, { to: 'debug' }))
    }
    return result
  })
}
