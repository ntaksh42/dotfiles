# Claude Code dotfiles installer for Windows
# Use -Check to preview permission changes, or -PermissionsOnly to apply only those changes.

param(
    [switch]$Check,
    [switch]$PermissionsOnly,
    [string]$ClaudeDir = $(if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' })
)

$ErrorActionPreference = 'Stop'

function Read-SettingsObject([string]$Json, [string]$Path) {
    $options = @{ InputObject = $Json; ErrorAction = 'Stop' }
    if ($PSVersionTable.PSVersion -ge [version]'7.5') { $options.DateKind = 'String' }
    if (-not $Json.TrimStart().StartsWith('{')) { throw "Expected a JSON object in $Path" }
    ConvertFrom-Json @options
}

function Merge-Settings($Current, $Template) {
    foreach ($property in $Template.PSObject.Properties) {
        $name = $property.Name
        $value = $property.Value
        $existing = $Current.PSObject.Properties[$name]
        if ($null -eq $existing) {
            $Current | Add-Member -NotePropertyName $name -NotePropertyValue $value
        }
        elseif ($existing.Value -is [pscustomobject] -and $value -is [pscustomobject]) {
            Merge-Settings $existing.Value $value
        }
        else {
            $existing.Value = $value
        }
    }
}

function Show-PermissionChanges($Current, $Target) {
    $changed = $false
    if ($Current.defaultMode -cne $Target.defaultMode) {
        Write-Host "  permissions.defaultMode: [$($Current.defaultMode)] -> [$($Target.defaultMode)]"
        $changed = $true
    }
    foreach ($name in 'allow', 'ask', 'deny') {
        $before = @($Current.$name | Where-Object { $null -ne $_ })
        $after = @($Target.$name)
        if ((ConvertTo-Json -InputObject $Current.$name -Compress) -ceq (ConvertTo-Json -InputObject $Target.$name -Compress)) { continue }
        $changed = $true
        $removed = @($before | Where-Object { $_ -cnotin $after })
        $added = @($after | Where-Object { $_ -cnotin $before })
        Write-Host "  permissions.${name}:"
        $removed | ForEach-Object { Write-Host "    - $_" }
        $added | ForEach-Object { Write-Host "    + $_" }
        if ($removed.Count + $added.Count -eq 0) { Write-Host '    List representation or order changes.' }
    }
    if (-not $changed) { Write-Host '  Permissions are up to date.' }
}

$settingsFile = Join-Path $ClaudeDir 'settings.json'
$templateFile = Join-Path $PSScriptRoot 'settings.template.json'
$template = Read-SettingsObject ([IO.File]::ReadAllText($templateFile)) $templateFile
$existingJson = if (Test-Path -LiteralPath $settingsFile) { [IO.File]::ReadAllText($settingsFile) }
$settings = if ($null -eq $existingJson) { [pscustomobject]@{} } else { Read-SettingsObject $existingJson $settingsFile }
if ($null -ne $settings.permissions -and $settings.permissions -isnot [pscustomobject]) {
    throw "Expected a JSON object for permissions in $settingsFile"
}

Write-Host "Claude Code permissions in $settingsFile"
Show-PermissionChanges $settings.permissions $template.permissions
if ($Check) { return }

if ($PermissionsOnly) {
    $template = [pscustomobject]@{ permissions = $template.permissions }
}
else {
    $template.extraKnownMarketplaces.'dotfiles-mods'.source.path = Join-Path $env:LOCALAPPDATA 'dotfiles\marketplaces\dotfiles-mods'
}

$previous = ConvertTo-Json -InputObject $settings -Depth 100 -Compress -WarningAction Stop
Merge-Settings $settings $template
$updated = ConvertTo-Json -InputObject $settings -Depth 100 -Compress -WarningAction Stop
if ($previous -cne $updated) {
    New-Item -ItemType Directory -Path $ClaudeDir -Force | Out-Null
    $id = [guid]::NewGuid().ToString('N')
    $stagedFile = "$settingsFile.tmp.$id"
    try {
        $prettyJson = ConvertTo-Json -InputObject $settings -Depth 100 -WarningAction Stop
        [IO.File]::WriteAllText($stagedFile, $prettyJson + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        if ($null -eq $existingJson) {
            [IO.File]::Move($stagedFile, $settingsFile)
        }
        else {
            if ([IO.File]::ReadAllText($settingsFile) -cne $existingJson) {
                throw "Settings changed while preparing the update. Run the installer again: $settingsFile"
            }
            $backupFile = "$settingsFile.backup.$id"
            [IO.File]::Replace($stagedFile, $settingsFile, $backupFile)
            Write-Host "Backed up: $backupFile"
        }
        Write-Host "Updated: $settingsFile"
    }
    finally {
        if (Test-Path -LiteralPath $stagedFile) { Remove-Item -LiteralPath $stagedFile }
    }
}

if ($PermissionsOnly) { return }

& (Join-Path $PSScriptRoot '..\tools\Install-AgentInstructions.ps1') -ClaudeDir $ClaudeDir

$envName = 'ENABLE_TOOL_SEARCH'
if (-not [Environment]::GetEnvironmentVariable($envName, 'User')) {
    [Environment]::SetEnvironmentVariable($envName, 'true', 'User')
    $env:ENABLE_TOOL_SEARCH = 'true'
    Write-Host "$envName configured at user scope."
}

Write-Host 'Run Install-DevTools to install the skills, hooks, and the mods plugin.'
Write-Host 'Restart Claude Code for settings changes to take effect.'
