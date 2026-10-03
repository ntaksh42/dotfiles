import { describe, expect, test } from 'claude-code/testing'

import { parseAdoRemote, summarize } from './ado'

const REPO = { orgUrl: 'https://dev.azure.com/contoso', project: 'My Project', repo: 'web' }

describe('parseAdoRemote', () => {
  test('dev.azure.com の HTTPS（ユーザー名付き、URL エンコード）', () => {
    expect(parseAdoRemote('https://contoso@dev.azure.com/contoso/My%20Project/_git/web')).toEqual(REPO)
  })

  test('visualstudio.com の HTTPS（DefaultCollection 付き）', () => {
    expect(parseAdoRemote('https://contoso.visualstudio.com/DefaultCollection/My%20Project/_git/web')).toEqual(REPO)
  })

  test('SSH', () => {
    expect(parseAdoRemote('git@ssh.dev.azure.com:v3/contoso/My%20Project/web')).toEqual(REPO)
  })

  test('GitHub などは null', () => {
    expect(parseAdoRemote('https://github.com/contoso/web.git')).toBeNull()
    expect(parseAdoRemote('')).toBeNull()
  })
})

describe('summarize', () => {
  test('リンクと投票の集計', () => {
    const pr = summarize(REPO, {
      pullRequestId: 68,
      title: 'Large test PR',
      isDraft: false,
      reviewers: [{ vote: 10 }, { vote: 5 }, { vote: 0 }, { vote: -5 }],
    })
    expect(pr).toEqual({
      id: 68,
      title: 'Large test PR',
      url: 'https://dev.azure.com/contoso/My%20Project/_git/web/pullrequest/68',
      isDraft: false,
      approved: 2,
      reviewers: 4,
      isRejected: false,
      isWaiting: true,
    })
  })

  test('id の無いものは null', () => {
    expect(summarize(REPO, {})).toBeNull()
  })
})
