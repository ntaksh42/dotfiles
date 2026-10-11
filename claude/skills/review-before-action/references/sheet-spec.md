# シートの規約 v3 — 標準モードのシートの書き方

> `v3` は**標準モードのシートの体裁**の版で、シート冒頭の `<!-- review-sheet-format: v3 -->` と対になる。
> `references/reply-format.md` の `0.3.0` は**回答テキストの契約**の版で、別系統。混同しない。

標準モード (UI 配置・設計・方針の 1 案) の HTML は、必ずこの規約で書く。
`assets/sheet-template.html` はこの規約を実装した雛形なので、雛形を埋めるだけなら本文の「骨格」と「問いカード」の節だけ読めば足りる。
雛形を改造する、または雛形を使わず自分で書くときは、末尾の CSS スケルトンを起点にする。

指摘モード・添削モードにはこの規約を適用しない。どちらも原稿そのものを見せるのが定義で、要約したシートに組み直さない。

## この規約の読み方

雛形 (`assets/sheet-template.html`) を埋めるだけなら、**「骨格は固定」と「問いカード」の 2 節だけ**読めば足りる。

| 節 | 何が書いてあるか | いつ読む |
|---|---|---|
| 大原則 | 見て判断に到達するシートという方針 | 最初に 1 回 |
| **骨格は固定** | 上から順に置く 11 の部品 | **毎回** |
| 結論ファースト | 冒頭 3 点セットと禁止事項 | 毎回 |
| 絵の規律 | スクショ・A/B 対比・overlay 注記の描き方 | 絵を描く時 |
| **問いカード** | 自己完結カードの必須要素 | **毎回** |
| 文章の規律 | 段落・用語・畳みの規則 | 毎回 |
| 見た目の規約 | 7 色トークン・書体・幅 (雛形が実装済み) | 雛形を改造する時 |
| 雛形が加える部品 | `#akSheet` / `.mockbtn` / 回答フォーム | 雛形の作者のみ |
| CSS スケルトン | 雛形を使わず自分で書く時の起点 | 雛形を使わない時 |

## 大原則: 読むのではなく、見て判断に到達するシート

承認のシートは、読ませて説得するシートではない。見て判断に到達するシートである。
文章より、構造化された図と表のほうが「見て答えを入力しやすい」。
この規約の各項目は、人の採点でこの原則に沿うと確かめられたものだけを残している。

## 骨格は固定

上から順に、毎回同じ場所に同じものを置く。人が探さずに答えられるようにするため。

1. **キッカー** — `✎ REVIEW` と日付 (Mono、赤)
2. **主張のタイトル** — 内容の要約ではなく言い切り
3. **結論ボックス** — 「結論:」で始まる 3 文以内。ここで読むのをやめても判断に要る情報が揃う形
4. **モックボタン** (動的論点がある時だけ) — `./review/mock/` に置いたモックへの `file://` リンク。結論ボックス直下、全体図の上
5. **用語欄** (`.gl`) — 読者が知らない語だけ 1 行ずつ定義。無ければ欄ごと削除
6. **全体図** — インライン SVG 1 枚。題材の全体像を描き、問いが刺さる場所に赤の ①②③ を打つ。問い 3 つ以上、または h2 節 3 つ以上のシートでは必須 (それ未満は任意)。人の採点で唯一「はっきり」勝った部品なので省かない
7. **短い説明** — 現物スクショや再現モックはここ。変更点は赤の注記で示す
8. **案の対比表** — 2 案以上 × 2 観点以上の判断材料は表 1 枚を標準にする。行 = 案、列 = 観点、セル 1〜2 文。対比表と問いカードの利点/代償が同内容なら、表を畳み (`<details>`) に入れてよい (シートが長くなるのを防ぐ。問いカードだけで答えられることが条件)
9. **問いカード** (`.qcard`) — 3±1 問。書き方は下の節
10. **畳み付録** (`<details>`) — 比較の詳細・落とした案・実測ログ・問いごとの根拠
11. **回答フォーム** — 雛形が実装済み。問いカードの radio と同期する。見た目が違う選択肢には、シート本文と同じ絵を選択肢の直下 (`.thumb`) にも付ける

**問いをシートの先頭に置かない。** 人の採点で「はっきり」否定された唯一の配置がこれで、問いを記憶したまま説明を読ませる形になる。判断への到達性は、問いの位置ではなく全体図と自己完結カードで作る。

