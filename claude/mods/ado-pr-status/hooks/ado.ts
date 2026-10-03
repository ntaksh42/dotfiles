export type AdoRepo = { orgUrl: string; project: string; repo: string }

export type PrSummary = {
  id: number
  title: string
  url: string
  isDraft: boolean
  /** 承認（vote 10 / 5）した人数と、レビュアー全体の人数 */
  approved: number
  reviewers: number
  isRejected: boolean
  isWaiting: boolean
}

/** ccstatusline 側のスクリプトが読むファイルの中身 */
export type StatusFile = { updatedAt: number; branch: string; pr: PrSummary | null; error?: string }

const decode = (part: string) => decodeURIComponent(part).replace(/\.git$/, '')

/** origin の URL から Azure DevOps の組織・プロジェクト・リポジトリを読む。ADO でなければ null */
export const parseAdoRemote = (url: string): AdoRepo | null => {
  const patterns: Array<[RegExp, (m: RegExpExecArray) => AdoRepo]> = [
    [
      /^https:\/\/(?:[^@/]+@)?dev\.azure\.com\/([^/]+)\/([^/]+)\/_git\/([^/?#]+)/,
      m => ({ orgUrl: `https://dev.azure.com/${m[1]}`, project: decode(m[2] ?? ''), repo: decode(m[3] ?? '') }),
    ],
    [
      /^https:\/\/(?:[^@/]+@)?([^./]+)\.visualstudio\.com\/(?:DefaultCollection\/)?([^/]+)\/_git\/([^/?#]+)/,
      m => ({ orgUrl: `https://dev.azure.com/${m[1]}`, project: decode(m[2] ?? ''), repo: decode(m[3] ?? '') }),
    ],
    [
      /^(?:ssh:\/\/)?[^@]+@(?:ssh\.dev\.azure\.com|vs-ssh\.visualstudio\.com):v3\/([^/]+)\/([^/]+)\/([^/]+)$/,
      m => ({ orgUrl: `https://dev.azure.com/${m[1]}`, project: decode(m[2] ?? ''), repo: decode(m[3] ?? '') }),
    ],
  ]
  for (const [pattern, toRepo] of patterns) {
    const m = pattern.exec(url.trim())
    if (m) {
      return toRepo(m)
    }
  }
  return null
}

type RawPr = {
  pullRequestId?: number
  title?: string
  isDraft?: boolean
  reviewers?: Array<{ vote?: number }>
}

/** `az repos pr list -o json` の 1 件を表示用にまとめる */
export const summarize = (repo: AdoRepo, raw: RawPr): PrSummary | null => {
  if (typeof raw.pullRequestId !== 'number') {
    return null
  }
  const votes = (raw.reviewers ?? []).map(r => r.vote ?? 0)

  return {
    id: raw.pullRequestId,
    title: raw.title ?? '',
    url: `${repo.orgUrl}/${encodeURIComponent(repo.project)}/_git/${encodeURIComponent(repo.repo)}/pullrequest/${raw.pullRequestId}`,
    isDraft: raw.isDraft === true,
    approved: votes.filter(vote => vote >= 5).length,
    reviewers: votes.length,
    isRejected: votes.includes(-10),
    isWaiting: votes.includes(-5),
  }
}
