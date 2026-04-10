# dangerous-command-guard.ps1
# PreToolUse hook - blocks or confirms dangerous Bash commands

# Ensure UTF-8 for Japanese text handling
[Console]::InputEncoding  = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$rawInput = @($input) -join ""

# Parse input JSON properly
try {
    $hookInput = $rawInput | ConvertFrom-Json
} catch {
    exit 0
}

$command = $hookInput.tool_input.command
if (-not $command) {
    exit 0
}

# ---- Patterns that are unconditionally blocked ----
$blockPatterns = @(
    # force-push variants (--force-with-lease is safer but still destructive on remotes)
    'git\s+push\s+(.*\s)?--force\b',
    'git\s+push\s+(.*\s)?-f\b',
    # destructive filesystem operations
    'rm\s+-[a-z]*r[a-z]*f[a-z]*\s+(\/|~|\$HOME|\.\.\/)',   # rm -rf targeting root/home/parent
    '>\s*/dev/sd[a-z]',
    '\bmkfs\b',
    '\bdd\b.+\bof=/dev/'
)

# ---- Patterns that require user confirmation ----
$askPatterns = @(
    # regular push (not force) - still ask for awareness
    'git\s+push\b(?!.*--dry-run)',
    # hard reset
    'git\s+reset\s+--hard\b',
    # clean (removes untracked files)
    'git\s+clean\s+-[a-z]*f',
    # rm -rf on relative/absolute paths (non-root, but still destructive)
    'rm\s+-[a-z]*r[a-z]*f[a-z]*\s+'
)

# ---- Check block patterns ----
foreach ($pattern in $blockPatterns) {
    if ($command -match $pattern) {
        $output = @{
            hookSpecificOutput = @{
                hookEventName          = "PreToolUse"
                permissionDecision     = "deny"
                permissionDecisionReason = "Dangerous command blocked by dangerous-command-guard: matched pattern [$pattern]"
            }
        } | ConvertTo-Json -Depth 10 -Compress
        Write-Output $output
        exit 0
    }
}

# ---- Check ask patterns ----
foreach ($pattern in $askPatterns) {
    if ($command -match $pattern) {
        $output = @{
            hookSpecificOutput = @{
                hookEventName          = "PreToolUse"
                permissionDecision     = "ask"
                permissionDecisionReason = "Command requires confirmation: [$command]. Run manually if preferred."
            }
        } | ConvertTo-Json -Depth 10 -Compress
        Write-Output $output
        exit 0
    }
}

exit 0
