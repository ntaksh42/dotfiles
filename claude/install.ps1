# Claude Code dotfiles installer for Windows
# Usage: .\install.ps1

$ErrorActionPreference = "Stop"

# Paths
$ScriptDir       = Split-Path -Parent $MyInvocation.MyCommand.Path
$ClaudeDir       = Join-Path $env:USERPROFILE ".claude"
$HooksSourceDir  = Join-Path $ScriptDir "hooks"
$HooksDestDir    = Join-Path $ClaudeDir "hooks"
$SkillsSourceDir = Join-Path $ScriptDir "skills"
$SkillsDestDir   = Join-Path $ClaudeDir "skills"
$TemplateFile    = Join-Path $ScriptDir "settings.template.json"
$ReviewGatePromptFile = Join-Path $HooksSourceDir "review-gate.prompt.md"
$DefaultIdleOutputDir = Join-Path $env:USERPROFILE "claude-idle-snapshots"

Write-Host "Claude Code dotfiles installer" -ForegroundColor Cyan
Write-Host "==============================" -ForegroundColor Cyan
Write-Host ""

# Create .claude directory if not exists
if (-not (Test-Path $ClaudeDir)) {
    Write-Host "Creating $ClaudeDir ..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $ClaudeDir | Out-Null
}

# Backup existing settings.json
$SettingsFile = Join-Path $ClaudeDir "settings.json"
if (Test-Path $SettingsFile) {
    $BackupFile = Join-Path $ClaudeDir "settings.json.backup.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Write-Host "Backing up existing settings.json to $BackupFile" -ForegroundColor Yellow
    Copy-Item $SettingsFile $BackupFile
}

# Copy hook scripts to .claude/hooks/ and register in settings.json
Write-Host "Copying hook scripts..." -ForegroundColor Green
if (-not (Test-Path $HooksDestDir)) {
    New-Item -ItemType Directory -Path $HooksDestDir -Force | Out-Null
}

$HookRegistrations = @()
foreach ($file in (Get-ChildItem -Path $HooksSourceDir -Filter "*.ps1")) {
    $dest = Join-Path $HooksDestDir $file.Name
    Copy-Item $file.FullName $dest -Force
    Write-Host "  - hooks\$($file.Name)" -ForegroundColor Gray

    # .HOOK ブロックからメタデータを抽出
    $content = Get-Content $file.FullName -Raw
    if ($content -match '(?s)<#\s*\.HOOK\s*(\{.*?\})\s*#>') {
        try {
            $meta = $Matches[1] | ConvertFrom-Json
            $HookRegistrations += [PSCustomObject]@{
                file        = $file.Name
                event       = $meta.event
                matcher     = if ($meta.PSObject.Properties.Name -contains "matcher")     { $meta.matcher }     else { $null }
                async       = if ($meta.PSObject.Properties.Name -contains "async")       { $meta.async }       else { $null }
                asyncRewake = if ($meta.PSObject.Properties.Name -contains "asyncRewake") { $meta.asyncRewake } else { $null }
            }
            $asyncLabel = if ($meta.PSObject.Properties.Name -contains "async" -and $meta.async) { ", async=true" } else { "" }
            Write-Host "    -> event=$($meta.event)$(if ($meta.matcher) { ", matcher=$($meta.matcher)" })$asyncLabel" -ForegroundColor DarkGray
        } catch {
            Write-Host "    -> WARNING: Failed to parse .HOOK metadata" -ForegroundColor Yellow
        }
    }
}

# Copy skills
if (Test-Path $SkillsSourceDir) {
    Write-Host "Copying skills..." -ForegroundColor Green
    if (-not (Test-Path $SkillsDestDir)) {
        New-Item -ItemType Directory -Path $SkillsDestDir | Out-Null
    }
    $SkillDirs = Get-ChildItem -Path $SkillsSourceDir -Directory
    foreach ($skillDir in $SkillDirs) {
        $destSkillDir = Join-Path $SkillsDestDir $skillDir.Name
        Copy-Item $skillDir.FullName $destSkillDir -Recurse -Force
        Write-Host "  - $($skillDir.Name)" -ForegroundColor Gray
    }
}

# Set ENABLE_TOOL_SEARCH environment variable if not exists
$envName = "ENABLE_TOOL_SEARCH"
$currentValue = [Environment]::GetEnvironmentVariable($envName, "User")
if (-not $currentValue) {
    Write-Host "Setting $envName environment variable..." -ForegroundColor Green
    [Environment]::SetEnvironmentVariable($envName, "true", "User")
    $env:ENABLE_TOOL_SEARCH = "true"
    Write-Host "  - $envName = true (User scope)" -ForegroundColor Gray
} else {
    Write-Host "$envName already set: $currentValue" -ForegroundColor Gray
}

