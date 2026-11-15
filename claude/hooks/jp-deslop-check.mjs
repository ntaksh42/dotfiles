// PreToolUse hook: 日本語の文章を書くツール呼び出しを、このセッションで jp-deslop を読み込むまで止める。
// plugin や mod に依存しない単体スクリプト。~/.claude/settings.json の PreToolUse に登録して使う（tools/Install-JpDeslopHook.ps1）。
// 対象は jp-deslop の description と同じ範囲に絞る:
//   - Write / Edit / MultiEdit で、文書の拡張子（.md など）のファイルに仮名を含む文章を書く
//   - Bash / PowerShell で、仮名を含む PR・Issue・Work Item の本文や、複数行のコミットメッセージを書く
// コードのファイル（コメント）、1 行のコミットメッセージ、HTML（report-to-user のシート）は対象にしない。
// 一度読み込めばセッションの終わりまで通す。サブエージェントの呼び出しは止めない。
// 環境変数 JP_DESLOP_CHECK=off で無効にできる。失敗したときは何もしない（hook で作業を止めない）。
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const SKILL_NAME = 'jp-deslop'
const KANA = /[ぁ-ゖァ-ヺ]/
const DOC_EXT = /\.(md|mdx|markdown|txt|rst|adoc)$/i
// 本文を書く CLI。gh の pr/issue の create・edit・comment・review、az の repos pr と boards work-item
const BODY_CLI = /\bgh\s+(pr|issue)\s+(create|edit|comment|review)\b|\baz\s+(repos\s+pr|boards\s+work-item)\b/

export function hasKana(text) {
  return KANA.test(String(text ?? ''))
}

// git commit のメッセージが複数行か（-m を 2 つ以上、またはメッセージに改行を含む）
export function isMultilineCommit(command) {
  const c = String(command ?? '')
  if (!/\bgit\s+commit\b/.test(c)) return false
  const m = c.match(/(^|\s)(-m|--message)(\s|=)/g)
  if (m && m.length >= 2) return true
  return /\n/.test(c.slice(c.search(/\bgit\s+commit\b/)))
}

// このツール呼び出しが jp-deslop の対象か
export function needsSkill(toolName, toolInput) {
  const input = toolInput ?? {}
  const path = String(input.file_path ?? '')
  switch (toolName) {
    case 'Write':
      return DOC_EXT.test(path) && hasKana(input.content)
    case 'Edit':
      return DOC_EXT.test(path) && hasKana(input.new_string)
    case 'MultiEdit':
      return DOC_EXT.test(path) && Array.isArray(input.edits) && input.edits.some(e => hasKana(e?.new_string))
    case 'Bash':
    case 'PowerShell': {
      const command = String(input.command ?? '')
      if (!hasKana(command)) return false
      return BODY_CLI.test(command) || isMultilineCommit(command)
    }
    default:
      return false
  }
}

// このセッションで jp-deslop を読み込んだか（Skill ツールの呼び出しか、/jp-deslop の入力）
export function loadedSkill(transcriptLines) {
  for (const l of transcriptLines) {
    if (!l.includes(SKILL_NAME)) continue
    if (l.includes(`<command-name>/${SKILL_NAME}</command-name>`)) return true
    let e
    try {
      e = JSON.parse(l)
    } catch {
      continue
    }
    const content = e?.message?.content
    if (e?.type === 'assistant' && Array.isArray(content) &&
      content.some(b => b?.type === 'tool_use' && b.name === 'Skill' && String(b.input?.skill ?? '').endsWith(SKILL_NAME))) {
      return true
    }
  }
  return false
}

export function decide(input, transcriptText) {
  if (process.env.JP_DESLOP_CHECK === 'off') return undefined
  if (input.agent_id !== undefined) return undefined
  if (!needsSkill(input.tool_name, input.tool_input)) return undefined
  if (transcriptText === undefined) return undefined
  if (loadedSkill(transcriptText.split('\n'))) return undefined
  return {
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason:
        `日本語の文章を書く前に、Skill ツールで ${SKILL_NAME} を読み込んでください。` +
        '読み込んだら、その「書くとき」に沿って文章を見直し、同じ操作をもう一度実行します。このセッションでは以後止めません。',
    },
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  let raw = ''
  process.stdin.setEncoding('utf8')
  process.stdin.on('data', chunk => (raw += chunk))
  process.stdin.on('end', () => {
    try {
      const input = JSON.parse(raw || '{}')
      let transcript
      try {
        transcript = input.transcript_path ? readFileSync(input.transcript_path, 'utf8') : undefined
      } catch {
        transcript = undefined
      }
      const result = decide(input, transcript)
      if (result) process.stdout.write(JSON.stringify(result))
    } catch {
      // 失敗しても何もしない
    }
  })
}
