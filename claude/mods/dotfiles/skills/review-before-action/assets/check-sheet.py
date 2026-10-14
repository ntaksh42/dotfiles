#!/usr/bin/env python3
"""レビュー 標準モード — シートの埋め忘れ検査。

  python3 check-sheet.py ./review/<topic>-01.html

sheet-template.html を埋めて作ったシートを、人に見せる前に機械的に検査する。
狙いは「無言で壊れる不備」だけを捕まえること — 人が回答しても agent に届かない、
または下書きが他のシートと衝突する類の欠陥は、画面を見ても気づけない。

検出するもの:
  - TODO / CHANGE-ME の残り (DRAFT_KEY 使い回し、DOC 未設定)
  - QUESTIONS と回答フォームの radio name のズレ (ズレた問いは無言で「お任せ」になる)
  - 問いカード数と回答ブロック数の不一致
  - .thumb が空 (選択肢の絵が欠けている)
  - crypto.randomUUID の混入 (file:// で undefined になる)
  - 相対 URL の外部参照 (self-contained 違反)
  - 問い数が 5 以上 (判断コスト過多)

終了コード 0 = 出題してよい / 1 = 直してから出す。標準ライブラリのみ (python3.8+)。
"""
import argparse
import re
import sys
from pathlib import Path


def find_questions_map(js: str):
    """script 内の QUESTIONS = { q1: "...", ... } から qid を拾う。"""
    m = re.search(r'\bQUESTIONS\s*=\s*\{(.*?)\}', js, re.DOTALL)
    if not m:
        return None
    return re.findall(r'(\w+)\s*:', m.group(1))


def strip_comments(html: str) -> str:
    """HTML コメントを除いた本体。雛形の注意書き自体を検出しないため
    (例: 「crypto.randomUUID は使わない」というコメントを違反として数えない)。"""
    return re.sub(r'<!--.*?-->', '', html, flags=re.DOTALL)