# Generate settings.json from template
Write-Host "Generating settings.json..." -ForegroundColor Green
$template = Get-Content $TemplateFile -Raw
$claudeDirEscaped   = $ClaudeDir -replace '\\', '\\\\'
$idleOutputEscaped  = $DefaultIdleOutputDir -replace '\\', '\\\\'
$settings = $template -replace '\{\{CLAUDE_DIR\}\}', $claudeDirEscaped `
                      -replace '\{\{IDLE_OUTPUT_DIR\}\}', $idleOutputEscaped

# review-gate agent フックのプロンプトをファイルから読み込み、JSON 文字列として埋め込む。
# PS5.1 の ConvertTo-Json は単一文字列を {value,Count,...} に包む癖があるため使わず、
# JSON 文字列に必要な最小限のエスケープを決定的に適用する。
if (Test-Path $ReviewGatePromptFile) {
    $reviewGatePrompt = Get-Content $ReviewGatePromptFile -Raw -Encoding UTF8
    $escaped = $reviewGatePrompt -replace '\\', '\\' `
                                 -replace '"', '\"' `
                                 -replace "`r", '\r' `
                                 -replace "`n", '\n' `
                                 -replace "`t", '\t'
    # テンプレート側の "prompt": "{{REVIEW_GATE_PROMPT}}" の placeholder のみ差し替える
    # （$ を特別扱いする -replace ではなく literal な .Replace を使う）
    $settings = $settings.Replace('{{REVIEW_GATE_PROMPT}}', $escaped)
}

$settingsObj = $settings | ConvertFrom-Json

# hooks/ スクリプトのメタデータから settings.json に hook を登録
if ($HookRegistrations.Count -gt 0) {
    Write-Host "Registering hooks from metadata..." -ForegroundColor Green

    if (-not ($settingsObj.PSObject.Properties.Name -contains "hooks")) {
        $settingsObj | Add-Member -MemberType NoteProperty -Name "hooks" -Value ([PSCustomObject]@{})
    }

    foreach ($reg in $HookRegistrations) {
        $cmd = "powershell.exe -ExecutionPolicy Bypass -File `"%USERPROFILE%\\.claude\\hooks\\$($reg.file)`""
        $cmdEntry = [PSCustomObject]@{ type = "command"; command = $cmd }
        if ($null -ne $reg.async)       { $cmdEntry | Add-Member -MemberType NoteProperty -Name "async"       -Value $reg.async }
        if ($null -ne $reg.asyncRewake) { $cmdEntry | Add-Member -MemberType NoteProperty -Name "asyncRewake" -Value $reg.asyncRewake }

        $hookEntry = [PSCustomObject]@{ hooks = @($cmdEntry) }
        if ($reg.matcher) {
            $hookEntry | Add-Member -MemberType NoteProperty -Name "matcher" -Value $reg.matcher
        }

        $event = $reg.event
        if (-not ($settingsObj.hooks.PSObject.Properties.Name -contains $event)) {
            $settingsObj.hooks | Add-Member -MemberType NoteProperty -Name $event -Value @()
        }

        # 同じ matcher が既に存在する場合はスキップ
        $alreadyExists = @($settingsObj.hooks.$event | Where-Object {
            ($null -eq $reg.matcher -and -not ($_.PSObject.Properties.Name -contains "matcher")) -or
            ($_.PSObject.Properties.Name -contains "matcher" -and $_.matcher -eq $reg.matcher)
        })
        if ($alreadyExists.Count -gt 0) {
            Write-Host "  - $($reg.file): already registered, skipping" -ForegroundColor DarkGray
        } else {
            $settingsObj.hooks.$event += $hookEntry
            Write-Host "  - $($reg.file): registered to $event$(if ($reg.matcher) { "[$($reg.matcher)]" })" -ForegroundColor Gray
        }
    }
}

$settingsObj | ConvertTo-Json -Depth 10 | Set-Content -Path $SettingsFile -Encoding UTF8

# Create idle output directory
if (-not (Test-Path $DefaultIdleOutputDir)) {
    New-Item -ItemType Directory -Path $DefaultIdleOutputDir -Force | Out-Null
    Write-Host "Created idle output dir: $DefaultIdleOutputDir" -ForegroundColor Gray
}

Write-Host ""
Write-Host "Installation complete!" -ForegroundColor Green
Write-Host ""
Write-Host "Installed files:" -ForegroundColor Cyan
Get-ChildItem $ClaudeDir -Filter "*.ps1" | ForEach-Object { Write-Host "  - $($_.FullName)" -ForegroundColor Gray }
Write-Host "  - $SettingsFile" -ForegroundColor Gray
if (Test-Path $SkillsDestDir) {
    Write-Host "Installed skills:" -ForegroundColor Cyan
    Get-ChildItem $SkillsDestDir -Directory | ForEach-Object { Write-Host "  - $($_.Name)" -ForegroundColor Gray }
}
Write-Host ""
Write-Host "Note: Restart Claude Code for changes to take effect." -ForegroundColor Yellow
