# ---------------------------------------------------------------------------
# §3c gita (複数リポジトリ管理)
# ---------------------------------------------------------------------------

# gita reads git output with the locale codec (cp932), which fails on UTF-8 commit messages
# (gita ll -> UnicodeDecodeError). Python's UTF-8 mode fixes that.
$env:PYTHONUTF8 = '1'

# gita wrapper: clean each repo's stray "nul" file, then pull every repo.
# A repo whose current branch has no origin upstream is switched to -Fallback first.
function gita-pull-all {
    [CmdletBinding()]
    param([string]$Fallback = 'main')

    if (-not (Test-Cmd gita)) { Write-Warning 'gita-pull-all needs gita (gita add <path> to register repos)'; return }

    $names = @(((gita ls) -join ' ') -split '\s+' | Where-Object { $_ })
    if ($names.Count -eq 0) { Write-Warning 'No repos registered in gita (use: gita add <path>)'; return }

    foreach ($name in $names) {
        $repo = (gita ls $name).Trim()
        Write-Host "[$name] " -ForegroundColor Cyan -NoNewline
        if (-not $repo -or -not (Test-Path -LiteralPath $repo)) { Write-Warning "path not found: $repo"; continue }
        Write-Host $repo -ForegroundColor DarkGray

        # 1) Remove Windows-reserved "nul" files (block git checkout/pull on Windows).
        $stray = @(
            git -C $repo ls-files
            git -C $repo ls-files --others --exclude-standard
        ) | Where-Object { $_ -match '(^|/)nul$' } | Sort-Object -Unique
        foreach ($rel in $stray) {
            $full = Join-Path $repo ($rel -replace '/', '\')
            Remove-Item -LiteralPath "\\?\$full" -Force -ErrorAction SilentlyContinue
            Write-Host "  removed stray file: $rel" -ForegroundColor Yellow
        }

        # 2) Fetch, then pull the current branch; fall back if it has no origin upstream.
        git -C $repo fetch --prune --quiet
        $branch = (git -C $repo rev-parse --abbrev-ref HEAD).Trim()
        git -C $repo rev-parse --verify --quiet "origin/$branch" *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  no origin/$branch -> switching to $Fallback" -ForegroundColor Yellow
            git -C $repo checkout $Fallback
            if ($LASTEXITCODE -ne 0) { Write-Warning "  checkout $Fallback failed"; continue }
        }
        git -C $repo pull --ff-only
    }
}

# このディレクトリと直下のサブディレクトリにある git リポジトリを gita に登録。
function gita-scan {
    param([string]$Path = '.')
    if (-not (Test-Cmd gita)) { Write-Warning 'gita-scan needs gita'; return }
    $root = (Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue).Path
    if (-not $root) { Write-Warning "Path not found: $Path"; return }

    $targets = @()
    if (Test-Path -LiteralPath (Join-Path $root '.git')) { $targets += $root }
    $targets += @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.git') } |
        Select-Object -ExpandProperty FullName)

    if ($targets.Count -eq 0) { Write-Host 'No git repos found (this dir and its direct subdirs).' -ForegroundColor Yellow; return }
    foreach ($t in $targets) { gita add $t }
    Write-Host "Registered $($targets.Count) repo(s) with gita." -ForegroundColor Green
}

# gita の登録 (repos.csv) から gita ll を失敗させる行を探す: フォルダがない / 名前が空 / git で開けない。
# 一覧を出し、確認のうえ削除する (元のファイルは .bak に残す)。名前が空の行は gita rm で消せないため直接編集する。
function gita-doctor {
    param([string]$Path = (Join-Path $HOME '.config\gita\repos.csv'))
    if (-not (Test-Path -LiteralPath $Path)) { Write-Warning "gita registry not found: $Path"; return }

    $lines = @(Get-Content -LiteralPath $Path | Where-Object { $_.Trim() })
    $bad = @(foreach ($line in $lines) {
            $fields = $line -split ','
            $repo = $fields[0]; $name = $fields[1]
            $reason = if (-not (Test-Path -LiteralPath $repo)) { 'folder not found' }
            elseif (-not $name) { 'empty name' }
            else {
                git -C $repo rev-parse --git-dir *> $null
                if ($LASTEXITCODE -ne 0) { 'not a git repository' }
            }
            if ($reason) { [pscustomobject]@{ Name = $name; Path = $repo; Reason = $reason; Line = $line } }
        })

    if ($bad.Count -eq 0) { Write-Host "No problems in $($lines.Count) gita entries." -ForegroundColor Green; return }
    foreach ($b in $bad) { Write-Host ("  {0,-22} {1,-12} {2}" -f $b.Reason, $b.Name, $b.Path) -ForegroundColor Yellow }
    if ((Read-Host "Remove these $($bad.Count) entries? (y/N)") -notmatch '^(y|yes)$') { Write-Host 'Aborted.'; return }

    Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force
    Set-Content -LiteralPath $Path -Value @($lines | Where-Object { $_ -notin $bad.Line }) -Encoding utf8NoBOM
    Write-Host "Removed $($bad.Count) entries (backup: $Path.bak)." -ForegroundColor Green
}