## 結論ファースト

冒頭は 3 点セット。キッカー → 主張のタイトル → 結論ボックス。結論は 3 文以内で、1 文も短くする。

冒頭に大きな数字を並べる飾り (stat カードの列) は禁止。判断に要る数値は、問いカードの中に再掲する。

## 絵の規律

- **現物と乖離したモックを描かない。** 既存画面に加えるなら、スクショ埋め込みか DOM 再現で現行 UI を忠実に再現する
- **変更 = 赤系、現状 = 無彩色。** 再現モックの上に赤で差分を描く
- **①②③ の番号注記はスクショの上に赤の overlay で乗せる** (`.shotwrap` 部品)。画像の外の段落に赤文字を書いて画像内の黒いバッジと対応させる形にしない。視線が往復して絵が頭に残らず、大きな画像の中の小さな黒点は視覚ガイドとして機能しない。丸ラベル (`.lbl`) が本文や数字に被るシートでは、ラベルを外して図キャプション側に赤の ①②③ で説明を書く
- **選択肢の対立軸は両方絵にする。** A と B の見た目の違いを `.ab` 部品で並べ、差分に赤丸を打つ。推奨案の挿絵だけ並べて選択肢を文字 1 行にすると、人は想像で補えず全問お任せに倒れる
- **回答フォームの選択肢にも同じ絵を付ける。** 人はシートを読んでからフォームで答える。フォームで絵が消えると、選択肢を選ぶ瞬間に想像で補わせることになる。シート本文の `.ab` / SVG と同じ絵を `.q label` の中の `<figure class="thumb">` にコピーする (新しく描かない)。方針・優先度など見た目の無い選択肢には付けない
- 図には主張型のタイトル (図の中の 1 行目) と「図 N — 何を見るか」のキャプションを付ける。図とキャプションだけの拾い読みでも筋が追える形にする。図はインライン SVG を第一候補にする
- 再往復の 2 枚目以降は、前のシートで撤回した案を取り消し線で残す (何を捨てたかも情報)

## 問いカード (`.qcard`) — 自己完結が条件

カードだけ読めばその場で答えられる形にする。本文へ戻らせない。

- 問い 1 行
- 各選択肢に利点 1 行と代償 1 行。**非推奨の選択肢にも「選ぶ理由 (利点)」を 1 行書く。** 代償しか書かれていない選択肢は実質 1 択で、ゲートとして機能しない
- 判断に要る数値の再掲
- 未選択 = お任せ。推奨案に `.rec` バッジ
- 各問に `file:line` か実行結果の引用を添える (畳みの中で満たしてよい)

## 文章の規律

- 1 段落 1 トピック、2〜4 文
- 読者が知らない内輪語・作業語は、一般語に言い換えるか、冒頭の用語欄 (`.gl`) で 1 行定義してから使う
- 数値の列・時刻・パスは Mono (`.mono` / `td.n`) で桁を揃える
- **本文は判断に最小限、残りは `<details>` に畳む。** 問いごとの根拠も畳んでよい。summary は中身と分量を予告する文言にする (例: 「検討して落とした 4 案と採点表 (表 1 枚)」)。「詳細」「その他」は禁止
- **核心の判断材料は畳まない。** 現物スクショ、選択肢の差分の絵、実測の要点は本文に出す。畳んでよいのは「読みたい人だけ読む」層だけ

## 見た目の規約 (雛形が実装済み)

- **書体**: IBM Plex Sans JP × IBM Plex Mono。Google Fonts の `<link>` は https 絶対 URL なので `file://` でも読める。CDN に届かない環境ではヒラギノ等のシステムフォントに落ちる
- **色は 7 トークンのみ**: `--ink` / `--muted` / `--line` / `--paper` / `--paper-dim` / `--accent` / `--red`
  - **赤 `--red` #DC2626 は「提案・訂正・論点」の専任。** 情報整理だけのシートでも論点は赤にする。シートから赤が消えると、どこが論点かが一目で分からなくなる。飾りや、非推奨選択肢の利点強調には使わない
  - **青 `--accent` #2563EB は導線の専任** (リンク・モックボタン・summary)
  - 残りは無彩色
