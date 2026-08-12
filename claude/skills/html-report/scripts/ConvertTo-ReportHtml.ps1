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
#
# `コード` の中身は「書いたままの文字列」であってほしいので、最初に退避して
# 他の変換から隔離し、最後に戻す。素朴に順番に置換すると
# `a**b` と **bold** が混ざって <code>a<strong>b</code></strong> のように
# タグの入れ子が壊れる。
function Convert-InlineMarkup {
    param([string]$Text)

    $result = ConvertTo-HtmlText $Text

    # --- コードスパンを退避 ---
    $codeSpans = [System.Collections.ArrayList]::new()
    $result = [regex]::Replace($result, '`([^`]+)`', {
        param($m)
        $idx = $codeSpans.Add($m.Groups[1].Value)
        # 本文に現れない制御文字で囲んだプレースホルダに置き換える
        "$([char]0x0002)$idx$([char]0x0003)"
    })

    # **強調** と *斜体*
    $result = [regex]::Replace($result, '\*\*([^*]+)\*\*', '<strong>$1</strong>')
    $result = [regex]::Replace($result, '(?<!\*)\*([^*]+)\*(?!\*)', '<em>$1</em>')

    # [ラベル](URL) — javascript: 等のスキームは踏ませない。
    # URL 内の括弧を拾えるよう、入れ子を 1 段だけ許す。
    $result = [regex]::Replace($result, '\[([^\]]+)\]\(((?:[^()]|\([^()]*\))*)\)', {
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

    # --- コードスパンを復元 ---
    $result = [regex]::Replace($result, "$([char]0x0002)(\d+)$([char]0x0003)", {
        param($m)
        '<code>' + $codeSpans[[int]$m.Groups[1].Value] + '</code>'
    })

    return $result
}

# SVG から実行可能な要素・属性を取り除く。
#
# 本文はレポート対象のコードやログを引用することがあり、そこに紛れた
# スクリプトをそのままレポートへ通すと、開いただけで実行されてしまう。
# 図として書かれた SVG は通したいので、描画に関係しない部分だけ落とす。
function Remove-SvgScripting {
    param([string]$Svg)

    # <script>...</script> と <foreignObject>...</foreignObject> をブロックごと除去
    $clean = [regex]::Replace($Svg, '(?is)<\s*(script|foreignObject)\b[^>]*>.*?<\s*/\s*\1\s*>', '')
    # 自己終了・閉じ忘れの単独タグも落とす
    $clean = [regex]::Replace($clean, '(?is)<\s*/?\s*(script|foreignObject)\b[^>]*>', '')
    # on* イベントハンドラ属性（onload= など）
    $clean = [regex]::Replace($clean, '(?is)\son[a-z]+\s*=\s*(".*?"|''.*?''|[^\s>]+)', '')
    # href/xlink:href の javascript: スキーム
    $clean = [regex]::Replace($clean, '(?is)((?:xlink:)?href)\s*=\s*(["'']?)\s*javascript:[^"''>]*\2', '')

    return $clean
}

function ConvertTo-ReportHtml {
    param([string]$Markdown)

    # 変換の副産物としてセクション見出しを集める。呼び出し側は
    # $script:ReportSections を読んで目次を組み立てる。
    $script:ReportSections = [System.Collections.ArrayList]::new()

    $lines = $Markdown -split "`r?`n"
    $sections = [System.Collections.ArrayList]::new()

    # 現在組み立て中のセクション。## 見出しごとに切り替わる。
    $currentTitle = $null
    $currentBody = [System.Collections.ArrayList]::new()

    function Flush-Section {
        param($Title, $Body, $Target)
        if ($Body.Count -eq 0 -and -not $Title) { return }

        $inner = ($Body -join "`n")
        # 見出しがあるなら本文が空でもカードは出す。黙って消えると、
        # 「該当なし」のつもりで置いた節が抜け落ちたのか書き忘れたのか分からなくなる。
        if (-not $inner.Trim() -and -not $Title) { return }

        if ($Title) {
            $safeTitle = Convert-InlineMarkup $Title
            # 目次から飛べるようにアンカーを振る。見出し文字列は日本語や
            # 記号を含むので、id には連番だけを使って安定させる。
            $anchor = 'sec-' + ($script:ReportSections.Count + 1)
            [void]$script:ReportSections.Add(@{
                Anchor = $anchor
                # 目次側でもう一度エスケープしないよう、変換済みを渡す
                Title  = $safeTitle
            })
            [void]$Target.Add(@"
<div class="section" id="$anchor">
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
                    # 図として書かれた SVG は描画のため通すが、
                    # 実行可能な部分だけは落としてから埋め込む
                    [void]$currentBody.Add("<div class=`"figure`">" + (Remove-SvgScripting $code) + "</div>")
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
            # 桁数の大きい入力で [int] があふれるので decimal で受けてから丸める。
            # 先頭の - は負値として活かし、それ以外の非数字は捨てる。
            $pct = 0
            if ($spec.Count -gt 1) {
                $raw = $spec[1].Trim()
                $neg = $raw -match '^\s*-'
                $digits = $raw -replace '[^\d]', ''
                if ($digits) {
                    # 桁が大きいと decimal も超えるので、上限より長い桁は
                    # その時点で 100% とみなす
                    if ($digits.Length -gt 18) {
                        $pct = if ($neg) { 0 } else { 100 }
                    } else {
                        $value = [decimal]$digits
                        if ($neg) { $value = -$value }
                        $pct = [int][Math]::Max([decimal]0, [Math]::Min([decimal]100, $value))
                    }
                }
            }
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

            # セル数がヘッダーに満たない行は空セルで埋める。
            # 埋めないと列がずれて、以降の行が別の見出しの下に並んで見える。
            $tbodyLines = foreach ($row in $bodyRows) {
                $cells = @(Split-Row $row)
                while ($cells.Count -lt $header.Count) { $cells += '' }
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
        # インデント幅で入れ子を作る。箇条書きと番号付きが並んだ場合は
        # 別のリストとして切り替える（同じ <ul> に混ぜると番号が消える）。
        if ($line -match '^(\s*)([-*]|\d+\.)\s+(.+)$') {
            # まず連続するリスト行を (深さ, 種別, 本文) として読み取る
            $entries = [System.Collections.ArrayList]::new()
            while ($i -lt $lines.Count -and $lines[$i] -match '^(\s*)([-*]|\d+\.)\s+(.+)$') {
                [void]$entries.Add(@{
                    Indent  = $Matches[1].Replace("`t", '    ').Length
                    Ordered = $Matches[2] -match '^\d'
                    Text    = Convert-InlineMarkup $Matches[3]
                })
                $i++
            }

            # インデント幅は書き手によって 2 / 4 とばらつくので、
            # 幅そのものではなく「出現した幅の順位」を深さとして扱う。
            $levels = @($entries | ForEach-Object { $_.Indent } | Sort-Object -Unique)

            $html = [System.Collections.ArrayList]::new()
            $stack = [System.Collections.ArrayList]::new()   # 開いているリストの種別
            $openItem = [System.Collections.ArrayList]::new() # 各階層で <li> が開いているか

            foreach ($entry in $entries) {
                $depth = [array]::IndexOf($levels, $entry.Indent)
                $tag = if ($entry.Ordered) { 'ol' } else { 'ul' }

                # 浅くなったぶんだけ閉じる
                while ($stack.Count -gt $depth + 1) {
                    $last = $stack.Count - 1
                    if ($openItem[$last]) { [void]$html.Add('</li>') }
                    [void]$html.Add("</$($stack[$last])>")
                    $stack.RemoveAt($last)
                    $openItem.RemoveAt($last)
                }

                if ($stack.Count -eq $depth + 1) {
                    # 同じ深さ。種別が変わったらリストを開き直す
                    $last = $stack.Count - 1
                    if ($stack[$last] -ne $tag) {
                        if ($openItem[$last]) { [void]$html.Add('</li>') }
                        [void]$html.Add("</$($stack[$last])>")
                        [void]$html.Add("<$tag>")
                        $stack[$last] = $tag
                        $openItem[$last] = $false
                    } elseif ($openItem[$last]) {
                        [void]$html.Add('</li>')
                        $openItem[$last] = $false
                    }
                } else {
                    # 深くなった。直前の <li> を開いたまま子リストを入れる
                    [void]$html.Add("<$tag>")
                    [void]$stack.Add($tag)
                    [void]$openItem.Add($false)
                }

                [void]$html.Add("<li>" + $entry.Text)
                $openItem[$stack.Count - 1] = $true
            }

            # 残りをすべて閉じる
            while ($stack.Count -gt 0) {
                $last = $stack.Count - 1
                if ($openItem[$last]) { [void]$html.Add('</li>') }
                [void]$html.Add("</$($stack[$last])>")
                $stack.RemoveAt($last)
                $openItem.RemoveAt($last)
            }

            [void]$currentBody.Add($html -join "`n")
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
