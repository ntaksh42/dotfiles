#!/usr/bin/env python3
"""report-to-user — 比較シートと [判断] JSON の機械検査。

  python3 check-sheet.py ./review/<topic>.html --comments <judgments.json>

人に見せる前に「無言で壊れる不備」だけを捕まえる。画面を見ても気づけない類の欠陥:
  - TODO の残り
  - 問いカード・回答フォームの混入 (問いは会話の [判断] で出す)
  - 相対 URL の外部参照 (self-contained 違反)
  - [判断] の selector がシートに無い (どの絵の話か分からない)
  - 論点 (#p1 …) と [判断] の数のズレ、5 件以上
  - [判断] に 推奨 / 根拠 の書き忘れ
  - 文字の多すぎ (本文の文章 600 字超、結論 120 字超)
  - 報告シート: 図がある場合の要点の印 (class="key") の欠落、
    文字の多すぎ (本文 600 字超、結論 80 字超、表のセル 60 字超)、畳みが本文より長い

終了コード 0 = 出してよい / 1 = 直してから出す。標準ライブラリのみ (python3.8+)。
"""
import argparse
import html as htmllib
import json
import re
import sys
from pathlib import Path


PROSE_LIMIT = 600
CONCL_LIMIT = 120
REPORT_PROSE_LIMIT = 600
REPORT_CONCL_LIMIT = 80
REPORT_CELL_LIMIT = 60


def visible_len(fragment: str) -> int:
    text = htmllib.unescape(re.sub(r'<[^>]+>', '', fragment))
    return len(re.sub(r'\s+', '', text))


def prose_length(live: str):
    """本文の文章 (見出し・結論・段落・キャプション・表) の文字数。SVG と畳みの中は数えない。"""
    body = re.sub(r'<(svg|details|style)\b.*?</\1>', '', live, flags=re.DOTALL)
    parts = re.findall(r'<(h1|h2|p|figcaption|td|th|li)\b[^>]*>(.*?)</\1>', body, flags=re.DOTALL)
    concl = re.search(r'<div class=["\']concl["\'][^>]*>(.*?)</div>', body, flags=re.DOTALL)
    concl_len = visible_len(concl.group(1)) if concl else 0
    gl = sum(visible_len(t) for t in re.findall(r'<div class=["\']gl["\'][^>]*>(.*?)</div>', body, flags=re.DOTALL))
    return sum(visible_len(t) for _, t in parts) + concl_len + gl, concl_len


def check_sheet(html: str):
    live = re.sub(r'<!--.*?-->', '', html, flags=re.DOTALL)
    errors, warns = [], []
    n_todo = len(re.findall(r'TODO', html))
    if n_todo:
        errors.append(f'TODO が {n_todo} 箇所残っている (雛形のコメントを埋めるか削る)')
    if re.search(r'class=["\'][^"\']*\bqcard\b', live) or re.search(r'<input[^>]*type=["\']radio', live):
        errors.append('問いカード / radio がある — 問いはシートに書かず会話の [判断] で出す')
    for m in re.finditer(r'<(?:script|link|img)[^>]*(?:src|href)=["\'](?!https:|data:|file:|#|mailto:|//)([^"\']+)["\']', live):
        warns.append(f'相対 URL の外部参照: {m.group(1)} (data URI か https 絶対 URL にする)')
    is_report = '<!-- report-sheet -->' in html
    if not is_report and 'review-sheet-format: v5' not in html:
        warns.append('<!-- review-sheet-format: v5 --> が無い (どの規約で書いたシートかの目印)')
    total, concl = prose_length(live)
    if is_report:
        if '<svg' in live and not re.search(r'class=["\'][^"\']*\bkey\b', live):
            warns.append('要点の印 (class="key") が無い — 図の中で要点の要素だけを赤くする')
        if total > REPORT_PROSE_LIMIT:
            warns.append(f'本文の文章が {total} 字 (目安 {REPORT_PROSE_LIMIT} 字以内)。説明は図のラベルへ移すか、項目を絞る。判断や行動に要る項目は畳まない')
        folded = sum(visible_len(t) for t in re.findall(r'<details\b[^>]*>(.*?)</details>', live, flags=re.DOTALL))
        if folded > total:
            warns.append(f'畳みの中 ({folded} 字) が本文 ({total} 字) より長い。読み手が判断や行動に使う項目が <details> に入っていないか見直す')
        if concl > REPORT_CONCL_LIMIT:
            warns.append(f'結論が {concl} 字 (目安 {REPORT_CONCL_LIMIT} 字以内・1 文)')
        body = re.sub(r'<(svg|details)\b.*?</\1>', '', live, flags=re.DOTALL)
        long_cells = [n for n in (visible_len(t) for t in re.findall(r'<td\b[^>]*>(.*?)</td>', body, flags=re.DOTALL)) if n > REPORT_CELL_LIMIT]
        if long_cells:
            warns.append(f'表のセル {len(long_cells)} 個が {REPORT_CELL_LIMIT} 字超 (最長 {max(long_cells)} 字)。文でなく句で書く')
    if not is_report and total > PROSE_LIMIT:
        warns.append(f'本文の文章が {total} 字 (目安 {PROSE_LIMIT} 字以内)。絵で分かる説明から削り、判断外の決定は <details> へ')
    if not is_report and concl > CONCL_LIMIT:
        warns.append(f'結論が {concl} 字 (目安 {CONCL_LIMIT} 字以内・2 文まで)')
    ids = set(re.findall(r'\bid=["\']([^"\']+)["\']', live))
    points = sorted(i for i in ids if re.fullmatch(r'p\d+', i))
    return errors, warns, ids, points


