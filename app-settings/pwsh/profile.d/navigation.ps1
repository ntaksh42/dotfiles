# ---------------------------------------------------------------------------
# §2 Navigation & file operations
# ---------------------------------------------------------------------------

# Create directory and move into it
function mkcd {
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path
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
        }
        else { $_.Length }
        [PSCustomObject]@{ Name = $_.Name; Size = [math]::Round($bytes / 1MB, 2) }
    } | Sort-Object Size -Descending | Format-Table -AutoSize
}

# Go up directories
function .. { Set-Location .. }
function ... { Set-Location ..\.. }
function .... { Set-Location ..\..\.. }

# Go up N directory levels (default 1)
function up {
    param([int]$Levels = 1)
    if ($Levels -lt 1) { $Levels = 1 }
    Set-Location (('..\' * $Levels).TrimEnd('\'))
}

# Jump to source\repos
function repos { Set-Location (Join-Path $env:USERPROFILE 'source\repos') }

# Listing: defer the eza lookup until the first listing command is used.
function ll {
    if (Test-Cmd eza) { eza -lh --git --icons --group-directories-first @args }
    else { Get-ChildItem @args }
}
function la {
    if (Test-Cmd eza) { eza -lah --git --icons --group-directories-first @args }
    else { Get-ChildItem -Force @args }
}
function lt {
    if (Test-Cmd eza) { eza --tree --level=2 --icons @args }
    else { Get-ChildItem -Recurse -Depth 1 @args }
}

# Fuzzy find a file and open it (fd + fzf)
function ff {
    if (-not (Test-Cmd fzf)) { Write-Warning 'ff needs fzf'; return }
    $sel = if (Test-Cmd fd) { & fd --type f | fzf }
    else { Get-ChildItem -Recurse -File | Select-Object -ExpandProperty FullName | fzf }
    if ($sel) { Invoke-Item $sel }
}

# Fuzzy find a directory and cd into it (fd + fzf)
function fcd {
    if (-not (Test-Cmd fzf)) { Write-Warning 'fcd needs fzf'; return }
    $sel = if (Test-Cmd fd) { & fd --type d | fzf }
    else { Get-ChildItem -Recurse -Directory | Select-Object -ExpandProperty FullName | fzf }
    if ($sel) { Set-Location $sel }
}

# touch: create file or update timestamp
function touch {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path $Path) { (Get-Item $Path).LastWriteTime = Get-Date }
    else { New-Item -ItemType File -Path $Path | Out-Null }
}

# Copy a file to <name>.bak-YYYYMMDD-HHmmss alongside it (snapshot before edits)
function backup-file {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Write-Warning "Not a file: $Path"; return }
    $item = Get-Item -LiteralPath $Path
    $dest = Join-Path $item.DirectoryName ('{0}.bak-{1}' -f $item.Name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item -LiteralPath $item.FullName -Destination $dest
    Write-Host "Backed up -> $dest" -ForegroundColor Green
}

# Reload this profile
function reload { . $script:DotfilesProfilePath }

# Measure this profile in clean child PowerShell processes. Tool init caches are
# intentionally preserved so the result represents normal, warm startup.
function Measure-ProfileStartup {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 20)][int]$Samples = 5,
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string]$Path = $script:DotfilesProfilePath
    )

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $pwsh = (Get-Process -Id $PID).Path
    $measureCommand = @'
$sw = [Diagnostics.Stopwatch]::StartNew()
. $env:DOTFILES_PROFILE_MEASURE_PATH
$sw.Stop()
'__PROFILE_MS__={0}' -f $sw.Elapsed.TotalMilliseconds.ToString([Globalization.CultureInfo]::InvariantCulture)
'@

    $values = foreach ($sample in 1..$Samples) {
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $pwsh
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.Environment['DOTFILES_PROFILE_MEASURE_PATH'] = $resolved
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $measureCommand)) {
            [void]$psi.ArgumentList.Add($argument)
        }

        $process = [Diagnostics.Process]::Start($psi)
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0 -or $stdout -notmatch '__PROFILE_MS__=([0-9.]+)') {
            throw "Profile measurement failed (exit $($process.ExitCode)): $stderr"
        }
        [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
    }

    $stats = $values | Measure-Object -Minimum -Maximum -Average
    [PSCustomObject]@{
        Samples   = $Samples
        AverageMs = [math]::Round($stats.Average, 2)
        MinimumMs = [math]::Round($stats.Minimum, 2)
        MaximumMs = [math]::Round($stats.Maximum, 2)
    }
}

# Edit this profile (VS Code if present, else Notepad)
function Edit-Profile {
    if (Test-Cmd code) { code $script:DotfilesProfilePath } else { notepad $script:DotfilesProfilePath }
}
Set-Alias profile Edit-Profile

