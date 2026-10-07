# ---------------------------------------------------------------------------
# §8 PSReadLine - prediction and key bindings
# ---------------------------------------------------------------------------

# Interactive history search with delete support (Ctrl+r replacement)
# Usage: Ctrl+r to search, Del to delete selected entry and re-open
function Invoke-FzfHistory {
    if (-not (Test-Cmd fzf)) { Write-Warning 'History search needs fzf'; return }
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

        $key = $selected[0]
        $line = $selected[1]

        if ($key -eq 'del' -and $line) {
            $content = Get-Content $histFile
            $content | Where-Object { $_ -ne $line } | Set-Content $histFile
            # ループして再表示
        }
        elseif ($line) {
            [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt()
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert($line)
            return
        }
        else {
            return
        }
    }
}

# Search this profile's command catalog (fzf) and insert the chosen command
# name into the prompt without executing it, so arguments can follow.
# Combined entries like 'gp / gpf' or 'gsta/gstp/gstl' are split into
# separate candidates; argument placeholders like '<msg>' are stripped.
function Invoke-CommandPalette {
    if (-not (Test-Cmd fzf)) { Write-Warning 'Invoke-CommandPalette needs fzf'; return }

    $rows = foreach ($section in $script:ProfileHelp.Keys) {
        foreach ($item in $script:ProfileHelp[$section]) {
            $names = ($item.Cmd -split '[,/]') | ForEach-Object {
                ($_ -replace '[\[<].*', '').Trim()
            } | Where-Object { $_ }
            foreach ($name in $names) {
                "$name`t$($item.Desc)`t[$section]"
            }
        }
    }

    $sel = $rows | fzf --delimiter "`t" --with-nth 1, 2, 3 --prompt 'cmd> '
    if (-not $sel) { return }

    $cmdName = ($sel -split "`t")[0]
    [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt()
    [Microsoft.PowerShell.PSConsoleReadLine]::Insert("$cmdName ")
}

if ($host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) {
    Import-Module PSReadLine

    Set-PSReadLineOption -PredictionSource History
    Set-PSReadLineOption -PredictionViewStyle ListView
    Set-PSReadLineOption -EditMode Windows
    Set-PSReadLineOption -HistorySearchCursorMovesToEnd
    Set-PSReadLineOption -HistoryNoDuplicates
    Set-PSReadLineOption -MaximumHistoryCount 10000

    Set-PSReadLineKeyHandler -Key UpArrow   -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
    Set-PSReadLineKeyHandler -Key Ctrl+d    -Function DeleteCharOrExit
    Set-PSReadLineKeyHandler -Key Tab       -Function MenuComplete
    Set-PSReadLineKeyHandler -Key Alt+a     -Function SelectCommandArgument

    # Smart auto-closing brackets / quotes (adapted from the PSReadLine sample profile)
    Set-PSReadLineKeyHandler -Key '(', '{', '[' -BriefDescription InsertPairedBraces -ScriptBlock {
        param($key, $arg)
        $close = @{ '(' = ')'; '{' = '}'; '[' = ']' }[[string]$key.KeyChar]
        $line = $null; $cursor = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        $selStart = $null; $selLen = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::GetSelectionState([ref]$selStart, [ref]$selLen)
        if ($selLen -ne -1) {
            [Microsoft.PowerShell.PSConsoleReadLine]::Replace($selStart, $selLen, "$($key.KeyChar)" + $line.Substring($selStart, $selLen) + $close)
            [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($selStart + $selLen + 2)
        }
        else {
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert("$($key.KeyChar)$close")
            [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($cursor + 1)
        }
    }

    Set-PSReadLineKeyHandler -Key ')', ']', '}' -BriefDescription SmartCloseBraces -ScriptBlock {
        param($key, $arg)
        $line = $null; $cursor = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        if ($cursor -lt $line.Length -and $line[$cursor] -eq $key.KeyChar) {
            [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($cursor + 1)
        }
        else {
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert("$($key.KeyChar)")
        }
    }

    Set-PSReadLineKeyHandler -Key '"', "'" -BriefDescription SmartInsertQuote -ScriptBlock {
        param($key, $arg)
        $quote = $key.KeyChar
        $line = $null; $cursor = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        if ($cursor -lt $line.Length -and $line[$cursor] -eq $quote) {
            [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($cursor + 1)
        }
        else {
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert("$quote$quote")
            [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($cursor + 1)
        }
    }

    # fzf history search (registered last so PSFzf doesn't override Ctrl+r)
    Set-PSReadLineKeyHandler -Key Ctrl+r -ScriptBlock { Invoke-FzfHistory }
    # fzf command palette: search this profile's command catalog, insert the pick
    Set-PSReadLineKeyHandler -Key Ctrl+g -ScriptBlock { Invoke-CommandPalette }
}

