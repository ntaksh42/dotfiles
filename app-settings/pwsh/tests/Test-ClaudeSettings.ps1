$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHarness.ps1')

$repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$installer = Join-Path $repo 'tools/Install-ClaudeSettings.ps1'
$scratch = Join-Path ([IO.Path]::GetTempPath()) "claude-settings-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $scratch | Out-Null

try {
    Test-Case 'Claude settings: check twice, merge, and leave the second run unchanged' {
        $path = Join-Path $scratch 'settings.json'
        $original = @'
{
  "outputStyle": "Explanatory",
  "skillListingBudgetFraction": 0.01,
  "skillOverrides": {"crit": "name-only", "custom": "full"},
  "autoMode": {"environment": ["existing permission", "$defaults"], "other": true},
  "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "node \"C:/tmp/hook.mjs\""}]}]},
  "env": {"EXAMPLE": "untouched"}
}
'@
        $original = ($original -replace '\r?\n', "`r`n") + "`r`n"
        [IO.File]::WriteAllText($path, $original, [Text.UTF8Encoding]::new($true))
        $before = Get-FileHash -LiteralPath $path

        $firstCheck = @(& $installer -ClaudeDir $scratch -Check)
        $backupFilter = 'settings.json.backup.*'
        $checkUnchanged = $before.Hash -eq (Get-FileHash -LiteralPath $path).Hash -and
            @(Get-ChildItem -LiteralPath $scratch -Filter $backupFilter).Count -eq 0

        & $installer -ClaudeDir $scratch
        $applied = Get-FileHash -LiteralPath $path
        $settings = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        $finalCheck = @(& $installer -ClaudeDir $scratch -Check)
        & $installer -ClaudeDir $scratch
        $unchanged = $applied.Hash -eq (Get-FileHash -LiteralPath $path).Hash -and
            $applied.Hash -ne $before.Hash
        $backups = @(Get-ChildItem -LiteralPath $scratch -Filter $backupFilter)
        $text = [IO.File]::ReadAllText($path)
        $kept = $settings.hooks.Stop[0].hooks[0].command -ceq 'node "C:/tmp/hook.mjs"' -and
            $settings.skillOverrides.custom -ceq 'full' -and $settings.autoMode.other -eq $true -and
            $settings.autoMode.environment[0] -ceq '$defaults' -and
            $settings.autoMode.environment[1] -ceq 'existing permission' -and $settings.env.EXAMPLE -ceq 'untouched'
        Write-Host "  Check runs: $($firstCheck.Count), $($finalCheck.Count) diff lines; initial check made no writes=$checkUnchanged"
        Write-Host "  Merge preserves hooks, skill overrides and auto mode settings=$kept"
        Write-Host "  Second apply leaves the file unchanged=$unchanged; post-apply diff lines=$($finalCheck.Count); backups=$($backups.Count)"

        $firstCheck.Count -gt 0 -and $checkUnchanged -and
        $settings.outputStyle -ceq 'Concise' -and $settings.skillListingBudgetFraction -eq 0.03 -and
        $settings.skillOverrides.crit -ceq 'user-invocable-only' -and $settings.autoMode.environment.Count -eq 3 -and
        $settings.autoMode.environment[2] -clike '**Source control**:*' -and $kept -and
        $text -notmatch '(?<!\r)\n' -and $text.EndsWith("`r`n") -and [IO.File]::ReadAllBytes($path)[0] -eq 239 -and
        $unchanged -and $finalCheck.Count -eq 0 -and $backups.Count -eq 1 -and
        (Get-FileHash -LiteralPath $backups[0].FullName).Hash -eq $before.Hash
    }

    Test-Case 'Claude settings: a standalone installer fetches the template and creates a settings file' {
        $copy = Join-Path $scratch 'Install-ClaudeSettings.ps1'
        $dest = Join-Path $scratch 'new-profile'
        Copy-Item -LiteralPath $installer -Destination $copy
        function Invoke-WebRequest {
            param([string]$Uri, [switch]$UseBasicParsing)
            if ($Uri -cne 'https://raw.githubusercontent.com/ntaksh42/dotfiles/main/claude/settings.template.json') {
                throw "Unexpected URI: $Uri"
            }
            [pscustomobject]@{ Content = [IO.File]::ReadAllText((Join-Path $repo 'claude/settings.template.json')) }
        }
        & $copy -ClaudeDir $dest
        $settings = Get-Content -LiteralPath (Join-Path $dest 'settings.json') -Raw | ConvertFrom-Json -AsHashtable
        $settings.Count -eq 4 -and $settings.autoMode.environment.Count -eq 2 -and
        $settings.autoMode.environment[0] -ceq '$defaults' -and @(& $copy -ClaudeDir $dest -Check).Count -eq 0
    }

    Test-Case 'Claude settings: a malformed settings file is left intact' {
        $dest = Join-Path $scratch 'invalid'
        New-Item -ItemType Directory -Path $dest | Out-Null
        $path = Join-Path $dest 'settings.json'
        [IO.File]::WriteAllText($path, '{"bad":')
        $failed = $false
        try { & $installer -ClaudeDir $dest }
        catch { $failed = $true }
        $failed -and [IO.File]::ReadAllText($path) -ceq '{"bad":' -and @(Get-ChildItem -LiteralPath $dest).Count -eq 1
    }
}
finally {
    $resolvedScratch = [IO.Path]::GetFullPath($scratch)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    if (-not $resolvedScratch.StartsWith($tempRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedScratch) -notlike 'claude-settings-*') { throw 'Unexpected test cleanup path.' }
    Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
}

Complete-Tests
