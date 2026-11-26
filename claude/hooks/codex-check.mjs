import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { decide as checkReply } from './reply-check.mjs'
import { decide as checkVerification } from './verify-check.mjs'
import { decide as checkJapanese, needsSkill } from './jp-deslop-check.mjs'

function parseJson(text) {
  try {
    return JSON.parse(text)
  } catch {
    return undefined
  }
}

function patchEdits(command) {
  const edits = []
  let edit
  for (const line of String(command ?? '').split('\n')) {
    const file = /^\*\*\* (?:Add|Update|Delete) File: (.+?)\r?$/.exec(line)
    if (file) {
      edit = { file_path: file[1], new_string: '' }
      edits.push(edit)
    } else if (edit && line.startsWith('+')) {
      edit.new_string += line.slice(1) + '\n'
    }
  }
  return edits
}

const skillRead = /\b(?:Get-Content|cat|type|sed|head|more|bat|rg)\b[^\n;]*?[\\/]((?:report-to-user|verify-before-done|jp-deslop))[\\/]SKILL\.md\b/ig

function toolUse(name, input) {
  return { type: 'tool_use', name, input }
}

function transcriptTools(item) {
  if (item.name === 'apply_patch') return [toolUse('Edit', {})]
  if (!['exec_command', 'shell', 'shell_command', 'exec'].includes(item.name)) return []

  const args = parseJson(item.arguments)
  const command = args?.cmd ?? args?.command ?? item.input
  if (typeof command !== 'string') return []
  // Codex loads file-based skills through shell reads.
  const skills = Array.from(command.matchAll(skillRead), match =>
    toolUse('Skill', { skill: match[1].toLowerCase() }))
  return [toolUse('Bash', { command }), ...skills]
}

function adaptTranscript(text) {
  if (text === undefined) return undefined
  // Codex rollouts use event_msg and response_item records. The wire format
  // for hook stdin is stable, but these transcript records may change.
  const entries = []
  for (const line of text.split('\n')) {
    const entry = parseJson(line)
    const item = entry?.payload
    if (entry?.type === 'event_msg' && item?.type === 'user_message') {
      entries.push({ type: 'user', message: { content: item.message || 'user_message' } })
    } else if (entry?.type === 'response_item' && ['function_call', 'custom_tool_call'].includes(item?.type)) {
      const content = transcriptTools(item)
      if (content.length) entries.push({ type: 'assistant', message: { content } })
    }
  }
  return entries.map(entry => JSON.stringify(entry)).join('\n')
}

export function decideCodex(check, input, transcriptText) {
  const transcript = adaptTranscript(transcriptText)
  if (input.hook_event_name === 'Stop') {
    if (check === 'reply-check') return checkReply(input, transcript)
    if (check === 'verify-check') {
      const result = checkVerification(input, transcript)
      if (result) result.reason = result.reason.replace('Skill ツールで ', '')
      return result
    }
  }
  if (input.hook_event_name === 'PreToolUse' && check === 'jp-deslop-check') {
    const requests = input.tool_name === 'apply_patch'
      ? patchEdits(input.tool_input?.command).map(tool_input => ({ ...input, tool_name: 'Edit', tool_input }))
      : [input]
    const request = requests.find(item => needsSkill(item.tool_name, item.tool_input))
    if (!request) return undefined
    const result = checkJapanese(request, transcript)
    if (result) {
      const output = result.hookSpecificOutput
      output.permissionDecisionReason = output.permissionDecisionReason.replace(
        'Skill ツールで jp-deslop を読み込んでください',
        'jp-deslop の SKILL.md を開いてください')
    }
    return result
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const input = JSON.parse(readFileSync(0, 'utf8'))
    let transcript
    try {
      if (input.transcript_path) transcript = readFileSync(input.transcript_path, 'utf8')
    } catch {
      // The transcript may not be available.
    }
    const result = decideCodex(process.argv[2], input, transcript)
    if (result) process.stdout.write(JSON.stringify(result))
  } catch {
    // Match the shared checks' fail-open behavior.
  }
}
