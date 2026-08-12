<#
.SYNOPSIS
  Markdown 本文から HTML レポートを生成し、保存してブラウザで開く。

.DESCRIPTION
  html-report スキルの中核スクリプト。種別ごとの色テーマ・バッジ・保存先を
  output-config.toml から解決し、Markdown 本文を HTML へ変換して
  templates/base.html に流し込む。

  番号は保存先ディレクトリの既存ファイルから自動採番する（-Number 指定時はそれを使う）。

.PARAMETER Kind
  レポート種別。review / bug / investigation / research / security / proposal のいずれか。

.PARAMETER Title
  レポートのタイトル。ヘッダー h1 と <title> に入る。

.PARAMETER Subtitle
  対象の説明（ブランチ名、調査対象など）。ヘッダーのメタ行に入る。

.PARAMETER BodyPath
  本文の Markdown ファイルパス。書式は references/markdown-syntax.md を参照。

.PARAMETER Cards
  サマリーカード。"ラベル|値|補足" 形式の文字列を最大3つまで。補足は省略可。

.PARAMETER Number
  レポート番号。省略時は保存先の最大番号+1（既存なしなら 1）。

.PARAMETER NoOpen
  生成後にブラウザで開かない。

.EXAMPLE
  .\New-HtmlReport.ps1 -Kind bug -Title "ログイン失敗の調査" -BodyPath body.md `
    -Cards "バグID|#142","ステータス|原因特定","影響範囲|認証全体"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('review', 'bug', 'investigation', 'research', 'security', 'proposal')]
    [string]$Kind,

    [Parameter(Mandatory)]
    [string]$Title,

    [string]$Subtitle = '',

    [Parameter(Mandatory)]
    [string]$BodyPath,

    [string[]]$Cards = @(),

    [int]$Number = 0,

    [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $PSCommandPath
$skillDir = Split-Path -Parent $scriptDir

# ---- 種別ごとのテーマ ----------------------------------------------------
# SKILL.md の色テーマ表と対応。ここを変えると全レポートの見た目が変わる。
# OnDark / Dim は暗所用。Accent をそのまま暗所で使うと沈むので、
# 明度を上げた同系色と、地に敷ける暗い同系色を組にして持つ。
$themes = @{
    review        = @{ Accent = '#1d4ed8'; Light = '#dbeafe'; OnDark = '#93b4fd'; Dim = '#1e3054'; Badge = 'CODE REVIEW' }
    bug           = @{ Accent = '#dc2626'; Light = '#fee2e2'; OnDark = '#fca5a5'; Dim = '#4c1d1d'; Badge = 'BUG ANALYSIS' }
    investigation = @{ Accent = '#7c3aed'; Light = '#ede9fe'; OnDark = '#c4b5fd'; Dim = '#332a55'; Badge = 'INVESTIGATION' }
    research      = @{ Accent = '#0891b2'; Light = '#cffafe'; OnDark = '#7dd3e8'; Dim = '#12414f'; Badge = 'RESEARCH' }
    security      = @{ Accent = '#ea580c'; Light = '#ffedd5'; OnDark = '#fdba74'; Dim = '#4a2a12'; Badge = 'SECURITY AUDIT' }
    proposal      = @{ Accent = '#0f766e'; Light = '#ccfbf1'; OnDark = '#5eead4'; Dim = '#12433f'; Badge = 'PROPOSAL' }
}
$theme = $themes[$Kind]

# ---- 設定読み込み --------------------------------------------------------
# TOML は単純な key = "value" 形式のみ想定。パーサを持ち込むほどの構造ではない。
function Read-OutputConfig {
    param([string]$Path)

    $config = @{
        BaseDir  = '~/reports'
        Subdirs  = @{}
        Prefixes = @{}
    }
    if (-not (Test-Path $Path)) { return $config }

    $section = ''
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $line = $line -replace '#.*$', ''   # 行末コメントを除去
        $line = $line.Trim()
        if (-not $line) { continue }

        if ($line -match '^\[(.+)\]$') { $section = $Matches[1]; continue }
        if ($line -notmatch '^(\S+)\s*=\s*"(.*)"$') { continue }

        $key = $Matches[1]
        $value = $Matches[2]
        switch ($section) {
            'output'          { if ($key -eq 'base_dir') { $config.BaseDir = $value } }
            'output.subdirs'  { $config.Subdirs[$key] = $value }
            'output.prefixes' { $config.Prefixes[$key] = $value }
        }
    }
    return $config
}

$config = Read-OutputConfig -Path (Join-Path $skillDir 'output-config.toml')

# ~ はホームディレクトリへ展開する。PowerShell の Resolve-Path は
# 未作成のパスで失敗するので手動で処理する。
$baseDir = $config.BaseDir
if ($baseDir -match '^~[/\\]?(.*)$') {
    $baseDir = Join-Path $HOME $Matches[1]
}

$subdir = if ($config.Subdirs.ContainsKey($Kind)) { $config.Subdirs[$Kind] } else { '' }
$outDir = if ($subdir) { Join-Path $baseDir $subdir } else { $baseDir }
$prefix = if ($config.Prefixes.ContainsKey($Kind)) { $config.Prefixes[$Kind] } else { $Kind }

if (-not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

# ---- 番号決定 ------------------------------------------------------------
if ($Number -le 0) {
    $pattern = [regex]::Escape($prefix) + '(\d+)\.html$'
    $existing = Get-ChildItem -LiteralPath $outDir -Filter "$prefix*.html" -File -ErrorAction SilentlyContinue |
        ForEach-Object { if ($_.Name -match $pattern) { [int]$Matches[1] } }

    $Number = if ($existing) { ([int[]]$existing | Measure-Object -Maximum).Maximum + 1 } else { 1 }
}
$docId = '{0}{1:D3}' -f $prefix, $Number
$outPath = Join-Path $outDir "$docId.html"

# ---- Markdown → HTML -----------------------------------------------------
. (Join-Path $scriptDir 'ConvertTo-ReportHtml.ps1')

if (-not (Test-Path $BodyPath)) {
    throw "本文ファイルが見つかりません: $BodyPath"
}
$markdown = Get-Content -LiteralPath $BodyPath -Raw -Encoding UTF8
$mainContent = ConvertTo-ReportHtml -Markdown $markdown

# ---- サマリーカード ------------------------------------------------------
$cardsHtml = ''
if ($Cards.Count -gt 0) {
    $items = foreach ($card in $Cards) {
        $parts = $card -split '\|'
        $label = ConvertTo-HtmlText $parts[0].Trim()
        $value = if ($parts.Count -gt 1) { ConvertTo-HtmlText $parts[1].Trim() } else { '-' }
        $sub = if ($parts.Count -gt 2) { ConvertTo-HtmlText $parts[2].Trim() } else { '' }

        # 値が長いとカード内で折り返して不格好になるので、字数に応じて縮める
        $style = if ($value.Length -gt 12) { ' style="font-size:1rem"' } else { '' }

        @"
  <div class="summary-card">
    <div class="label">$label</div>
    <div class="value"$style>$value</div>
    <div class="sub">$sub</div>
  </div>
"@
    }
    $cardsHtml = "<div class=`"summary-grid`">`n" + ($items -join "`n") + "`n</div>"
}

# ---- 目次 ----------------------------------------------------------------
# セクションが少ないうちは、目次があっても視線が増えるだけで得がない。
# 画面に収まらなくなる 5 個以上のときだけ出す。
$tocHtml = ''
if ($script:ReportSections.Count -ge 5) {
    $links = foreach ($sec in $script:ReportSections) {
        "    <li><a href=`"#$($sec.Anchor)`">$($sec.Title)</a></li>"
    }
    $tocHtml = @"
