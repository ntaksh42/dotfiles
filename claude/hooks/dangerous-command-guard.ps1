<#
.HOOK
{
  "event": "PreToolUse",
  "matcher": "Bash"
}
#>
# dangerous-command-guard.ps1
# 危険なBashコマンドをブロックするhook（PreToolUse/Bash）

param()

$raw = $input | Out-String
try {
    $data = $raw | ConvertFrom-Json
} catch {
    exit 0
}

$cmd = $data.tool_input.command
if (-not $cmd) { exit 0 }

# [カテゴリ1] システムディレクトリへの再帰削除
$systemDestructive = @(
    # Unix系 rm -rf をシステム/ホームルートに
    'rm\s+-[a-zA-Z]*r[a-zA-Z]*\s+(/|~)\s*$'
    'rm\s+-[a-zA-Z]*r[a-zA-Z]*\s+(/|~)(\s|$)'
    # Windows: C:\ や C:\Windows 以下を再帰削除
    'Remove-Item.+(-Recurse|-r).+(-Force|-fo).+(C:\\\\(?:Windows|Program Files|Users\\\\[^\\\\]+\s*$))'
    'Remove-Item.+(-Force|-fo).+(-Recurse|-r).+(C:\\\\(?:Windows|Program Files|Users\\\\[^\\\\]+\s*$))'
    'rd\s+/s\s+/q\s+C:\\\\(?:Windows|Program Files|Users\\\\[^\\\\]+\s*$)'
    'del\s+/s\s+/q\s+C:\\\\(?:Windows|Program Files)'
    # ホームディレクトリ自体を削除
    'Remove-Item.+(-Recurse|-r).+\$(HOME|env:USERPROFILE)\s*$'
    'Remove-Item.+(-Recurse|-r).+\$(HOME|env:USERPROFILE)(\s|$)'
)

# [カテゴリ2] ディスクフォーマット
$formatCommands = @(
    'format\s+[a-zA-Z]:\s'
    'format\s+[a-zA-Z]:$'
    'diskpart'
)

# [カテゴリ3] ダウンロード&実行（curl/wget pipe to shell）
$downloadExecute = @(
    '(curl|wget).+\|\s*(bash|sh|zsh|fish|pwsh|powershell|iex|Invoke-Expression)'
    'Invoke-WebRequest.+\|\s*Invoke-Expression'
    'irm\s+.+\|\s*iex'
    '\(New-Object.+WebClient\).+DownloadString.+\|\s*iex'
)

# [カテゴリ4] PATH破壊（PATH変数を上書き）
$pathDestroy = @(
    '\[Environment\]::SetEnvironmentVariable\s*\(\s*[''"]PATH[''"]'
    '\$env:PATH\s*=\s*[''"][^''"]*[''"](?!.*\+)'   # PATH = "何か" (追記ではなく上書き)
)

$allPatterns = @(
    @{ category = "システムディレクトリ再帰削除"; patterns = $systemDestructive }
    @{ category = "ディスクフォーマット";         patterns = $formatCommands }
    @{ category = "ダウンロード&実行";            patterns = $downloadExecute }
    @{ category = "PATH変数の破壊的上書き";       patterns = $pathDestroy }
)

foreach ($group in $allPatterns) {
    foreach ($pattern in $group.patterns) {
        if ($cmd -match $pattern) {
            Write-Error @"
BLOCKED [$($group.category)]: 危険なコマンドパターンを検出しました。
コマンド: $cmd
パターン: $pattern
意図的な操作の場合はターミナルで直接実行してください。
"@
            exit 2
        }
    }
}

exit 0
