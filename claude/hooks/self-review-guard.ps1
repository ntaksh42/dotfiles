<#
.HOOK
{
  "event": "Stop"
}
#>
# self-review-guard.ps1
# コード変更（Edit/Write/MultiEdit/NotebookEdit）が発生したターンに限り、
# 出力を確定する前に self-review サブエージェントによるセルフレビューが
# 行われたかを transcript で検証する Stop フック。
# 未実施なら応答をブロックし、レビュー実施を促して続行させる。

$ErrorActionPreference = "Stop"

$raw = $input | Out-String
try {
    $data = $raw | ConvertFrom-Json
} catch {
    exit 0
}

$transcript = $data.transcript_path
if (-not $transcript -or -not (Test-Path $transcript)) { exit 0 }

# transcript(JSONL) を1行ずつパース
$entries = New-Object System.Collections.Generic.List[object]
foreach ($line in (Get-Content -Path $transcript -Encoding UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $entries.Add(($line | ConvertFrom-Json)) } catch {}
}
if ($entries.Count -eq 0) { exit 0 }

# 「現在のターン」の開始位置を特定する。
# 末尾から遡り、最後の本物のユーザー発話（tool_result でない user メッセージ）を探す。
$startIndex = 0
for ($i = $entries.Count - 1; $i -ge 0; $i--) {
    $e = $entries[$i]
    if ($e.isSidechain) { continue }   # サブエージェント内部の発話は無視
    if ($e.type -ne "user") { continue }
    $content = $e.message.content
    $isToolResult = $false
    if ($content -is [System.Array]) {
        foreach ($block in $content) {
            if ($block.type -eq "tool_result") { $isToolResult = $true; break }
        }
    }
    if (-not $isToolResult) { $startIndex = $i; break }
}

# 現在のターン内の assistant の tool_use を走査
$editTools   = @("Edit", "Write", "MultiEdit", "NotebookEdit")
$agentTools  = @("Task", "Agent")   # サブエージェント起動ツール（環境差異に対応）
$codeChanged = $false
$reviewDone  = $false
for ($i = $startIndex; $i -lt $entries.Count; $i++) {
    $e = $entries[$i]
    if ($e.isSidechain) { continue }   # サブエージェント内部の tool_use は数えない
    if ($e.type -ne "assistant") { continue }
    $content = $e.message.content
    if ($content -isnot [System.Array]) { continue }
    foreach ($block in $content) {
        if ($block.type -ne "tool_use") { continue }
        if ($editTools -contains $block.name) { $codeChanged = $true }
        # subagent_type は完全一致に頼らず緩く判定（プラグイン名前空間付き等に対応）。
        # レビュー実施済みなのにブロックが解けない事故を避ける。
        if (($agentTools -contains $block.name) -and ($block.input.subagent_type -like "*self-review*")) {
            $reviewDone = $true
        }
    }
}

if ($codeChanged -and -not $reviewDone) {
    $reason = "このターンでコード変更（Edit/Write 等）を行いました。" +
              "回答を確定する前に、Task ツールで subagent_type=self-review のサブエージェントを起動し、" +
              "変更内容のセルフレビュー（バグ・退行・要件適合・簡素化の観点）を実施してください。" +
              "レビュー結果を踏まえ、必要なら修正してから完了してください。"
    $payload = [PSCustomObject]@{ decision = "block"; reason = $reason } | ConvertTo-Json -Compress
    Write-Output $payload
}

exit 0
