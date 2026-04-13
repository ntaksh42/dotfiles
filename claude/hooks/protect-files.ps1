<#
.HOOK
{
  "event": "PreToolUse",
  "matcher": "Edit|Write"
}
#>
# protect-files.ps1
# Edit/Writeによる機密ファイルへの書き込みをブロックするhook

param()

$raw = $input | Out-String
try {
    $data = $raw | ConvertFrom-Json
} catch {
    exit 0
}

$path = $data.tool_input.file_path
if (-not $path) { exit 0 }

# 保護対象パターン（正規表現）
$protectedPatterns = @(
    '\.env$'
    '\.env\.'
    'credentials\.json'
    'secrets\.json'
    '\.key$'
    '\.pem$'
    '\.pfx$'
    '\.p12$'
    'appsettings\.(Development|Production)\.json$'
)

foreach ($pattern in $protectedPatterns) {
    if ($path -match $pattern) {
        Write-Error "BLOCKED: '$path' is a protected file (matched: $pattern). Edit manually if needed."
        exit 2
    }
}

exit 0
