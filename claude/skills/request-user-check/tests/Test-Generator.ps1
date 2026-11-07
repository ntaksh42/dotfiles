# 実際の生成器を一時コピーで実行し、ユーザーのレポートを変更せずに検証する。
$ErrorActionPreference = 'Stop'
$source = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "request-user-check-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $testRoot | Out-Null
Copy-Item -LiteralPath $source -Destination (Join-Path $testRoot 'skill') -Recurse
$testSkill = Join-Path $testRoot 'skill'
$reportDir = (Join-Path $testRoot 'reports').Replace('\', '/')
@"
[output]
base_dir = "$reportDir"
[output.subdirs]
review = "reviews"
[output.prefixes]
review = "PR"
"@ | Set-Content -LiteralPath (Join-Path $testSkill 'output-config.toml') -Encoding utf8

$body = Join-Path $testRoot 'body.md'
$rows = 1..20 | ForEach-Object { "| 指摘$_ | 根拠$_ |" }
@"
## 結論
全指摘とコードを保持する。
## 指摘
| 項目 | 根拠 |
|---|---|
$($rows -join "`n")
## コード
``````typescript
const value = '<tag>';
``````
## 確度
[!green 確認済み]
## 成果物
[本文](file:///C:/reports/test%20report.html)
"@ | Set-Content -LiteralPath $body -Encoding utf8
$generator = Join-Path $testSkill 'scripts/New-HtmlReport.ps1'
$script:checks = 0
function Assert-Result([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL $Name" }
    $script:checks++
    Write-Host "ok    $Name"
}

# NoOpen が実際にブラウザ起動を抑えることも検査する。
function Start-Process { throw 'NoOpen が指定されたのにブラウザ起動が呼ばれました' }
$first = & $generator -Kind review -Title '統合 <確認>' -BodyPath $body -NoOpen
$second = & $generator -Kind review -Title '次のレポート' -BodyPath $body -NoOpen
Assert-Result ($first -eq (Join-Path $reportDir 'reviews/PR001.html')) '設定した保存先と初回番号'
Assert-Result ($second -eq (Join-Path $reportDir 'reviews/PR002.html')) '自動採番で別ファイルを保存'
$html = Get-Content -LiteralPath $first -Raw -Encoding utf8
Assert-Result (([regex]::Matches($html, '<td>指摘\d+</td>')).Count -eq 20) '20件の指摘を全件保持'
Assert-Result ($html.Contains("const value = '&lt;tag&gt;';")) 'コードをエスケープして保持'
Assert-Result ($html.Contains('統合 &lt;確認&gt;')) 'タイトルのエスケープ'
Assert-Result ($html.Contains('class="toc"')) '5節以上の目次'
Assert-Result ($html.Contains('prefers-color-scheme: dark')) 'ダークモードCSS'
Assert-Result ($html -notmatch '\{\{[A-Z_]+\}\}') '未置換変数なし'
Assert-Result ($html -notmatch 'https://cdn') 'MermaidなしはCDN依存なし'
Assert-Result ($html.Contains('href="file:///C:/reports/test%20report.html"')) 'ローカル成果物リンク'

$explicit = Join-Path $testRoot 'scratch/topic-ab12.html'
$path = & $generator -Kind investigation -Title 'Scratch' -BodyPath $body -OutputPath $explicit -NoOpen
Assert-Result ($path -eq $explicit -and (Test-Path -LiteralPath $explicit)) 'Orca向け明示保存先と親ディレクトリ生成'
Assert-Result (-not (Test-Path -LiteralPath (Join-Path $reportDir 'investigation001.html'))) '明示保存時は設定先へ重複生成しない'

foreach ($kind in @('bug', 'investigation', 'research', 'security', 'proposal')) {
    $path = & $generator -Kind $kind -Title $kind -BodyPath $body -NoOpen
    Assert-Result (Test-Path -LiteralPath $path) "$kind 種別の生成"
}
$mermaidBody = Join-Path $testRoot 'mermaid.md'
"## 図`n``````mermaid`nflowchart LR`n A --> B`n``````" | Set-Content -LiteralPath $mermaidBody -Encoding utf8
$path = & $generator -Kind research -Title '図' -BodyPath $mermaidBody -NoOpen
$mermaidHtml = Get-Content -LiteralPath $path -Raw -Encoding utf8
Assert-Result ($mermaidHtml.Contains('https://cdn.jsdelivr.net/npm/mermaid@11') -and $mermaidHtml.Contains('mermaid-offline')) 'MermaidのみCDNと失敗時の注記を含む'
Write-Host "pass: $script:checks  fail: 0"
Write-Host "検証用成果物: $testRoot"
