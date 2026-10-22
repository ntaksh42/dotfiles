#!/usr/bin/env python3
"""レビュー 標準モード — シートと [判断] コメント JSON の機械検査。

  python3 check-sheet.py ./review/<topic>-01.html --comments <judgments.json>

人に見せる前に「無言で壊れる不備」だけを捕まえる。画面を見ても気づけない類の欠陥:
  - TODO の残り
  - 問いカード・回答フォームの混入 (問いは [判断] コメントで出す)
  - 相対 URL の外部参照 (self-contained 違反)
  - [判断] の selector がシートに無い (ピンが刺さらない)
  - 論点 (#p1 …) と [判断] の数のズレ、5 件以上
  - [判断] に 推奨 / 根拠 / 未返信時の既定 の書き忘れ

終了コード 0 = 出してよい / 1 = 直してから出す。標準ライブラリのみ (python3.8+)。
"""
import argparse
import json
import re
import sys
from pathlib import Path


def check_sheet(html: str):
    live = re.sub(r'<!--.*?-->', '', html, flags=re.DOTALL)
    errors, warns = [], []
    n_todo = len(re.findall(r'TODO', html))
    if n_todo:
        errors.append(f'TODO が {n_todo} 箇所残っている (雛形のコメントを埋めるか削る)')
    if re.search(r'class=["\'][^"\']*\bqcard\b', live) or re.search(r'<input[^>]*type=["\']radio', live):
        errors.append('問いカード / radio がある — 問いはシートに書かず [判断] コメントで出す')
    for m in re.finditer(r'<(?:script|link|img)[^>]*(?:src|href)=["\'](?!https:|data:|file:|#|mailto:|//)([^"\']+)["\']', live):
        warns.append(f'相対 URL の外部参照: {m.group(1)} (data URI か https 絶対 URL にする)')
    if 'review-sheet-format: v4' not in html:
        warns.append('<!-- review-sheet-format: v4 --> が無い (どの規約で書いたシートかの目印)')
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
                errors.append(f'selector {sel} がシートに無い — ピンが刺さらない')
        elif c.get('scope') != 'review' and '[判断]' in c.get('body', ''):
            errors.append('selector の無い [判断] がある — 論点の要素 (#p1 …) にピン留めする')
    for i, c in enumerate(judgments, 1):
        body = c['body']
        head = body.splitlines()[0][:40]
        for key, why in (('推奨', '推奨'), ('未返信', '未返信時の既定'), ('根拠', '根拠 (file:line か実行結果)')):
            if key not in body:
                errors.append(f'[判断] #{i} 「{head}」に {why} が無い')
        if '利点' not in body:
            warns.append(f'[判断] #{i} 「{head}」に利点が無い (非推奨の選択肢にも利点を書く)')
    pinned = {c['selector'][1:] for c in judgments if str(c.get('selector', '')).startswith('#')}
    unpinned = [p for p in points if p not in pinned]
    if unpinned:
        warns.append(f'[判断] の刺さっていない論点: {", ".join("#" + p for p in unpinned)}')
    return errors, warns


def main() -> None:
    ap = argparse.ArgumentParser(description='標準モードのシートと [判断] コメント JSON を、人に見せる前に検査する。')
    ap.add_argument('sheet', help='シート HTML (例: ./review/topic-01.html)')
    ap.add_argument('--comments', help='crit comment --json に渡す JSON ファイル')
    a = ap.parse_args()

    path = Path(a.sheet)
    if not path.is_file():
        sys.exit(f'check-sheet: シートが見つからない: {path}')
    errors, warns, ids, points = check_sheet(path.read_text(encoding='utf-8'))
    if a.comments:
        try:
            data = json.loads(Path(a.comments).read_text(encoding='utf-8'))
        except (OSError, ValueError) as e:
            sys.exit(f'check-sheet: コメント JSON を読めない: {e}')
        e2, w2 = check_comments(data, ids, points)
        errors += e2
        warns += w2
    else:
        warns.append('--comments 未指定 ([判断] JSON の検査を飛ばした)')

    out = [f'  NG  {e}' for e in errors] + [f'  ??  {w}' for w in warns]
    if not out:
        out.append('  OK  不備なし。preflight (references/preflight.md) に進む')
    msg = f'check-sheet: {path}\n' + '\n'.join(out)
    try:
        print(msg)
    except UnicodeEncodeError:              # Windows の cp932 コンソール対策
        sys.stdout.buffer.write(msg.encode('utf-8', 'replace') + b'\n')
    sys.exit(1 if errors else 0)


if __name__ == '__main__':
    main()
