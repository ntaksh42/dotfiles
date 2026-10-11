// 新しい順・重複なしの PowerShell 履歴と、ペインの絞り込み語
export type CmdHistoryEntries = string[]

declare module 'claude-code' {
  interface PluginState {
    'cmdHistory': { entries: CmdHistoryEntries; filter: string }
  }
}