- **本文幅 760px、基本文字 14.5px。** 見出しは半歩小さく h1 25px / h2 19px。高さは内容なり。縦に間延びする空 div や min-height の水増しを置かない
- **self-contained 必須。** 相対 URL 禁止。画像は data URI か https 絶対 URL。外部 JS を読み込まない。モックへの `file://` リンクは「シートの外へ出る導線」なので合法
- 冒頭コメント `<!-- review-sheet-format: v3 -->` を残す (どの規約で書いたシートかの目印)

## 雛形が CSS スケルトンに加えている部品 (雛形の作者向け)

CSS スケルトンは社内で採択されたシートそのものの写しで、下の部品は含まない。雛形にはこれらを加える。

- **提案領域のラッパ `#akSheet`** — キッカーから畳み付録までを包む。回答フォームはこの外に置く
- **モックボタン `.mockbtn`** — `--accent` 色のボタン。`href` は `./review/mock/<name>.html` への相対パスではなく、シートと同じディレクトリを起点にした `file://` 絶対 URL を書く (相対 URL 禁止の規約に合わせる)
- **回答フォーム** — 問いごとの radio (name = q1, q2, …) + 選択肢ごとの絵 `.thumb` (見た目が違う選択肢のみ。シート本文と同じ絵のコピー。選択中はラベルと同じ淡赤) + 補足 textarea + 選択解除ボタン (お任せに戻す) + 全体へのコメント textarea + [貼り付ける文章を作る] ボタン。出力は `references/reply-format.md` の固定形。下書きは localStorage に自動保存 (キーは `DRAFT_KEY`、シートごとに一意な固定文字列)

## CSS スケルトン (最小テンプレ) — ここから書き始める

