<#
.SYNOPSIS
  Markdown 本文から HTML レポートを生成し、保存してブラウザで開く。

.DESCRIPTION
  report-to-user のレポート生成。種別ごとの色テーマ・バッジ・保存先を
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

.PARAMETER OutputPath
  保存先を明示する。省略時は設定から自動採番する。Orca の scratch 出力などに使う。

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

    [switch]$NoOpen,

    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $PSCommandPath
$skillDir = Split-Path -Parent $scriptDir

# ---- 種別ごとのテーマ ----------------------------------------------------
# SKILL.md の色テーマ表と対応。ここを変えると全レポートの見た目が変わる。
# OnDark / Dim は暗所用。Accent をそのまま暗所で使うと沈むので、
# 明度を上げた同系色と、地に敷ける暗い同系色を組にして持つ。
$themes = @{
    review        = @{ Accent = '#1d4ed8'; Light = '#dbeafe'; OnDark = '#93b4fd'; Dim = '#1e3054'; Badge = 'レビュー' }
    bug           = @{ Accent = '#dc2626'; Light = '#fee2e2'; OnDark = '#fca5a5'; Dim = '#4c1d1d'; Badge = '不具合' }
    investigation = @{ Accent = '#7c3aed'; Light = '#ede9fe'; OnDark = '#c4b5fd'; Dim = '#332a55'; Badge = '調査' }
    research      = @{ Accent = '#0891b2'; Light = '#cffafe'; OnDark = '#7dd3e8'; Dim = '#12414f'; Badge = '技術調査' }
    security      = @{ Accent = '#ea580c'; Light = '#ffedd5'; OnDark = '#fdba74'; Dim = '#4a2a12'; Badge = 'セキュリティ' }
    proposal      = @{ Accent = '#0f766e'; Light = '#ccfbf1'; OnDark = '#5eead4'; Dim = '#12433f'; Badge = '提案' }
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

if ($OutputPath) {
    $outPath = [System.IO.Path]::GetFullPath($OutputPath)
    $outDir = Split-Path -Parent $outPath
    $docId = [System.IO.Path]::GetFileNameWithoutExtension($outPath)
} else {
    # ---- 番号決定 --------------------------------------------------------
    if ($Number -le 0) {
        $pattern = [regex]::Escape($prefix) + '(\d+)\.html$'
        $existing = if (Test-Path -LiteralPath $outDir) {
            Get-ChildItem -LiteralPath $outDir -Filter "$prefix*.html" -File |
                ForEach-Object { if ($_.Name -match $pattern) { [int]$Matches[1] } }
        }
        $Number = if ($existing) { ([int[]]$existing | Measure-Object -Maximum).Maximum + 1 } else { 1 }
    }
    $docId = '{0}{1:D3}' -f $prefix, $Number
    $outPath = Join-Path $outDir "$docId.html"
}

if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

# ---- Markdown → HTML -----------------------------------------------------
. (Join-Path $scriptDir 'ConvertTo-ReportHtml.ps1')

if (-not (Test-Path $BodyPath)) {
    throw "本文ファイルが見つかりません: $BodyPath"
}
$markdown = Get-Content -LiteralPath $BodyPath -Raw -Encoding UTF8
$mainContent = ConvertTo-ReportHtml -Markdown $markdown

# ---- サマリーカード ------------------------------------------------------
$cardsHtml = ''
# pwsh -File で呼ぶと -Cards "a|b","c|d" は配列にならず "a|b,c|d" の 1 つの文字列で届く。
# そのまま分けると 2 枚目が 1 枚目の値と補足に混ざるので、
# 「, の直後に短いラベルと |」が続く所でカードを分け直す。
# ラベルは「結論」「次の行動」のような短い語なので、空白や読点を含む句は区切りとみなさない。
$Cards = @(foreach ($card in $Cards) {
    $card -split ',(?=[^,|\s、。]{1,12}\|)'
})
if ($Cards.Count -gt 0) {
    $items = foreach ($card in $Cards) {
        $parts = $card -split '\|'
        $label = ConvertTo-HtmlText $parts[0].Trim()
        $value = if ($parts.Count -gt 1) { ConvertTo-HtmlText $parts[1].Trim() } else { '-' }
        $sub = if ($parts.Count -gt 2) { ConvertTo-HtmlText $parts[2].Trim() } else { '' }

        @"
  <div class="summary-card">
    <div class="label">$label</div>
    <div class="value">$value</div>
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
        # 重大・注意の件数だけ添える。項目数は何の数か読み取れないので出さない。
        # 番号は見出し側に書かれることが多いので、目次では振らない。
        $meta = ''
        if ($sec.Red -gt 0)    { $meta += "<span class=`"toc-flag toc-red`">重大 $($sec.Red)</span>" }
        if ($sec.Yellow -gt 0) { $meta += "<span class=`"toc-flag toc-yellow`">注意 $($sec.Yellow)</span>" }
        "    <li><a href=`"#$($sec.Anchor)`"><span class=`"toc-label`">$($sec.Title)</span>$meta</a></li>"
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

# ---- 重要度サマリー ------------------------------------------------------
# 重大・注意が何件あるかは、開いた瞬間にいちばん知りたいこと。
# 本文を読み進めて数える作業を省く。
$severityHtml = ''
$totalRed = ($script:ReportSections | Measure-Object -Property Red -Sum).Sum
$totalYellow = ($script:ReportSections | Measure-Object -Property Yellow -Sum).Sum
if ($totalRed -gt 0 -or $totalYellow -gt 0) {
    $parts = @()
    if ($totalRed -gt 0)    { $parts += "<span class=`"sev sev-red`">重大 $totalRed</span>" }
    if ($totalYellow -gt 0) { $parts += "<span class=`"sev sev-yellow`">注意 $totalYellow</span>" }
    $severityHtml = "<div class=`"severity-bar`">" + ($parts -join '') + "</div>"
}

# ---- テンプレート適用 ----------------------------------------------------
$templatePath = Join-Path $skillDir 'templates/base.html'
$html = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8

$date = Get-Date -Format 'yyyy-MM-dd'
# 見出しの上の 1 行: 種別 · 対象 · 日付。対象が無ければ区切りごと省く
$metaParts = @("<span class=`"kind`">$($theme.Badge)</span>")
if ($Subtitle) { $metaParts += "<span>$(ConvertTo-HtmlText $Subtitle)</span>" }
$metaParts += "<span>$date</span>"
$metaHtml = $metaParts -join ''
$replacements = @{
    '{{TITLE}}'           = ConvertTo-HtmlText $Title
    '{{ACCENT_COLOR}}'    = $theme.Accent
    '{{ACCENT_LIGHT}}'    = $theme.Light
    '{{ACCENT_ON_DARK}}'  = $theme.OnDark
    '{{ACCENT_DIM}}'      = $theme.Dim
    '{{META}}'            = $metaHtml
    '{{DATE}}'            = $date
    '{{DOC_ID}}'          = $docId
    '{{SUMMARY_CARDS}}'   = $cardsHtml
    '{{SEVERITY}}'        = $severityHtml
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
  // 表示側のテーマ (Orca は OS と別に切り替えられる) に合わせるため、
  // prefers-color-scheme ではなく実際の背景の明るさで配色を選ぶ。
  const bg = getComputedStyle(document.body).backgroundColor.match(/\d+(\.\d+)?/g) || [255, 255, 255];
  const dark = (0.299 * bg[0] + 0.587 * bg[1] + 0.114 * bg[2]) < 128;
  try {
    const { default: mermaid } = await import('https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.esm.min.mjs');
    // startOnLoad は load イベントで描画する。import を待つ間に load が終わっていると
    // 何も描かれないので、初期化のあとで明示的に run する。
    mermaid.initialize({
      startOnLoad: false,
      theme: dark ? 'dark' : 'neutral',
      securityLevel: 'strict',
      fontFamily: getComputedStyle(document.body).fontFamily,
    });
    await mermaid.run({ querySelector: 'pre.mermaid' });
    // 横に長いシーケンス図を枠の幅まで縮めると字が読めなくなる。
    // 縮めるのは元の 7 割までにして、はみ出すぶんは枠の中で横スクロールさせる。
    for (const svg of document.querySelectorAll('pre.mermaid svg')) {
      const natural = svg.viewBox.baseVal && svg.viewBox.baseVal.width;
      const box = svg.parentElement.clientWidth - 32;
      if (!natural || natural <= box) continue;
      svg.style.maxWidth = 'none';
      svg.style.width = Math.round(Math.max(box, natural * 0.7)) + 'px';
    }
  } catch (e) {
    for (const el of document.querySelectorAll('pre.mermaid:not([data-processed])')) {
      el.classList.add('mermaid-offline');
      const note = document.createElement('div');
      note.className = 'mermaid-note';
      note.textContent = '図を描画できませんでした。以下は図の定義です。';
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
