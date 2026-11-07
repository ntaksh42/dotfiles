# claude/skills/ の各スキルを ~/.claude/skills/ へ置く（同名のスキルは置き換える）。
# ~/.claude/skills が ~/.agents/skills へのジャンクションなら、Codex と共有される（Sync-DevToolSkills）。
# 使い方: pwsh -NoProfile -File tools/Install-DotfilesSkills.ps1 [-SkillsDir <path>]
param(
    [string]$SkillsDir = (Join-Path $env:USERPROFILE '.claude\skills')
)

$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot '..\claude\skills'
$tmp = $null
try {
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        # Install-DevTools は GitHub から本スクリプトだけを一時フォルダへ取得して実行するため、main の ZIP からスキルを取る
        $tmp = Join-Path $env:TEMP "dotfiles-skills-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $tmp | Out-Null
        $zip = Join-Path $tmp 'main.zip'
        Invoke-WebRequest -Uri 'https://github.com/ntaksh42/dotfiles/archive/refs/heads/main.zip' -OutFile $zip -UseBasicParsing
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $tmp 'x')
        $source = Join-Path (@(Get-ChildItem -LiteralPath (Join-Path $tmp 'x') -Directory)[0].FullName) 'claude\skills'
    }

    New-Item -ItemType Directory -Path $SkillsDir -Force | Out-Null
    foreach ($skill in Get-ChildItem -LiteralPath $source -Directory) {
        $dest = Join-Path $SkillsDir $skill.Name
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        Copy-Item -LiteralPath $skill.FullName -Destination $dest -Recurse
        Write-Host "配置: $dest"
    }
    Write-Host 'Claude Code を再起動すると反映される。'
}
finally {
    if ($tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
