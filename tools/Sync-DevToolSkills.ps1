# Share user skills between Codex and Claude Code without copying.
param(
    [string]$AgentsSkillsDir = (Join-Path $env:USERPROFILE '.agents\skills'),
    [string]$ClaudeSkillsDir = (Join-Path $env:USERPROFILE '.claude\skills')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\app-settings\pwsh\profile.d\devtools.ps1')
Sync-DevToolSkills -AgentsSkillsDir $AgentsSkillsDir -ClaudeSkillsDir $ClaudeSkillsDir
