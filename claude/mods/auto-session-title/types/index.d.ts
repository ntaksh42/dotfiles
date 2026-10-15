// 1 セッション分の記録: 数えたプロンプト数、最初の依頼、直近の依頼
export type TitleSession = { count: number; first: string; recent: string[] }
// 今のタイトルと、それが手動の /rename で付いたものか
export type TitleCurrent = { title: string; manual: boolean }

declare module 'claude-code' {
  interface PluginState {
    'auto-session-title': { sessions: Record<string, TitleSession>; current: TitleCurrent }
  }
}
