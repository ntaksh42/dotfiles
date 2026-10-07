# ---------------------------------------------------------------------------
# §4 Visual Studio / build (C#/C++)
# ---------------------------------------------------------------------------

# Locate latest VS install path via vswhere
function Get-VsInstallPath {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { return $null }
    (& $vswhere -latest -property installationPath 2>$null)
}

# Resolve devenv.exe of the latest VS
function Get-DevEnvPath {
    $vsPath = Get-VsInstallPath
    if (-not $vsPath) { return $null }
    $devenv = Join-Path $vsPath 'Common7\IDE\devenv.exe'
    if (Test-Path $devenv) { $devenv } else { $null }
}

# Enter VS Developer environment in the CURRENT session (on demand; slow)
function vsdev {
    $vsPath = Get-VsInstallPath
    if (-not $vsPath) { Write-Warning 'Visual Studio not found (vswhere)'; return }
    $dll = Join-Path $vsPath 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll'
    if (-not (Test-Path $dll)) { Write-Warning "DevShell module not found: $dll"; return }
    try {
        Import-Module $dll
        Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'
    }
    catch {
        Write-Warning "vsdev failed: $($_.Exception.Message)"
    }
}

# Find nearest *.sln walking up from current directory
function Find-Sln {
    $dir = (Get-Location).Path
    while ($dir) {
        $slns = Get-ChildItem -Path $dir -Filter *.sln -File -ErrorAction SilentlyContinue
        if ($slns) { return $slns }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return @()
}

# Open nearest solution in Visual Studio
function sln {
    $devenv = Get-DevEnvPath
    if (-not $devenv) { Write-Warning 'Visual Studio (devenv) not found'; return }
    $slns = Find-Sln
    if (-not $slns) { Write-Warning 'No .sln found upward from current directory'; return }
    $target = if ($slns.Count -eq 1) { $slns[0].FullName }
    elseif (Test-Cmd fzf) { $slns.FullName | fzf }
    else { $slns[0].FullName }
    if ($target) { Start-Process $devenv $target }
}

# Open a path (default: current dir) in Visual Studio
function vs {
    param([string]$Path = ".")
    $devenv = Get-DevEnvPath
    if (-not $devenv) { Write-Warning 'Visual Studio (devenv) not found'; return }
    Start-Process $devenv (Resolve-Path $Path).Path
}

# dotnet / msbuild shortcuts
function db { dotnet build @args }
function dr { dotnet run @args }
function dt { dotnet test @args }
function msb { msbuild @args }

