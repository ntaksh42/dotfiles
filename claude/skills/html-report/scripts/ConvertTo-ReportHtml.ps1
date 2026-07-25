<#
.SYNOPSIS
  レポート本文の Markdown を HTML へ変換する。

.DESCRIPTION
  New-HtmlReport.ps1 からドットソースで読み込まれる。
  汎用 Markdown パーサではなく、レポート本文に必要な記法だけを扱う。
  対応記法の一覧と書式は references/markdown-syntax.md を参照。

  この範囲に絞っているのは、レポートの見た目を安定させるため。
  想定外の記法は段落として素通しするので、変換に失敗して内容が消えることはない。
#>

# HTML 特殊文字をエスケープする。属性値・本文の双方で使う。
function ConvertTo-HtmlText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

# 行内記法（強調・コード・リンク）を処理する。
# エスケープ済みのテキストに対して呼ぶ前提。
function Convert-InlineMarkup {
    param([string]$Text)

    $result = ConvertTo-HtmlText $Text

    # `コード` — 中身をさらにエスケープしないよう最初に処理する
    $result = [regex]::Replace($result, '`([^`]+)`', '<code>$1</code>')

    # **強調** と *斜体*
    $result = [regex]::Replace($result, '\*\*([^*]+)\*\*', '<strong>$1</strong>')
    $result = [regex]::Replace($result, '(?<!\*)\*([^*]+)\*(?!\*)', '<em>$1</em>')

    # [ラベル](URL) — javascript: 等のスキームは踏ませない
    $result = [regex]::Replace($result, '\[([^\]]+)\]\(([^)]+)\)', {
        param($m)
        $label = $m.Groups[1].Value
        $url = $m.Groups[2].Value
        if ($url -match '^(https?:|mailto:|#|/|\.)') {
            "<a href=`"$url`">$label</a>"
        } else {
            $label
        }
    })

    # 重要度タグ: [!red 重大] のような記法をバッジに変換
    $result = [regex]::Replace($result, '\[!(red|yellow|green|blue|gray)\s+([^\]]+)\]', '<span class="tag tag-$1">$2</span>')

    return $result
}

function ConvertTo-ReportHtml {
    param([string]$Markdown)

    $lines = $Markdown -split "`r?`n"
    $sections = [System.Collections.ArrayList]::new()

    # 現在組み立て中のセクション。## 見出しごとに切り替わる。
    $currentTitle = $null
    $currentBody = [System.Collections.ArrayList]::new()

    function Flush-Section {
        param($Title, $Body, $Target)
        if ($Body.Count -eq 0 -and -not $Title) { return }

        $inner = ($Body -join "`n")
        if (-not $inner.Trim()) { return }

        if ($Title) {
            $safeTitle = Convert-InlineMarkup $Title
            [void]$Target.Add(@"
<div class="section">
  <div class="section-header">$safeTitle</div>
  <div class="section-body content">
$inner
  </div>
</div>
"@)
        } else {
            # 見出しの前に本文がある場合も落とさずに出す
            [void]$Target.Add(@"
<div class="section">
  <div class="section-body content">
$inner
  </div>
</div>
"@)
        }
    }

    $i = 0
    while ($i -lt $lines.Count) {
        $line = $lines[$i]

        # ---- コードフェンス ----
        if ($line -match '^\s*```(\w*)') {
            $lang = $Matches[1]
            $i++
            $buffer = [System.Collections.ArrayList]::new()
            while ($i -lt $lines.Count -and $lines[$i] -notmatch '^\s*```') {
                [void]$buffer.Add($lines[$i])
                $i++
            }
            $i++  # 閉じフェンスを読み飛ばす

            $code = $buffer -join "`n"
            switch ($lang) {
                'mermaid' {
                    # Mermaid は記法をそのまま渡す必要があるので最小限のエスケープに留める
                    [void]$currentBody.Add("<pre class=`"mermaid`">" + (ConvertTo-HtmlText $code) + "</pre>")
                }
                'svg' {
                    # 図として意図的に書かれた SVG はそのまま通す
                    [void]$currentBody.Add("<div class=`"figure`">$code</div>")
                }
                default {
                    $langAttr = if ($lang) { " data-lang=`"$lang`"" } else { '' }
                    [void]$currentBody.Add("<pre$langAttr><code>" + (ConvertTo-HtmlText $code) + "</code></pre>")
                }
            }
            continue
        }

        # ---- 進捗バー :::bar ラベル|値 ----
        if ($line -match '^\s*:::bar\s+(.+)$') {
            $spec = $Matches[1] -split '\|'
            $label = Convert-InlineMarkup $spec[0].Trim()
            $pct = if ($spec.Count -gt 1) { [Math]::Max(0, [Math]::Min(100, [int]($spec[1].Trim() -replace '[^\d]', ''))) } else { 0 }
            [void]$currentBody.Add(@"
<div class="bar-row">
  <div class="bar-label">$label</div>
  <div class="bar-track"><div class="bar-fill" style="width:$pct%"></div></div>
  <div class="bar-value">$pct%</div>
</div>
"@)
            $i++
            continue
        }

        # ---- テーブル ----
        if ($line -match '^\s*\|.*\|\s*$') {
            $rows = [System.Collections.ArrayList]::new()
            while ($i -lt $lines.Count -and $lines[$i] -match '^\s*\|.*\|\s*$') {
                [void]$rows.Add($lines[$i].Trim())
                $i++
            }

            # 区切り行（|---|---|）を除いた実データ
            $dataRows = @($rows | Where-Object { $_ -notmatch '^\s*\|[\s\-:|]+\|\s*$' })
            if ($dataRows.Count -eq 0) { continue }

            # セル内の \| はセル区切りとして扱わない。
            # 一旦プレースホルダへ退避してから分割し、最後にパイプへ戻す。
            function Split-Row {
                param([string]$Row)
                $sentinel = [char]0x0001
                $trimmed = $Row.Trim() -replace '^\|', '' -replace '\|$', ''
                $trimmed = $trimmed.Replace('\|', $sentinel)
                return @($trimmed -split '\|' | ForEach-Object { $_.Trim().Replace($sentinel, '|') })
            }

            $header = Split-Row $dataRows[0]
            $bodyRows = @($dataRows | Select-Object -Skip 1)

            $thead = "<tr>" + (($header | ForEach-Object { "<th>" + (Convert-InlineMarkup $_) + "</th>" }) -join '') + "</tr>"

            $tbodyLines = foreach ($row in $bodyRows) {
                $cells = Split-Row $row
                "<tr>" + (($cells | ForEach-Object { "<td>" + (Convert-InlineMarkup $_) + "</td>" }) -join '') + "</tr>"
            }

            # 長い表は最初の15行だけ見せて残りは折りたたむ。
            # 一覧性を保ちつつ、スクロールで他のセクションが埋もれるのを防ぐ。
            if ($bodyRows.Count -gt 15) {
                $visible = ($tbodyLines | Select-Object -First 15) -join "`n"
                $hidden = ($tbodyLines | Select-Object -Skip 15) -join "`n"
                $rest = $bodyRows.Count - 15
                [void]$currentBody.Add(@"
<table><thead>$thead</thead><tbody>
$visible
</tbody></table>
<details><summary>残り $rest 行を表示</summary>
<table><thead>$thead</thead><tbody>
$hidden
</tbody></table>
</details>
"@)
            } else {
                $tbody = $tbodyLines -join "`n"
                [void]$currentBody.Add("<table><thead>$thead</thead><tbody>`n$tbody`n</tbody></table>")
            }
            continue
        }

        # ---- 見出し ----
        if ($line -match '^##\s+(.+)$') {
            Flush-Section -Title $currentTitle -Body $currentBody -Target $sections
            $currentTitle = $Matches[1].Trim()
            $currentBody = [System.Collections.ArrayList]::new()
            $i++
            continue
        }
        if ($line -match '^###\s+(.+)$') {
            [void]$currentBody.Add("<h3>" + (Convert-InlineMarkup $Matches[1].Trim()) + "</h3>")
            $i++
            continue
        }

        # ---- 引用 ----
        if ($line -match '^\s*>\s?(.*)$') {
            $quote = [System.Collections.ArrayList]::new()
            while ($i -lt $lines.Count -and $lines[$i] -match '^\s*>\s?(.*)$') {
                [void]$quote.Add((Convert-InlineMarkup $Matches[1]))
                $i++
            }
            [void]$currentBody.Add("<blockquote>" + ($quote -join '<br>') + "</blockquote>")
            continue
        }

        # ---- リスト ----
        if ($line -match '^\s*([-*]|\d+\.)\s+(.+)$') {
            $ordered = $Matches[1] -match '^\d'
            $items = [System.Collections.ArrayList]::new()
            while ($i -lt $lines.Count -and $lines[$i] -match '^\s*([-*]|\d+\.)\s+(.+)$') {
                [void]$items.Add("<li>" + (Convert-InlineMarkup $Matches[2]) + "</li>")
                $i++
            }
            $tag = if ($ordered) { 'ol' } else { 'ul' }
            [void]$currentBody.Add("<$tag>`n" + ($items -join "`n") + "`n</$tag>")
            continue
        }

        # ---- 空行 ----
        if (-not $line.Trim()) { $i++; continue }

        # ---- 段落 ----
        # 連続する行はひとつの段落にまとめる
        $para = [System.Collections.ArrayList]::new()
        while ($i -lt $lines.Count -and $lines[$i].Trim() -and
               $lines[$i] -notmatch '^\s*(#{2,3}\s|[-*]\s|\d+\.\s|\||>|```|:::)') {
            [void]$para.Add((Convert-InlineMarkup $lines[$i].Trim()))
            $i++
        }
        if ($para.Count -gt 0) {
            [void]$currentBody.Add("<p>" + ($para -join ' ') + "</p>")
        } else {
            $i++
        }
    }

    Flush-Section -Title $currentTitle -Body $currentBody -Target $sections
    return ($sections -join "`n")
}
