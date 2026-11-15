#!/usr/bin/env python3
"""report-to-user — 返信を書く前に、会話で返すかシートにするかを決める。

  python choose-form.py [--question <ユーザーの問い>] [--kind <種類>] [--items N] [--chars N]
                        [--lines N] [--decisions N]

下書きは渡さない。書く予定の中身の見積もりだけを渡す (下書きを書くとトークンを先に使ってしまう)。
  --question   ユーザーの問いの文。一覧・比較・手順などを求める語があり、答えが 2 項目以上 (または未見積もり) ならシートにする
  --kind       answer (既定) / work / review / list / compare / steps / commands / ui / manuscript / report
  --items      会話に並べる予定の項目・指摘・変更点の数
  --chars      結論の 1 文を除いた本文のおよその字数 (空白とコードブロックを除く)
  --lines      結論の 1 文を除いた本文のおよその行数
  --decisions  決めてもらう問いの数

出力は 1 行目が「形: 会話 / 報告シート / 詳細レポート / 比較シート / 原稿ファイル」、2 行目が理由。
終了コードは会話なら 0、それ以外は 10 (シェルで分岐したいとき用)。標準ライブラリのみ。
"""
import argparse
import re
import sys

# hook (reply-check.mjs) の上限は 5 行・300 字・5 項目。見積もりの誤差で差し戻されないよう、会話はこれより狭く取る
CHAT_LINES = 3
CHAT_CHARS = 200
CHAT_ITEMS = 3
CHAT_DECISIONS = 1

SHEET_KINDS = {'list', 'compare', 'steps', 'commands'}
REPORT_WORDS = r'HTML\s*(レポート|に(まとめ|して))|レポート(を|に)?(保存|残し|まとめ)|html\s*report'
LIST_WORDS = r'一覧|比較|手順|コマンド|洗い出|列挙|候補|選択肢|ほかに|他に|何がある|なにがある|どんな.{0,6}(ある|ない)|ネタ|案を|まとめて|教えて.{0,4}(全部|すべて)'


def choose(question='', kind='answer', items=None, chars=0, lines=0, decisions=0):
    """(形, 理由) を返す。items=None は項目数を見積もっていないことを表す。"""
    if kind == 'manuscript':
        return '原稿ファイル', '原稿そのものの依頼。報告シートに変換しない'
    r = re.search(REPORT_WORDS, question or '', flags=re.I)
    if kind == 'report' or r:
        why = f'問いに「{r.group(0)}」がある' if r else '種類が report'
        return '詳細レポート', f'{why}。HTML レポートの保存を頼まれている。references/html-report.md を読む'
    if kind == 'ui':
        return '比較シート', 'UI の配置や画面を見て選ぶ相談。references/comparison-sheet.md を読む'
    if kind in SHEET_KINDS:
        return '報告シート', f'種類が {kind}。長さを見積もらず最初からシートにする'
    m = re.search(LIST_WORDS, question or '')
    # 一覧を求める語は、答えが 1 項目なら効かせない (「他にある？」→「1 つだけある」はシートにしない)
    if m and (items is None or items >= 2):
        return '報告シート', f'問いに「{m.group(0)}」があり、答えが {items if items is not None else "未見積もりの"} 項目。一覧・比較・手順を求める質問は最初からシートにする'
    items = items or 0
    over = []
    if items > CHAT_ITEMS:
        over.append(f'項目 {items} 個 > {CHAT_ITEMS}')
    if chars > CHAT_CHARS:
        over.append(f'{chars} 字 > {CHAT_CHARS}')
    if lines > CHAT_LINES:
        over.append(f'{lines} 行 > {CHAT_LINES}')
    if decisions > CHAT_DECISIONS:
        over.append(f'要判断 {decisions} 問 > {CHAT_DECISIONS}')
    if over:
        return '報告シート', '会話の目安を超える: ' + '、'.join(over)
    reason = f'会話の目安 ({CHAT_LINES} 行・{CHAT_CHARS} 字・{CHAT_ITEMS} 項目) に収まる'
    if m:
        reason += f'。問いに「{m.group(0)}」があるが答えは 1 項目'
    if decisions:
        reason += '。問いは [判断] の形で書く'
    return '会話', reason


def main():
    ap = argparse.ArgumentParser(description='返信を会話で返すかシートにするかを決める。')
    ap.add_argument('--question', default='')
    ap.add_argument('--kind', default='answer',
                    choices=['answer', 'work', 'review', 'list', 'compare', 'steps', 'commands', 'ui', 'manuscript', 'report'])
    ap.add_argument('--items', type=int, default=None)
    for name in ('chars', 'lines', 'decisions'):
        ap.add_argument(f'--{name}', type=int, default=0)
    a = ap.parse_args()
    form, reason = choose(a.question, a.kind, a.items, a.chars, a.lines, a.decisions)
    msg = f'形: {form}\n理由: {reason}'
    if form == '報告シート':
        msg += '\n次: scripts/new-sheet.py でシートを作り、会話には結論 1 文とシートの場所だけを書く'
    try:
        print(msg)
    except UnicodeEncodeError:              # Windows の cp932 コンソール対策
        sys.stdout.buffer.write(msg.encode('utf-8', 'replace') + b'\n')
    sys.exit(0 if form == '会話' else 10)


if __name__ == '__main__':
    main()
