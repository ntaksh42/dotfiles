# Microsoft.PowerShell_profile.ps1 - PowerShell 7

# ---------------------------------------------------------------------------
# Aliases
# ---------------------------------------------------------------------------
Set-Alias cc    claude
Set-Alias cop   copilot
Set-Alias g     git
Set-Alias which Get-Command

# ---------------------------------------------------------------------------
# Utility Functions
# ---------------------------------------------------------------------------

# Create directory and move into it
function mkcd {
    param(
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$Path
    )
    New-Item -ItemType Directory -Force -Path $Path -ErrorAction Stop | Out-Null
    Set-Location $Path -ErrorAction Stop
}

# Display file/directory size
function size {
    param([string]$Path = ".")
    Get-ChildItem $Path |
        ForEach-Object {
            $bytes = if ($_.PSIsContainer) {
                (Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue |
                 Measure-Object -Property Length -Sum).Sum ?? 0
            } else { $_.Length }
            [PSCustomObject]@{ Name = $_.Name; Size = [math]::Round($bytes / 1MB, 2) }
        } | Sort-Object Size -Descending | Format-Table -AutoSize
}

# Interactive history search with delete support (Ctrl+r replacement)
# Usage: Ctrl+r to search, Del to delete selected entry and re-open
function Invoke-FzfHistory {
    $histFile = Join-Path $env:APPDATA 'Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt'
    if (-not (Test-Path $histFile)) { return }

    while ($true) {
        $selected = Get-Content $histFile |
            Where-Object { $_ -ne '' } |
            Select-Object -Unique |
            & fzf --scheme=history --no-sort --tac `
                  --prompt 'history> ' `
                  --expect 'del'

        # $selected[0] = 押されたキー、$selected[1] = 選択した行
        if (-not $selected) { return }

        $key  = $selected[0]
        $line = $selected[1]

        if ($key -eq 'del' -and $line) {
            $content = Get-Content $histFile
            $content | Where-Object { $_ -ne $line } | Set-Content $histFile
            # ループして再表示
        } elseif ($line) {
            [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt()
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert($line)
            return
        } else {
            return
        }
    }
}

# Show git status in short format
function gs { git status -sb @args }

# Show git log with graph
function gl { git log --oneline --graph --decorate -20 @args }

# Undo last git commit (return to staging)
function git-undo {
    git reset --soft HEAD~1
}

# ---------------------------------------------------------------------------
# PSReadLine - prediction and key bindings
# ---------------------------------------------------------------------------
if ($host.Name -eq 'ConsoleHost') {
    Import-Module PSReadLine

    Set-PSReadLineOption -PredictionSource History
    Set-PSReadLineOption -PredictionViewStyle ListView
    Set-PSReadLineOption -EditMode Windows
    Set-PSReadLineOption -HistorySearchCursorMovesToEnd

    Set-PSReadLineKeyHandler -Key UpArrow   -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
    Set-PSReadLineKeyHandler -Key Ctrl+d    -Function DeleteCharOrExit

    # fzf history search (PSFzf に上書きされないよう末尾で登録)
    Set-PSReadLineKeyHandler -Key Ctrl+r -ScriptBlock { Invoke-FzfHistory }
}
