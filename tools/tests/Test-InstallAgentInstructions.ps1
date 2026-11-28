# Run with: pwsh -NoProfile -File tools/tests/Test-InstallAgentInstructions.ps1
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$installer = Join-Path $repo 'tools\Install-AgentInstructions.ps1'
$claudeInstaller = Join-Path $repo 'claude\install.ps1'
$source = Join-Path $repo 'claude\CLAUDE.global.md'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('dotfiles-instructions-test-' + [guid]::NewGuid().ToString('N'))
. (Join-Path $repo 'app-settings\pwsh\tests\TestHarness.ps1')

try {
    $claudeDir = Join-Path $scratch 'Claude profile'
    $codexDir = Join-Path $scratch 'Codex profile'
    $claudeFile = Join-Path $claudeDir 'CLAUDE.md'
    $codexFile = Join-Path $codexDir 'AGENTS.md'
    $expectedHash = (Get-FileHash -LiteralPath $source).Hash

    Test-Case 'Fresh install copies identical rules to both agents' {
        & $installer -ClaudeDir $claudeDir -CodexDir $codexDir 6>$null
        (Get-FileHash -LiteralPath $claudeFile).Hash -eq $expectedHash -and
        (Get-FileHash -LiteralPath $codexFile).Hash -eq $expectedHash
    }

    Test-Case 'Changed instructions are backed up and unrelated configuration is preserved' {
        Set-Content -LiteralPath $claudeFile -Value 'original Claude rules' -NoNewline
        Set-Content -LiteralPath $codexFile -Value 'original Codex rules' -NoNewline
        $configFile = Join-Path $codexDir 'config.toml'
        Set-Content -LiteralPath $configFile -Value 'model = "keep-me"' -NoNewline
        & $installer -ClaudeDir $claudeDir -CodexDir $codexDir 6>$null
        $claudeBackups = @(Get-ChildItem -LiteralPath $claudeDir -Filter 'CLAUDE.md.backup.*')
        $codexBackups = @(Get-ChildItem -LiteralPath $codexDir -Filter 'AGENTS.md.backup.*')
        $claudeBackups.Count -eq 1 -and $codexBackups.Count -eq 1 -and
        (Get-Content -LiteralPath $claudeBackups[0].FullName -Raw) -ceq 'original Claude rules' -and
        (Get-Content -LiteralPath $codexBackups[0].FullName -Raw) -ceq 'original Codex rules' -and
        (Get-Content -LiteralPath $configFile -Raw) -ceq 'model = "keep-me"' -and
        (Get-FileHash -LiteralPath $claudeFile).Hash -eq $expectedHash -and
        (Get-FileHash -LiteralPath $codexFile).Hash -eq $expectedHash
    }

    Test-Case 'Repeated install leaves identical files and backups unchanged' {
        $claudeTime = (Get-Item -LiteralPath $claudeFile).LastWriteTimeUtc
        $codexTime = (Get-Item -LiteralPath $codexFile).LastWriteTimeUtc
        & $installer -ClaudeDir $claudeDir -CodexDir $codexDir 6>$null
        (Get-Item -LiteralPath $claudeFile).LastWriteTimeUtc -eq $claudeTime -and
        (Get-Item -LiteralPath $codexFile).LastWriteTimeUtc -eq $codexTime -and
        @(Get-ChildItem -LiteralPath $claudeDir -Filter '*.backup.*').Count -eq 1 -and
        @(Get-ChildItem -LiteralPath $codexDir -Filter '*.backup.*').Count -eq 1
    }

    Test-Case 'An active Codex override is reported and preserved' {
        $override = Join-Path $codexDir 'AGENTS.override.md'
        Set-Content -LiteralPath $override -Value 'override rules' -NoNewline
        $messages = @(& $installer -ClaudeDir $claudeDir -CodexDir $codexDir 3>&1)
        @($messages | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count -eq 1 -and
        (Get-Content -LiteralPath $override -Raw) -ceq 'override rules'
    }

    $settingsFile = Join-Path $claudeDir 'settings.json'
    @'
{
  "permissions": {
    "defaultMode": "default",
    "allow": ["Bash(git clean:*)"],
    "additionalDirectories": ["E:/work"],
    "disableBypassPermissionsMode": "disable"
  },
  "hooks": { "Stop": [{ "hooks": [{ "type": "command", "command": "example-hook" }] }] },
  "enabledPlugins": { "other@example": true },
  "env": { "EXAMPLE": "keep" }
}
'@ | Set-Content -LiteralPath $settingsFile -Encoding utf8
    $settingsHash = (Get-FileHash -LiteralPath $settingsFile).Hash

    Test-Case 'Permission preview identifies changes without writing settings or backups' {
        $messages = (& $claudeInstaller -Check -ClaudeDir $claudeDir 6>&1) -join "`n"
        $messages.Contains('permissions.defaultMode: [default] -> [auto]') -and
        $messages.Contains('- Bash(git clean:*)') -and
        $messages.Contains('+ Bash(git clean:*)') -and
        (Get-FileHash -LiteralPath $settingsFile).Hash -eq $settingsHash -and
        @(Get-ChildItem -LiteralPath $claudeDir -Filter 'settings.json.backup.*').Count -eq 0
    }

    Test-Case 'Permission update follows the template and preserves unrelated settings' {
        & $claudeInstaller -PermissionsOnly -ClaudeDir $claudeDir 6>$null
        $after = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
        $beforeBackup = @(Get-ChildItem -LiteralPath $claudeDir -Filter 'settings.json.backup.*')
        $after.permissions.defaultMode -ceq 'auto' -and
        $after.permissions.ask -ccontains 'Bash(git clean:*)' -and
        $after.permissions.allow -cnotcontains 'Bash(git clean:*)' -and
        $after.permissions.additionalDirectories[0] -ceq 'E:/work' -and
        $after.permissions.disableBypassPermissionsMode -ceq 'disable' -and
        $after.hooks.Stop[0].hooks[0].command -ceq 'example-hook' -and
        $after.enabledPlugins.'other@example' -eq $true -and
        $after.env.EXAMPLE -ceq 'keep' -and
        $null -eq $after.model -and
        $beforeBackup.Count -eq 1 -and
        (Get-FileHash -LiteralPath $beforeBackup[0].FullName).Hash -eq $settingsHash
    }

    Test-Case 'An identical permission update leaves the settings file and backup alone' {
        $time = (Get-Item -LiteralPath $settingsFile).LastWriteTimeUtc
        & $claudeInstaller -PermissionsOnly -ClaudeDir $claudeDir 6>$null
        (Get-Item -LiteralPath $settingsFile).LastWriteTimeUtc -eq $time -and
        @(Get-ChildItem -LiteralPath $claudeDir -Filter 'settings.json.backup.*').Count -eq 1
    }

    Test-Case 'Permission preview leaves a new profile unopened' {
        $newProfile = Join-Path $scratch 'unused profile'
        & $claudeInstaller -Check -ClaudeDir $newProfile 6>$null
        -not (Test-Path -LiteralPath $newProfile)
    }

    Test-Case 'Invalid settings abort a permission update without replacing the file' {
        Set-Content -LiteralPath $settingsFile -Value '{ malformed' -NoNewline
        try {
            & $claudeInstaller -PermissionsOnly -ClaudeDir $claudeDir 6>$null
            $false
        }
        catch {
            (Get-Content -LiteralPath $settingsFile -Raw) -ceq '{ malformed' -and
            @(Get-ChildItem -LiteralPath $claudeDir -Filter 'settings.json.backup.*').Count -eq 1
        }
    }
}
finally {
    $resolvedScratch = [IO.Path]::GetFullPath($scratch)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    if (-not $resolvedScratch.StartsWith($tempRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedScratch) -notlike 'dotfiles-instructions-test-*') { throw 'Unexpected test cleanup path.' }
    if (Test-Path -LiteralPath $resolvedScratch) { Remove-Item -LiteralPath $resolvedScratch -Recurse -Force }
}

Complete-Tests
