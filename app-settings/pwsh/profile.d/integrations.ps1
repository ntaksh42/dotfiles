# ---------------------------------------------------------------------------
# §5 Tool integrations (all guarded)
# ---------------------------------------------------------------------------

# Starship: cross-shell prompt (best with a Nerd Font for glyphs)
# --print-full-init avoids `starship init powershell` alone returning a lazy
# `Invoke-Expression (& starship ... | Out-String)` wrapper that re-invokes
# starship.exe in full on every dot-source, defeating Get-InitCache entirely.
# Kept synchronous here (unlike zoxide below, deferred to OnIdle): deferring
# it swaps $function:prompt only after the first prompt line is already on
# screen, which is visible as a one-time flash from the default prompt to
# starship's -- not worth the ~400-500ms saved (see zoxide's comment below).
if (Test-Cmd starship) {
    # 親プロセス経由で TERM=dumb が渡されると、starship が毎プロンプトでエラーを出す。
    if ($env:TERM -eq 'dumb') { Remove-Item Env:TERM }
    . (Get-InitCache 'starship' 'starship' { starship init powershell --print-full-init })
}

# bat: syntax-highlighted cat (bat outputs plain text when piped)
function cat {
    if (Test-Cmd bat) { bat @args } else { Get-Content @args }
}

# gsudo: sudo for Windows
function sudo {
    if (Test-Cmd gsudo) { gsudo @args }
    else { Write-Warning 'sudo needs gsudo' }
}

# Defer heavy modules (PSFzf + Terminal-Icons + zoxide, ~2s combined) to the
# first idle tick so the prompt appears immediately; they load once shortly
# after startup.
#
# zoxide: --hook pwd hooks Set-Location instead of prompt, so unlike
# starship above it has no visible effect when deferred -- pure startup-time
# win, and .NET's first-ever Process.Start/Task JIT cost in a fresh pwsh
# process (~100ms+ here) is worth moving off the interactive startup path.
$global:_dotfilesProfileDeferredDone = $false
if ($global:_dotfilesProfileIdleSubscriptionId) {
    Unregister-Event -SubscriptionId $global:_dotfilesProfileIdleSubscriptionId -ErrorAction Ignore
}
$null = Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -Action {
    if ($global:_dotfilesProfileDeferredDone) { return }
    $global:_dotfilesProfileDeferredDone = $true
    if (Get-Command zoxide -ErrorAction Ignore) {
        try { . (Get-InitCache 'zoxide' 'zoxide' { zoxide init --hook pwd powershell }) } catch {}
    }
    if (Get-Command gh -ErrorAction Ignore) {
        try { . (Get-InitCache 'gh' 'gh' { gh completion -s powershell }) } catch {}
    }
    if (Get-Module -ListAvailable -Name PSFzf) {
        try {
            Import-Module PSFzf
            Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordSetLocation 'Alt+c'
            # PSFzf grabs Ctrl+r on import; re-assert the custom fzf history handler.
            if (Get-Command fzf -ErrorAction Ignore) {
                Set-PSReadLineKeyHandler -Key Ctrl+r -ScriptBlock { Invoke-FzfHistory }
            }
        }
        catch {}
    }
    if (Get-Module -ListAvailable -Name Terminal-Icons) {
        Import-Module Terminal-Icons
    }
    # 遅延ロード中に初回プロンプトが消えることがあるため、完了後に再描画する。
    try { [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt() } catch {}
}

# Native tab completion (verified snippets), each guarded on command presence
Register-ArgumentCompleter -Native -CommandName dotnet -ScriptBlock {
    param($commandName, $wordToComplete, $cursorPosition)
    dotnet complete --position $cursorPosition "$wordToComplete" | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    }
}
$global:_dotfilesProfileIdleSubscriptionId = (Get-EventSubscriber -SourceIdentifier PowerShell.OnIdle |
    Sort-Object SubscriptionId -Descending |
    Select-Object -First 1).SubscriptionId

Register-ArgumentCompleter -Native -CommandName winget -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    [Console]::InputEncoding = [Console]::OutputEncoding = $OutputEncoding = [System.Text.Utf8Encoding]::new()
    $word = $wordToComplete.Replace('"', '""')
    $ast = $commandAst.ToString().Replace('"', '""')
    winget complete --word="$word" --commandline "$ast" --position $cursorPosition | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    }
}

# Reload PATH from Machine + User scope (use after installs; no shell restart)
function refreshenv {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = ($machine, $user | Where-Object { $_ }) -join ';'
    Write-Host 'PATH refreshed.' -ForegroundColor Green
}
Set-Alias Update-SessionPath refreshenv

# Clipboard shortcuts
function clip { $input | Set-Clipboard }
function paste { Get-Clipboard }

# Show public IP address
function myip { (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 5).ip }

# Show what's listening on a TCP port
function port {
    param([Parameter(Mandatory)][int]$Port)
    Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue |
    Select-Object LocalAddress, LocalPort, State, OwningProcess,
    @{ n = 'Process'; e = { (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName } }
}

# Kill the process(es) listening on a TCP port
function killport {
    param([Parameter(Mandatory)][int]$Port)
    $conns = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
    if (-not $conns) { Write-Warning "Nothing listening on port $Port"; return }
    $conns.OwningProcess | Sort-Object -Unique | ForEach-Object {
        Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
        Write-Host "Killed PID $_ on port $Port" -ForegroundColor Yellow
    }
}

