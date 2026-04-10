# session-start.ps1
# Claude Code SessionStart Hook
# Runs once when a new session starts. Checks environment and injects context.

[Console]::InputEncoding  = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$rawInput = @($input) -join ""

try {
    $hookInput = $rawInput | ConvertFrom-Json
} catch {
    exit 0
}

$cwd = $hookInput.cwd ?? (Get-Location).Path

# ---- Collect environment warnings ----
$warnings = @()

# Check for required tools
$requiredTools = @("git", "gh")
foreach ($tool in $requiredTools) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        $warnings += "WARNING: '$tool' not found in PATH"
    }
}

# Check for .env files that should NOT be committed
if ($cwd -and (Test-Path $cwd)) {
    $envFiles = Get-ChildItem -Path $cwd -Filter ".env" -Recurse -Depth 2 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\node_modules\\' }
    if ($envFiles) {
        $warnings += "NOTE: .env file(s) detected - never commit these to git"
    }
}

# Check for git repo and show branch
$repoInfo = ""
if ($cwd -and (Test-Path (Join-Path $cwd ".git"))) {
    Push-Location $cwd
    $branch = git branch --show-current 2>$null
    $remoteUrl = git remote get-url origin 2>$null
    Pop-Location
    if ($branch) {
        $repoInfo = "Git branch: $branch"
        if ($remoteUrl) {
            $repoInfo += " | Remote: $remoteUrl"
        }
    }
}

# ---- Build context message ----
$lines = @()
$lines += "=== Claude Code Session Started ==="
if ($repoInfo) { $lines += $repoInfo }
foreach ($w in $warnings) { $lines += $w }
$lines += "Language: Japanese | Model: $($hookInput.model ?? 'default')"

$contextText = $lines -join "`n"

# Output additionalContext to inject info into Claude's context window
$output = @{
    additionalContext = $contextText
} | ConvertTo-Json -Depth 5 -Compress

Write-Output $output
exit 0
