# html-report パーサの回帰テスト。
# 修正前の状態で走らせると、既知の不具合が FAIL として並ぶ。
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/ConvertTo-ReportHtml.ps1')

$script:pass = 0
$script:fail = 0

function Test-Case {
    param([string]$Name, [string]$Markdown, [scriptblock]$Check)
    try {
        $html = ConvertTo-ReportHtml -Markdown $Markdown
    } catch {
        Write-Host "FAIL  $Name  -- 例外: $_" -ForegroundColor Red
        $script:fail++
        return
    }
    if (& $Check $html) {
        Write-Host "ok    $Name" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "FAIL  $Name" -ForegroundColor Red
        Write-Host "      出力: $($html -replace "`n", ' ' )" -ForegroundColor DarkGray
        $script:fail++
    }
}

# --- 進捗バー ---
Test-Case '進捗バー: 巨大な数値でも落ちない' "## T`n:::bar x|99999999999999999999" {
    param($h) $h -match 'width:100%'
}
Test-Case '進捗バー: 負値は 0 に丸める' "## T`n:::bar x|-50" {
    param($h) $h -match 'width:0%'
}
Test-Case '進捗バー: 値なしは 0' "## T`n:::bar ラベルのみ" {
    param($h) $h -match 'width:0%'
}
Test-Case '進捗バー: 通常値' "## T`n:::bar x|85" {
    param($h) $h -match 'width:85%'
}

# --- 行内記法 ---
Test-Case 'インラインコード内の * は強調にしない' "## T`nsee ``a*b*c`` here" {
    param($h) $h -match '<code>a\*b\*c</code>' -and $h -notmatch '<code>a<em>'
}
Test-Case 'インラインコード内の ** も素通し' "## T`n``a**b`` and **bold**" {
    param($h) $h -match '<code>a\*\*b</code>' -and $h -match '<strong>bold</strong>'
}
Test-Case 'インラインコード内のバッジ記法は展開しない' "## T`n``[!red x]`` here" {
    param($h) $h -match '<code>\[!red x\]</code>'
}
Test-Case 'コード外のバッジは展開する' "## T`n[!red 重大] です" {
    param($h) $h -match 'tag-red'
}

# --- セクション ---
Test-Case '本文のない ## 見出しも残る' "## 空セクション`n`n## 本文あり`ntext" {
    param($h) $h -match '空セクション' -and $h -match '本文あり'
}

# --- テーブル ---
Test-Case 'セル数不足の行はヘッダー数まで補完' "## T`n| a | b | c |`n|---|---|---|`n| 1 |" {
    param($h) ([regex]::Matches($h, '<td>')).Count -eq 3
}
Test-Case 'セル数超過の行は切り捨てない' "## T`n| a | b |`n|---|---|`n| 1 | 2 | 3 |" {
    param($h) $h -match '<td>3</td>'
}
Test-Case 'エスケープした \| はセル区切りにしない' "## T`n| a | b |`n|---|---|`n| x \| y | z |" {
    param($h) $h -match '<td>x \| y</td>'
}

# --- リスト ---
Test-Case 'ネストしたリストが入れ子になる' "## T`n- 親`n  - 子`n- 親2" {
    param($h) $h -match '<ul>[\s\S]*<li>親[\s\S]*<ul>[\s\S]*<li>子'
}
Test-Case '番号付きと箇条書きが混在したら別リストにする' "## T`n- bullet`n1. number" {
    param($h) $h -match '<ul>' -and $h -match '<ol>'
}

# --- SVG / セキュリティ ---
Test-Case 'SVG 内の script タグを除去する' "## T`n``````svg`n<svg><script>alert(1)</script></svg>`n``````" {
    param($h) $h -notmatch '<script'
}
Test-Case 'SVG 内の onload 属性を除去する' "## T`n``````svg`n<svg onload=`"alert(1)`"></svg>`n``````" {
    param($h) $h -notmatch 'onload'
}
Test-Case 'SVG の正当な要素は残す' "## T`n``````svg`n<svg viewBox=`"0 0 10 10`"><rect fill=`"#fff`"/></svg>`n``````" {
    param($h) $h -match '<rect' -and $h -match 'viewBox'
}
Test-Case 'リンクの javascript: スキームは無効化' "## T`n[x](javascript:alert(1))" {
    param($h) $h -notmatch 'javascript:'
}

# --- 引用 ---
Test-Case '複数行の引用がまとまる' "## T`n> 一行目`n> 二行目" {
    param($h) $h -match '一行目<br>二行目'
}

Write-Host ""
Write-Host "pass: $script:pass  fail: $script:fail" -ForegroundColor $(if ($script:fail) { 'Yellow' } else { 'Green' })
if ($script:fail) { exit 1 }