```html
<!DOCTYPE html>
<html lang="ja">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<!-- review-sheet-format: v3 -->
<title>{タイトル}</title>
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans+JP:wght@400;500;700&family=IBM+Plex+Mono:wght@400;600&display=swap" rel="stylesheet">
<style>
:root{--ink:#212529;--muted:#64707C;--line:#DEE2E6;--paper:#FFFFFF;--paper-dim:#F6F8FA;--accent:#2563EB;--red:#DC2626}
body{background:var(--paper);color:var(--ink);font-family:'IBM Plex Sans JP','Hiragino Kaku Gothic ProN',sans-serif;font-size:14.5px;line-height:1.9;margin:0;border-top:3px solid var(--red);padding:14px 16px 20px}
main{max-width:760px;margin:0 auto}
.kicker{font-family:'IBM Plex Mono',Menlo,monospace;font-size:12.5px;letter-spacing:.08em;color:var(--red);font-weight:600}
h1{font-size:25px;line-height:1.45;margin:8px 0 12px}
h2{font-size:19px;line-height:1.45;margin:30px 0 8px;padding-bottom:4px;border-bottom:1px solid var(--line)}
p{margin:8px 0}
.concl{border:1px solid var(--line);border-left:3px solid var(--red);border-radius:10px;padding:14px 18px}
.red{color:var(--red)}
.m{color:var(--muted);font-size:12.5px;line-height:1.7}
.mono{font-family:'IBM Plex Mono',Menlo,monospace;font-size:13.5px}
.gl{font-size:12.5px;color:var(--muted);line-height:1.75;border-left:2px solid var(--line);padding-left:10px;margin:8px 0}
figure{margin:14px 0 6px}
figcaption{font-size:12.5px;color:var(--muted);line-height:1.6;padding-top:4px}
table{border-collapse:collapse;width:100%;font-size:13.5px;line-height:1.6;margin:8px 0}
th,td{border-bottom:1px solid var(--line);padding:6px 8px;text-align:left;vertical-align:top}
th{font-size:11.5px;letter-spacing:.06em;color:var(--muted);font-weight:500;white-space:nowrap;border-bottom:1.5px solid var(--ink)}
td.n{font-family:'IBM Plex Mono',Menlo,monospace;font-variant-numeric:tabular-nums;white-space:nowrap;text-align:right}
details{border:1px solid var(--line);border-radius:10px;padding:10px 16px;margin:10px 0}
summary{cursor:pointer;color:var(--accent);font-weight:500;font-size:13.5px}
/* 問いカード (自己完結 — 規約 v3 の答える場所) */
.qcard{border:1px solid var(--line);border-left:3px solid var(--red);border-radius:10px;padding:12px 16px;margin:12px 0}
.qcard .qt{font-weight:700;margin:0 0 6px}
.qcard ul{margin:4px 0;padding-left:1.3em}.qcard li{margin:4px 0}
.rec{font-family:'IBM Plex Mono',Menlo,monospace;font-size:11px;color:var(--red);border:1px solid var(--red);border-radius:4px;padding:0 5px;margin-left:4px;white-space:nowrap}
/* overlay 注記 (赤を画像の上に乗せる部品 — 座標は画像に対する %) */
.shotwrap{position:relative;line-height:0;margin:8px 0 4px}
.shotwrap img{width:100%;border:1px solid var(--line);border-radius:8px;display:block}
.shotwrap .mark{position:absolute;transform:translate(-50%,-50%);width:26px;height:26px;border:2.5px solid var(--red);border-radius:50%;background:rgba(255,255,255,.78);color:var(--red);font:600 13px/21px 'IBM Plex Mono',Menlo,monospace;text-align:center}
.shotwrap .lbl{position:absolute;transform:translateX(-50%);background:var(--red);color:#fff;font:700 11px/1.5 sans-serif;padding:2px 8px;border-radius:4px;white-space:nowrap}
/* A/B 対比 (choice の対立軸を並べる部品) */
.ab{display:grid;grid-template-columns:1fr 1fr;gap:12px}
.ab figure{margin:0}.ab figcaption{font-size:12.5px;color:var(--muted);line-height:1.6;padding-top:4px}
@media (max-width:640px){.ab{grid-template-columns:1fr}}
footer{margin-top:28px;border-top:1px solid var(--line);padding-top:10px}
@media print{summary{color:var(--ink)}details{border:none;padding:0}details[open] summary{display:none}}
</style></head>
<body><main>
<div class="kicker">✎ REVIEW — {YYYY-MM-DD}</div>
<h1>{タイトル — 内容の要約でなく主張}</h1>
<div class="concl"><b>結論:</b> {3 文以内、1 文も短く。何をどこに、なぜ}</div>
<div class="gl"><b>このシートで使う言葉</b>: {読者が知らない語だけ 1 行ずつ定義。無ければこの欄ごと削除}</div>
<figure>{全体図 — 問い 3 つ以上または節 3 つ以上なら必須。インライン SVG で題材の全体像 + 問いの場所に赤の ①②③}<figcaption>図 1 — 何を見るか: {…}</figcaption></figure>
<p>{短い説明 (現物スクショ・モックはここ)。提案する変更・論点は <span class="red">赤の注記</span> で示し、詳細は畳みへ}</p>
<table><tr><th>案</th><th>{観点 1}</th><th>{観点 2}</th></tr><tr><td>A. {案}</td><td>{1〜2 文}</td><td>{1〜2 文}</td></tr><tr><td>B. {案}</td><td>{1〜2 文}</td><td>{1〜2 文}</td></tr></table>
<div class="qcard"><p class="qt">問 1. {問い}</p><ul>
<li><b>A. {案}</b><span class="rec">推奨</span> — 利点: {1 行}。代償: {1 行}。</li>
<li>B. {案} — 利点: {1 行}。代償: {1 行}。</li>
</ul></div>
<details><summary>{中身と分量を予告する見出し}</summary><p class="m">{問いごとの根拠・長い比較・落とした案・実測ログ}</p></details>
</main></body></html>
```

部品の対応表:

| 部品 | 役割 |
|---|---|
| `.kicker` | 冒頭の `✎ REVIEW — 日付` |
| `.concl` | 結論ボックス (左に赤の縦線) |
| `.gl` | 用語欄 |
| `.red` | 本文中の赤い注記 |
| `.m` | 補足の小さい文字 (畳みの中身など) |
| `.mono` / `td.n` | 数値・パス・時刻の等幅 |
| `.qcard` / `.qt` / `.rec` | 問いカード / 問いの 1 行 / 推奨バッジ |
| `.shotwrap` / `.mark` / `.lbl` | スクショの上に乗せる赤丸 ①②③ / 赤い帯ラベル。位置は `style="left:NN%;top:NN%"` |
| `.ab` | A / B の絵を横に並べる格子 (640px 以下で縦積み) |
| `.thumb` | 回答フォームの選択肢の直下に置く絵 (`.q label` の中の `figure`)。シート本文の `.ab` / SVG のコピー。雛形側の部品 |
| `details` / `summary` | 畳み付録 (印刷時は開いた中身だけ残る) |