<div class="toc">
  <div class="toc-title">目次</div>
  <ol>
$($links -join "`n")
  </ol>
</div>
"@
}

# ---- テンプレート適用 ----------------------------------------------------
$templatePath = Join-Path $skillDir 'templates/base.html'
$html = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8

$date = Get-Date -Format 'yyyy-MM-dd'
$replacements = @{
    '{{TITLE}}'           = ConvertTo-HtmlText $Title
    '{{ACCENT_COLOR}}'    = $theme.Accent
    '{{ACCENT_LIGHT}}'    = $theme.Light
    '{{ACCENT_ON_DARK}}'  = $theme.OnDark
    '{{ACCENT_DIM}}'      = $theme.Dim
    '{{BADGE_LABEL}}'     = $theme.Badge
    '{{SUBTITLE}}'        = ConvertTo-HtmlText $Subtitle
    '{{DATE}}'            = $date
    '{{DOC_ID}}'          = $docId
    '{{SUMMARY_CARDS}}'   = $cardsHtml
    '{{TOC}}'             = $tocHtml
    '{{MAIN_CONTENT}}'    = $mainContent
}
foreach ($key in $replacements.Keys) {
    $html = $html.Replace($key, $replacements[$key])
}

# Mermaid ブロックがある場合のみ描画スクリプトを差し込む。
# 図を使わないレポートに CDN 依存を持ち込まないための分岐。
if ($mainContent -match 'class="mermaid"') {
    # 暗所では neutral テーマだと図が白飛びするので配色を切り替える。
    # CDN に届かない環境では図が描画されないままなので、
    # 「壊れている」のか「読み込めていない」のかが分かる注記を出す。
    $mermaidInit = @'
<script type="module">
  const dark = window.matchMedia('(prefers-color-scheme: dark)').matches;
  try {
    const { default: mermaid } = await import('https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs');
    mermaid.initialize({ startOnLoad: true, theme: dark ? 'dark' : 'neutral', securityLevel: 'strict' });
  } catch (e) {
    for (const el of document.querySelectorAll('pre.mermaid')) {
      el.classList.add('mermaid-offline');
      const note = document.createElement('div');
      note.className = 'mermaid-note';
      note.textContent = '図を描画できませんでした（オフライン）。以下は図の定義です。';
      el.parentNode.insertBefore(note, el);
    }
  }
</script>
'@
    $html = $html.Replace('</body>', "$mermaidInit`n</body>")
}

# BOM なし UTF-8 で書く。BOM があるとブラウザによっては先頭に余計な文字が出る。
[System.IO.File]::WriteAllText($outPath, $html, (New-Object System.Text.UTF8Encoding $false))

Write-Host "保存しました: $outPath"
Write-Host "種別: $Kind / ID: $docId"

if (-not $NoOpen) {
    Start-Process $outPath
}

# 呼び出し元がパスを使えるように返す
$outPath