def check_comments(data, ids, points):
    errors, warns = [], []
    judgments = [c for c in data if '[判断]' in c.get('body', '')]
    if len(judgments) >= 5:
        warns.append(f'[判断] が {len(judgments)} 件。3±1 件に絞る (人の判断コストが本体)')
    for c in data:
        sel = c.get('selector')
        if sel:
            m = re.fullmatch(r'#([\w-]+)', sel)
            if not m:
                warns.append(f'selector {sel} は id 指定でない (シートを直すとずれやすい。#p1 形式にする)')
            elif m.group(1) not in ids:
                errors.append(f'selector {sel} がシートに無い — どの絵の話か分からない')
        elif '[判断]' in c.get('body', ''):
            errors.append('selector の無い [判断] がある — 指す論点の要素 (#p1 …) を selector に書く')
    for i, c in enumerate(judgments, 1):
        body = c['body']
        head = body.splitlines()[0][:40]
        for key, why in (('推奨', '推奨'), ('根拠', '根拠 (file:line か実行結果)')):
            if key not in body:
                errors.append(f'[判断] #{i} 「{head}」に {why} が無い')
    pinned = {c['selector'][1:] for c in judgments if str(c.get('selector', '')).startswith('#')}
    unpinned = [p for p in points if p not in pinned]
    if unpinned:
        warns.append(f'[判断] の無い論点: {", ".join("#" + p for p in unpinned)}')
    return errors, warns


def main() -> None:
    ap = argparse.ArgumentParser(description='比較シートと [判断] JSON を、人に見せる前に検査する。')
    ap.add_argument('sheet', help='シート HTML (例: ./review/topic.html)')
    ap.add_argument('--comments', help='[判断] の JSON ファイル ([{"selector": "#p1", "body": "[判断] …"}])')
    a = ap.parse_args()

    path = Path(a.sheet)
    if not path.is_file():
        sys.exit(f'check-sheet: シートが見つからない: {path}')
    errors, warns, ids, points = check_sheet(path.read_text(encoding='utf-8'))
    if a.comments:
        try:
            data = json.loads(Path(a.comments).read_text(encoding='utf-8'))
        except (OSError, ValueError) as e:
            sys.exit(f'check-sheet: [判断] JSON を読めない: {e}')
        e2, w2 = check_comments(data, ids, points)
        errors += e2
        warns += w2
    else:
        warns.append('--comments 未指定 ([判断] JSON の検査を飛ばした)')

    out = [f'  NG  {e}' for e in errors] + [f'  ??  {w}' for w in warns]
    if not out:
        out.append('  OK  不備なし。比較シートなら試問 (references/preflight.md) に進む')
    msg = f'check-sheet: {path}\n' + '\n'.join(out)
    try:
        print(msg)
    except UnicodeEncodeError:              # Windows の cp932 コンソール対策
        sys.stdout.buffer.write(msg.encode('utf-8', 'replace') + b'\n')
    sys.exit(1 if errors else 0)


if __name__ == '__main__':
    main()
