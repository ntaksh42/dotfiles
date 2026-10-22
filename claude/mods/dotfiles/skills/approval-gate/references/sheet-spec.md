# シートの規約 v4 — 標準モードのシートの書き方

> `v4` は**標準モードのシートの体裁**の版で、シート冒頭の `<!-- review-sheet-format: v4 -->` と対になる。
> v3 からの変更: 問いカードと回答フォームを廃止。問いは Claude が [判断] コメントとして Crit で投稿し、シートには案の絵と根拠だけを置く。

標準モード (UI 配置・設計・方針の 1 案) の HTML は、必ずこの規約で書く。`crit preview` で開き、人は Crit のインラインコメントで答える。
`assets/sheet-template.html` はこの規約を実装した雛形なので、雛形を埋めるだけなら本文の「骨格」と「論点の印」の節だけ読めば足りる。
雛形を改造する、または雛形を使わず自分で書くときは、末尾の CSS スケルトンを起点にする。

原稿モードにはこの規約を適用しない。原稿そのものを Crit で開くのが定義で、要約したシートに組み直さない。

## この規約の読み方

| 節 | 何が書いてあるか | いつ読む |
|---|---|---|
| 大原則 | 見て判断に到達するシートという方針 | 最初に 1 回 |
| **骨格は固定** | 上から順に置く 9 の部品 | **毎回** |
| 結論ファースト | 冒頭 3 点セットと禁止事項 | 毎回 |
| 絵の規律 | スクショ・A/B 対比・overlay 注記の描き方 | 絵を描く時 |
| **論点の印** | `#p1` … の要素と [判断] コメントの対応 | **毎回** |
| 文章の規律 | 段落・用語・畳みの規則 | 毎回 |
| 見た目の規約 | 7 色トークン・書体・幅 (雛形が実装済み) | 雛形を改造する時 |
| CSS スケルトン | 雛形を使わず自分で書く時の起点 | 雛形を使わない時 |

## 大原則: 読むのではなく、見て判断に到達するシート

承認のシートは、読ませて説得するシートではない。見て判断に到達するシートである。
文章より、構造化された図と表のほうが「見てコメントしやすい」。
この規約の各項目は、人の採点でこの原則に沿うと確かめられたものだけを残している。

## 骨格は固定

上から順に、毎回同じ場所に同じものを置く。人が探さずに答えられるようにするため。

1. **キッカー** — `✎ REVIEW` と日付 (Mono、赤)
2. **主張のタイトル** — 内容の要約ではなく言い切り
3. **結論ボックス** — 「結論:」で始まる 3 文以内。ここで読むのをやめても判断に要る情報が揃う形
4. **モックボタン** (動的論点がある時だけ) — `./review/mock/` に置いたモックへの `file://` リンク。結論ボックス直下、全体図の上
5. **用語欄** (`.gl`) — 読者が知らない語だけ 1 行ずつ定義。無ければ欄ごと削除
6. **全体図** — インライン SVG 1 枚。題材の全体像を描き、論点の場所に赤の ①②③ を打つ。論点 3 つ以上、または h2 節 3 つ以上のシートでは必須 (それ未満は任意)。人の採点で唯一「はっきり」勝った部品なので省かない
7. **短い説明** — 現物スクショや再現モックはここ。変更点は赤の注記で示す
8. **論点** (`.pt#p1`, `#p2`, …) — 3±1 個。各論点の選択肢の絵。書き方は下の「論点の印」
9. **案の対比表と畳み付録** (`<details>`) — 2 案以上 × 2 観点以上は表 1 枚。比較の詳細・落とした案・実測ログは畳む

**シートに問い文・選択肢の一覧・推奨を書かない。** それは [判断] コメントの役目で、シートにも書くと人は同じ問いを 2 か所で読むことになる。v3 で「問いをシートの先頭に置く」が人の採点で否定されたのと同じ理由で、問いを記憶したまま説明を読ませる形も避ける。

## 結論ファースト

冒頭は 3 点セット。キッカー → 主張のタイトル → 結論ボックス。結論は 3 文以内で、1 文も短くする。

冒頭に大きな数字を並べる飾り (stat カードの列) は禁止。判断に要る数値は [判断] コメントの中に再掲する。

## 絵の規律

- **現物と乖離したモックを描かない。** 既存画面に加えるなら、スクショ埋め込みか DOM 再現で現行 UI を忠実に再現する
- **変更 = 赤系、現状 = 無彩色。** 再現モックの上に赤で差分を描く
- **①②③ の番号注記はスクショの上に赤の overlay で乗せる** (`.shotwrap` 部品)。画像の外の段落に赤文字を書いて画像内の黒いバッジと対応させる形にしない。視線が往復して絵が頭に残らず、大きな画像の中の小さな黒点は視覚ガイドとして機能しない。丸ラベル (`.lbl`) が本文や数字に被るシートでは、ラベルを外して図キャプション側に赤の ①②③ で説明を書く
- **選択肢の対立軸は両方絵にする。** A と B の見た目の違いを `.ab` 部品で並べ、差分に赤丸を打つ。推奨案の挿絵だけ並べて選択肢をコメントの文字 1 行にすると、人は想像で補えずお任せに倒れる。方針・優先度など見た目の無い論点は、絵の代わりに対比表でよい
- 図には主張型のタイトル (図の中の 1 行目) と「図 N — 何を見るか」のキャプションを付ける。図とキャプションだけの拾い読みでも筋が追える形にする。図はインライン SVG を第一候補にする
- 再往復の 2 枚目以降は、前のシートで撤回した案を取り消し線で残す (何を捨てたかも情報)