def check(path: Path):
    """(errors, warnings) を返す。errors が空なら出題可。"""
    html = path.read_text(encoding='utf-8')
    live = strip_comments(html)          # 実際に動く部分 (コメントは除く)
    errors, warns = [], []

    # --- 埋め忘れ ---
    if 'CHANGE-ME' in html:
        for var in ('DRAFT_KEY', 'DOC'):
            if re.search(rf'\b{var}\s*=\s*"[^"]*CHANGE-ME', html):
                errors.append(f'{var} が CHANGE-ME のまま。'
                              + ('使い回すと別シートの下書きが復元される' if var == 'DRAFT_KEY'
                                 else '回答 1 行目のラベルが CHANGE-ME になる'))
    n_todo = len(re.findall(r'TODO', html))
    if n_todo:
        errors.append(f'TODO が {n_todo} 箇所残っている (雛形のコメントを埋めるか削る)')

    # --- QUESTIONS と radio name の対応 ---
    qids = find_questions_map(html)
    radio_names = sorted(set(re.findall(r'<input[^>]*type=["\']radio["\'][^>]*name=["\'](\w+)["\']', html)
                             + re.findall(r'<input[^>]*name=["\'](\w+)["\'][^>]*type=["\']radio["\']', html)))
    if qids is None:
        errors.append('script 内に QUESTIONS が見つからない (回答プロンプトが空になる)')
    else:
        only_q = [q for q in qids if q not in radio_names]
        only_r = [r for r in radio_names if r not in qids]
        if only_q:
            errors.append(f'QUESTIONS にあるが radio が無い: {", ".join(only_q)} '
                          '(回答行が常に「未選択 = お任せ」になる)')
        if only_r:
            errors.append(f'radio があるが QUESTIONS に無い: {", ".join(only_r)} '
                          '(人が選んでも回答プロンプトに載らない = 無言で消える)')
        # 見出しの埋め忘れ ("Q1. " だけで中身が無い)
        for qid, text in re.findall(r'(\w+)\s*:\s*"([^"]*)"', re.search(
                r'\bQUESTIONS\s*=\s*\{(.*?)\}', html, re.DOTALL).group(1)):
            if re.fullmatch(r'\s*Q?\d*[.．]?\s*', text):
                errors.append(f'QUESTIONS.{qid} の見出しが空 ("{text}") — 問い文を書く')
        if len(qids) >= 5:
            warns.append(f'問いが {len(qids)} 問。3±1 問に絞る (人の判断コストが本体)')
        if len(qids) == 0:
            warns.append('問いが 0 問。標準モードで問いが無いなら、シートではなく普通の報告で足りる')

    # --- 問いカードと回答ブロックの数 ---
    n_qcard = len(re.findall(r'class=["\'][^"\']*\bqcard\b', html))
    n_qblock = len(re.findall(r'class=["\'][^"\']*\bq\b[^"\']*["\'][^>]*data-qid', html))
    if qids and n_qcard and n_qcard != len(qids):
        warns.append(f'問いカード {n_qcard} 枚に対し QUESTIONS は {len(qids)} 問 (判断材料と答える場所がズレていないか)')
    if n_qblock and qids and n_qblock != len(qids):
        warns.append(f'回答ブロック (.q[data-qid]) {n_qblock} 個に対し QUESTIONS は {len(qids)} 問')

    # --- .thumb が空 ---
    empty_thumbs = 0
    for m in re.finditer(r'<figure[^>]*class=["\'][^"\']*\bthumb\b[^"\']*["\'][^>]*>(.*?)</figure>', html, re.DOTALL):
        body = re.sub(r'<!--.*?-->', '', m.group(1), flags=re.DOTALL).strip()
        if not body:
            empty_thumbs += 1
    if empty_thumbs:
        errors.append(f'.thumb が {empty_thumbs} 個空 — 選択肢の絵が無いと、人は選ぶ瞬間に想像で補うことになる '
                      '(見た目の差が無い選択肢なら .thumb ごと削る)')

    # --- 壊れる書き方 (コメント内の注意書きは違反ではないので live を見る) ---
    if 'crypto.randomUUID' in live:
        errors.append('crypto.randomUUID がある — file:// や社内 http で undefined になり下書きが全滅する')
    for m in re.finditer(r'<(?:script|link|img)[^>]*(?:src|href)=["\'](?!https:|data:|file:|#|mailto:)([^"\']+)["\']', live):
        url = m.group(1)
        if not url.startswith('//'):
            warns.append(f'相対 URL の外部参照: {url} (self-contained 規約違反。data URI か https 絶対 URL にする)')

    # --- 固定形の契約 ---
    if '【レビュー回答】' not in html:
        errors.append('【レビュー回答】の組み立てが無い (references/reply-format.md の固定形が壊れている)')
    if '貼り付ける文章を作る' not in html:
        errors.append('[貼り付ける文章を作る] ボタンが無い (案内文と揃わない)')
    if 'review-sheet-format: v3' not in html:
        warns.append('<!-- review-sheet-format: v3 --> が無い (どの規約で書いたシートかの目印)')

    return errors, warns


def main() -> None:
    ap = argparse.ArgumentParser(
        description='レビュー 標準モードのシートを、人に見せる前に検査する。',
        epilog='終了コード 0 = 出題してよい / 1 = 直してから出す。')
    ap.add_argument('sheet', help='検査するシート HTML (例: ./review/topic-01.html)')
    a = ap.parse_args()

    path = Path(a.sheet)
    if not path.is_file():
        sys.exit(f'check-sheet: シートが見つからない: {path}')

    errors, warns = check(path)
    out = []
    for e in errors:
        out.append(f'  NG  {e}')
    for w in warns:
        out.append(f'  ??  {w}')
    if not out:
        out.append('  OK  埋め忘れなし。preflight (references/preflight.md) に進む')

    msg = f'check-sheet: {path}\n' + '\n'.join(out)
    try:
        print(msg)
    except UnicodeEncodeError:              # Windows の cp932 コンソール対策
        sys.stdout.buffer.write(msg.encode('utf-8', 'replace') + b'\n')
    sys.exit(1 if errors else 0)


if __name__ == '__main__':
    main()
