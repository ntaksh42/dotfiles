# Merge the managed keys into an existing Claude Code settings.json.
param(
    [string]$ClaudeDir = (Join-Path $env:USERPROFILE '.claude'),
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$ClaudeDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ClaudeDir)
$source = Join-Path $PSScriptRoot '..\claude\settings.template.json'
$remote = 'https://raw.githubusercontent.com/ntaksh42/dotfiles/main/claude/settings.template.json'
$target = Join-Path $ClaudeDir 'settings.json'
$exists = Test-Path -LiteralPath $target -PathType Leaf

$jsonArgs = @{ AsHashtable = $true; NoEnumerate = $true }
if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
    $jsonArgs.DateKind = 'String'
}
$templateText = if (Test-Path -LiteralPath $source -PathType Leaf) {
    [IO.File]::ReadAllText($source)
} else {
    (Invoke-WebRequest -Uri $remote -UseBasicParsing).Content
}
$template = ConvertFrom-Json @jsonArgs -InputObject $templateText
if ($exists) {
    $originalBytes = [IO.File]::ReadAllBytes($target)
    $hasBom = $originalBytes.Length -ge 3 -and $originalBytes[0] -eq 239 -and
        $originalBytes[1] -eq 187 -and $originalBytes[2] -eq 191
    $offset = if ($hasBom) { 3 } else { 0 }
    $original = [Text.Encoding]::UTF8.GetString($originalBytes, $offset, $originalBytes.Length - $offset)
    $settings = ConvertFrom-Json @jsonArgs -InputObject $original
} else {
    $settings = [ordered]@{}
}
if ($settings -isnot [System.Collections.IDictionary]) {
    throw "Expected a JSON object in $target"
}
if ($template -isnot [System.Collections.IDictionary] -or
    $template.outputStyle -isnot [string] -or $null -eq $template.skillListingBudgetFraction -or
    $template.skillOverrides -isnot [System.Collections.IDictionary] -or
    $template.autoMode.environment -isnot [array]) {
    throw 'The Claude settings template is missing managed settings.'
}
foreach ($key in 'skillOverrides', 'autoMode') {
    if ($null -eq $settings[$key]) { $settings[$key] = [ordered]@{} }
    elseif ($settings[$key] -isnot [System.Collections.IDictionary]) {
        throw "Expected a JSON object for $key in $target"
    }
}
if ($null -ne $settings.autoMode.environment -and $settings.autoMode.environment -isnot [array]) {
    throw "Expected a JSON array for autoMode.environment in $target"
}

$changes = [Collections.Generic.List[string]]::new()
function Set-ManagedSetting {
    param($Object, [string]$Key, $Value, [string]$Label = $Key)
    $after = ConvertTo-Json -InputObject $Value -Depth 100 -Compress
    $before = if ($Object.Contains($Key)) {
        ConvertTo-Json -InputObject $Object[$Key] -Depth 100 -Compress
    } else {
        '(unset)'
    }
    if ($before -ceq $after) { return }
    $Object[$Key] = $Value
    $changes.Add("- ${Label}: $before")
    $changes.Add("+ ${Label}: $after")
}

Set-ManagedSetting $settings outputStyle $template.outputStyle
Set-ManagedSetting $settings skillListingBudgetFraction $template.skillListingBudgetFraction
foreach ($key in $template.skillOverrides.psbase.Keys) {
    Set-ManagedSetting $settings.skillOverrides $key $template.skillOverrides[$key] "skillOverrides.$key"
}
$environment = @('$defaults')
foreach ($entry in $settings.autoMode.environment) {
    if ($entry -isnot [string] -or $entry -cne '$defaults') { $environment += ,$entry }
}
foreach ($entry in $template.autoMode.environment) {
    if ($environment -cnotcontains $entry) { $environment += $entry }
}
Set-ManagedSetting $settings.autoMode environment $environment 'autoMode.environment'

if ($changes.Count -eq 0) { return }
if ($Check) {
    $changes
    return
}

$json = ConvertTo-Json -InputObject $settings -Depth 100 -WarningAction Stop
$newline = [regex]::Match([string]$original, '\r\n|\n|\r').Value
if (-not $newline) { $newline = [Environment]::NewLine }
$trailing = if ($exists) { [regex]::Match($original, '(?:\r\n|\n|\r)+\z').Value } else { $newline }
$json = ($json -replace '\r\n|\n|\r', $newline) + $trailing
New-Item -ItemType Directory -Path $ClaudeDir -Force | Out-Null
$temp = "$target.$([guid]::NewGuid().ToString('N')).tmp"
try {
    [IO.File]::WriteAllText($temp, $json, [Text.UTF8Encoding]::new([bool]$hasBom))
    if ($exists) {
        if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($target)) -cne [Convert]::ToBase64String($originalBytes)) {
            throw "Settings changed during the merge: $target"
        }
        $backup = "$target.backup.$(Get-Date -Format 'yyyyMMdd-HHmmss.fffffff')"
        [IO.File]::Replace($temp, $target, $backup)
        Write-Host "Backed up: $backup"
    } else {
        [IO.File]::Move($temp, $target)
    }
    Write-Host "Updated: $target"
}
finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp }
}
