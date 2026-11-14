# claude/skills/ の各スキルを ~/.claude/skills/ へ置く（同名のスキルは置き換える）。
# ~/.claude/skills が ~/.agents/skills へのジャンクションなら、Codex と共有される（Sync-DevToolSkills）。
# 使い方: pwsh -NoProfile -File tools/Install-DotfilesSkills.ps1 [-SkillsDir <path>]
# 配置した claude/skills の Git ツリー SHA を <SkillsDir>/.dotfiles-skills-tree に記録する。Install-DevTools はこれを
# GitHub の main と比べて更新を判定する。SHA が分からないとき（未コミットの変更がある、API に届かない）は記録を消し、次回も配置させる。
param(
    [string]$SkillsDir = (Join-Path $env:USERPROFILE '.claude\skills')
)

$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot '..\claude\skills'
$tmp = $null
$treeSha = $null
try {
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        # Install-DevTools は GitHub から本スクリプトだけを一時フォルダへ取得して実行するため、main の ZIP からスキルを取る
        $tmp = Join-Path $env:TEMP "dotfiles-skills-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $tmp | Out-Null
        $zip = Join-Path $tmp 'main.zip'
        Invoke-WebRequest -Uri 'https://github.com/ntaksh42/dotfiles/archive/refs/heads/main.zip' -OutFile $zip -UseBasicParsing
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $tmp 'x')
        $source = Join-Path (@(Get-ChildItem -LiteralPath (Join-Path $tmp 'x') -Directory)[0].FullName) 'claude\skills'
        try {
            $entries = Invoke-RestMethod -Uri 'https://api.github.com/repos/ntaksh42/dotfiles/contents/claude?ref=main' `
                -Headers @{ 'User-Agent' = 'dotfiles-install-devtools' }
            $treeSha = @(@($entries) | Where-Object { $_.name -eq 'skills' -and $_.type -eq 'dir' })[0].sha
        }
        catch { Write-Warning "claude/skills の SHA を取得できない: $($_.Exception.Message)" }
    }
    elseif (Get-Command git -ErrorAction SilentlyContinue) {
        # 手元のクローンから配置する。未コミットの変更があると main と一致しないので記録しない。
        $repo = Split-Path -Parent $PSScriptRoot
        $dirty = git -C $repo status --porcelain -- claude/skills 2>$null
        if ($LASTEXITCODE -eq 0 -and -not $dirty) {
            $treeSha = git -C $repo rev-parse HEAD:claude/skills 2>$null
            if ($LASTEXITCODE -ne 0) { $treeSha = $null }
        }
    }

    New-Item -ItemType Directory -Path $SkillsDir -Force | Out-Null
    # report-to-user への改名後、旧名のスキルが重複して残らないようにする。
    if (Test-Path -LiteralPath (Join-Path $source 'report-to-user') -PathType Container) {
        $skillsRoot = (Resolve-Path -LiteralPath $SkillsDir).Path
        $legacySkill = [System.IO.Path]::GetFullPath((Join-Path $skillsRoot 'request-user-check'))
        if ([System.IO.Path]::GetDirectoryName($legacySkill) -ne $skillsRoot) {
            throw "旧スキルの削除先が skills 直下ではありません: $legacySkill"
        }
        if (Test-Path -LiteralPath $legacySkill) {
            $legacyItem = Get-Item -LiteralPath $legacySkill -Force
            if ($legacyItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                Remove-Item -LiteralPath $legacySkill -Force
            } else {
                Remove-Item -LiteralPath $legacySkill -Recurse -Force
            }
            Write-Host "旧名を削除: $legacySkill"
        }
    }
    foreach ($skill in Get-ChildItem -LiteralPath $source -Directory) {
        $dest = Join-Path $SkillsDir $skill.Name
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        Copy-Item -LiteralPath $skill.FullName -Destination $dest -Recurse
        Write-Host "配置: $dest"
    }
    $marker = Join-Path $SkillsDir '.dotfiles-skills-tree'
    if ($treeSha) {
        Set-Content -LiteralPath $marker -Value $treeSha -Encoding utf8NoBOM
    } elseif (Test-Path -LiteralPath $marker) {
        Remove-Item -LiteralPath $marker -Force
    }
    Write-Host 'Claude Code を再起動すると反映される。'
}
finally {
    if ($tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
