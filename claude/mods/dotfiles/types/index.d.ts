// ado-link-bar: バーに出すリンク（新しい順、設定の件数で切り詰め済み）
export type Mention = { url: string; label: string }
export type Links = { prs: Mention[]; workItems: Mention[] }
// ado-link-bar: 作業項目のタイトルと状態（URL をキーにする）
export type WorkItemInfo = { title: string; state: string }
export type WorkItemDetails = Record<string, WorkItemInfo>

// auto-session-title: 1 セッション分の記録（数えたプロンプト数、最初の依頼、直近の依頼）
export type TitleSession = { count: number; first: string; recent: string[] }
// auto-session-title: 今のタイトルと、それが手動の /rename で付いたものか
export type TitleCurrent = { title: string; manual: boolean }

// cmdHistory: 新しい順・重複なしの PowerShell 履歴
export type CmdHistoryEntries = string[]

declare module 'claude-code' {
  interface PluginState {
    dotfiles: {
      links: Links
      details: WorkItemDetails
      sessions: Record<string, TitleSession>
      current: TitleCurrent
      entries: CmdHistoryEntries
      filter: string
    }
  }
}