## 論点の印 — `#p1` と [判断] コメントの対応

- 1 論点 = 1 つの `<section class="pt" id="pN">`。`N` は 1 から振り、全体図の赤 ①②③ と番号を揃える
- 中身は見出し 1 行 (何の違いを見るか。問いの形にしない) + 選択肢 A / B の絵 (`.ab`) + 必要なら 1〜2 文
- [判断] コメントは `selector: "#pN"`, `route: "/preview-content"` でこの要素にピン留めする。人はピンを開くと、コメントと絵を同時に見られる
- id は `#pN` 形式の固定文字列にする。クラスや構造に依存した selector は、シートを直すとずれる
- `check-sheet.py --comments` が、selector がシートに存在するか、論点に [判断] が刺さっているかを検査する

## 文章の規律

- 1 段落 1 トピック、2〜4 文
- 読者が知らない内輪語・作業語は、一般語に言い換えるか、冒頭の用語欄 (`.gl`) で 1 行定義してから使う
- 数値の列・時刻・パスは Mono (`.mono` / `td.n`) で桁を揃える
- **本文は判断に最小限、残りは `<details>` に畳む。** summary は中身と分量を予告する文言にする (例: 「検討して落とした 4 案と採点表 (表 1 枚)」)。「詳細」「その他」は禁止
- **核心の判断材料は畳まない。** 現物スクショ、選択肢の差分の絵、実測の要点は本文に出す。畳んでよいのは「読みたい人だけ読む」層だけ

## 見た目の規約 (雛形が実装済み)

- **書体**: IBM Plex Sans JP × IBM Plex Mono。Google Fonts の `<link>` は https 絶対 URL。CDN に届かない環境ではヒラギノ等のシステムフォントに落ちる
- **色は 7 トークンのみ**: `--ink` / `--muted` / `--line` / `--paper` / `--paper-dim` / `--accent` / `--red`
  - **赤 `--red` #DC2626 は「提案・訂正・論点」の専任。** 情報整理だけのシートでも論点は赤にする。シートから赤が消えると、どこが論点かが一目で分からなくなる。飾りには使わない
  - **青 `--accent` #2563EB は導線の専任** (リンク・モックボタン・summary)
  - 残りは無彩色
- **本文幅 760px、基本文字 14.5px。** 見出しは半歩小さく h1 25px / h2 19px。高さは内容なり。縦に間延びする空 div や min-height の水増しを置かない
- **self-contained 必須。** 相対 URL 禁止。画像は data URI か https 絶対 URL。外部 JS を読み込まない。モックへの `file://` リンクは「シートの外へ出る導線」なので合法。モックボタン `.btn` の `href` はシートと同じディレクトリを起点にした `file://` 絶対 URL
- 冒頭コメント `<!-- review-sheet-format: v4 -->` を残す (どの規約で書いたシートかの目印)

## CSS スケルトン (最小テンプレ) — ここから書き始める

```html
<!DOCTYPE html>
<html lang="ja">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<!-- review-sheet-format: v4 -->
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
/* 論点 ([判断] コメントのピン先) */
.pt{border-left:3px solid var(--red);padding-left:14px;margin:18px 0}
.pt .no{font-family:'IBM Plex Mono',Menlo,monospace;font-weight:600;color:var(--red);margin-right:6px}
/* overlay 注記 (赤を画像の上に乗せる部品 — 座標は画像に対する %) */
.shotwrap{position:relative;line-height:0;margin:8px 0 4px}
.shotwrap img{width:100%;border:1px solid var(--line);border-radius:8px;display:block}
.shotwrap .mark{position:absolute;transform:translate(-50%,-50%);width:26px;height:26px;border:2.5px solid var(--red);border-radius:50%;background:rgba(255,255,255,.78);color:var(--red);font:600 13px/21px 'IBM Plex Mono',Menlo,monospace;text-align:center}
.shotwrap .lbl{position:absolute;transform:translateX(-50%);background:var(--red);color:#fff;font:700 11px/1.5 sans-serif;padding:2px 8px;border-radius:4px;white-space:nowrap}
/* A/B 対比 (選択肢の対立軸を並べる部品) */
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
<figure>{全体図 — インライン SVG で題材の全体像 + 論点の場所に赤の ①②③}<figcaption>図 1 — 何を見るか: {…}</figcaption></figure>
<p>{短い説明 (現物スクショ・モックはここ)。提案する変更は <span class="red">赤の注記</span> で示し、詳細は畳みへ}</p>
<section class="pt" id="p1"><h2><span class="no">①</span>{何の違いを見るか}</h2>
<div class="ab"><figure>{A の絵}<figcaption>A — {…}</figcaption></figure><figure>{B の絵}<figcaption>B — {…}</figcaption></figure></div></section>
<table><tr><th>案</th><th>{観点 1}</th><th>{観点 2}</th></tr><tr><td>A. {案}</td><td>{1〜2 文}</td><td>{1〜2 文}</td></tr><tr><td>B. {案}</td><td>{1〜2 文}</td><td>{1〜2 文}</td></tr></table>
<details><summary>{中身と分量を予告する見出し}</summary><p class="m">{長い比較・落とした案・実測ログ}</p></details>
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
| `.pt#pN` / `.no` | 論点 ([判断] コメントのピン先) / 見出しの赤い番号 |
| `.shotwrap` / `.mark` / `.lbl` | スクショの上に乗せる赤丸 ①②③ / 赤い帯ラベル。位置は `style="left:NN%;top:NN%"` |
| `.ab` | A / B の絵を横に並べる格子 (640px 以下で縦積み) |
| `details` / `summary` | 畳み付録 (印刷時は開いた中身だけ残る) |
