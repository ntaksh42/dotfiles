// 1 セッション分の記録: 数えたプロンプト数、最初の依頼、直近の依頼
export type TitleSession = { count: number; first: string; recent: string[] }

declare module 'claude-code' {
  interface PluginState {
    'auto-session-title': { sessions: Record<string, TitleSession>; ownTitles: string[] }
  }
}
