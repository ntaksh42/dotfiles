#!/usr/bin/env python3
"""report-to-user — Markdown から報告シートの HTML を作り、検査して場所を出す。

  python new-sheet.py <本文.md | -> [--name <英数字>] [--out <path>] [--meta <文字列>] [--save]

本文は「-」で標準入力から読める (Bash の heredoc で 1 回の呼び出しで済む)。書式は references/sheet-input.md。

形と保存先は呼び出し側が選ばず、この生成器が本文から決める:
  - 形: 本文の文章が 800 字以内なら「シート」、超えたら「詳細」(要判断・優先の帯、長い表の畳み、字数の上限なし)。choose_layout()
  - 種別: タイトルと見出しの語から review / bug / security / proposal / research / investigation を決める。infer_kind()
  - 保存先: 詳細と --save は output-config.toml の保存先へ連番で残す。シートは ORCA_CHAT_SCRATCH_DIR か
    一時ディレクトリの report-sheets/ に置く。Orca では残すものも scratch に写しを置いて会話に貼れるようにする。
    --out を渡すとそこだけに書く。
最後に assets/check-sheet.py の検査をかけ、NG があれば終了コード 1。標準ライブラリのみ (python3.8+)。
"""
import argparse
import datetime
import hashlib
import html
import importlib.util
import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import urllib.parse
from functools import lru_cache
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent.parent
TEMPLATE = SKILL_DIR / 'templates' / 'sheet.html'
CHECKER = SKILL_DIR / 'assets' / 'check-sheet.py'
CONFIG = SKILL_DIR / 'output-config.toml'
FOLD_ROWS = 6        # 優先の行があり、項目がこの数以上なら、優先以外の行を畳む
TABLE_FOLD = 15      # 自由な節の表は、データ行がこの数を超えたら残りを畳む
STATES = {'要判断': 'ask', '要対応': 'act', '未完了': 'act', '対応不要': ''}
NEXT_SLOT = '<!--next-slot-->'

# 種別: (表示名, 既定のサブディレクトリ, 既定の接頭辞)。output-config.toml で上書きできる
KINDS = {
    'review': ('レビュー', 'reviews', 'PR'),
    'bug': ('不具合', 'bugs', 'bug'),
    'investigation': ('調査', 'investigations', 'investigation'),
    'research': ('技術調査', 'research', 'research'),
    'security': ('セキュリティ', 'security', 'security'),
    'proposal': ('提案', 'proposals', 'proposal'),
}
# 上から順に見て、最初に当たった種別にする。どれにも当たらなければ investigation
KIND_RULES = [
    ('security', r'セキュリティ|脆弱|CVE|XSS|CSRF|インジェクション|権限昇格|秘密情報|認可'),
    ('review', r'レビュー|PR\s*#?\d|プルリク|Pull Request|差分'),
    ('bug', r'不具合|バグ|障害|クラッシュ|落ちる|失敗する|再現|根本原因|エラー'),
    ('proposal', r'提案|改善案|設計案|方針|計画|移行|統合|作り直'),
    ('research', r'比較|選定|技術調査|候補|ライブラリ|ベンチマーク'),
]


class InputError(Exception):
    pass


# ---- 行内記法 ---------------------------------------------------------------

SAFE_URL = re.compile(r'^(https?:|mailto:|file:///|#|/|\.)', re.I)
INLINE = re.compile(r'`([^`]+)`|\*\*(.+?)\*\*|(?<![*\w])\*([^*\s][^*]*?)\*(?![*\w])'
                    r'|\[!(red|yellow|green|blue|gray)\s+([^\]]+)\]|\[([^\]]+)\]\(((?:[^()\s]|\([^()]*\))+)\)')


def inline(text: str) -> str:
    """1 行分の Markdown を HTML にする: `code`、**太字**、*斜体*、[!red 札]、[文字](URL)。それ以外はエスケープする。"""
    out, pos = [], 0
    for m in INLINE.finditer(text):
        out.append(html.escape(text[pos:m.start()], quote=False))
        code, bold, em, color, badge, label, url = m.groups()
        if code is not None:
            out.append(source_link(code) or f'<code>{html.escape(code, quote=False)}</code>')
        elif bold is not None:
            out.append(f'<b>{inline(bold)}</b>')
        elif em is not None:
            out.append(f'<em>{inline(em)}</em>')
        elif color is not None:
            out.append(f'<span class="tag tag-{color}">{html.escape(badge, quote=False)}</span>')
        elif SAFE_URL.match(url):
            out.append(f'<a href="{html.escape(url)}">{inline(label)}</a>')
        else:  # javascript: などは踏ませず、文字だけ残す
            out.append(inline(label))
        pos = m.end()
    out.append(html.escape(text[pos:], quote=False))
    return ''.join(out)


@lru_cache(maxsize=1)
def repo_root() -> Path:
    try:
        top = subprocess.run(['git', 'rev-parse', '--show-toplevel'], capture_output=True, text=True, timeout=5)
        if top.returncode == 0 and top.stdout.strip():
            return Path(top.stdout.strip())
    except (OSError, subprocess.SubprocessError):
        pass
    return Path.cwd()


SOURCE_RE = re.compile(r'((?:[A-Za-z]:)?[\w.~/\-]*[\w-]\.\w+):(\d+)(?:-\d+)?')


def source_link(token: str):
    """`path:line` が実在するファイルを指すなら、エディタの該当行を開くリンクにする。そうでなければ None。"""
    m = SOURCE_RE.fullmatch(token.strip())
    if not m:
        return None
    path = Path(os.path.expanduser(m.group(1)))
    if not path.is_absolute():
        path = repo_root() / path
    if not path.is_file():
        return None
    uri = 'vscode://file/' + urllib.parse.quote(path.resolve().as_posix(), safe='/:') + f':{m.group(2)}'
    return (f'<a class="src" href="{html.escape(uri)}" title="エディタで開く">'
            f'<code>{html.escape(token.strip(), quote=False)}</code></a>')


def mark_sources(text: str) -> str:
    """根拠の行の素の file:line をコード表記で包み、inline() でリンクにできるようにする。リンクとコードの中は触らない。"""
    parts = re.split(r'(`[^`]+`|\[[^\]]+\]\([^)]*\))', text)
    for i in range(0, len(parts), 2):
        parts[i] = re.sub(r'(?<![\w/.:\-])' + SOURCE_RE.pattern + r'(?![\w/])',
                          lambda m: f'`{m.group(0)}`', parts[i])
    return ''.join(parts)


def clean_svg(svg: str) -> str:
    """SVG から実行される部分 (script、foreignObject、on* 属性、javascript: の href) を落とす。"""
    svg = re.sub(r'(?is)<\s*(script|foreignObject)\b[^>]*>.*?<\s*/\s*\1\s*>', '', svg)
    svg = re.sub(r'(?is)<\s*/?\s*(script|foreignObject)\b[^>]*>', '', svg)
    svg = re.sub(r'(?is)\son[a-z]+\s*=\s*(".*?"|\'.*?\'|[^\s>]+)', '', svg)
    return re.sub(r'(?is)((?:xlink:)?href)\s*=\s*(["\']?)\s*javascript:[^"\'>]*\2', '', svg)


def fence_html(lang: str, code: str, figure_wrap=True) -> str:
    if lang == 'svg':
        svg = clean_svg(code)
        return f'<div class="figure">{svg}</div>' if figure_wrap else svg
    if lang == 'mermaid':
        return f'<pre class="mermaid">{html.escape(code, quote=False)}</pre>'
    if lang == 'diff':
        return diff_html(code)
    attr = f' data-lang="{html.escape(lang)}"' if lang else ''
    return f'<pre{attr}><code>{html.escape(code, quote=False)}</code></pre>'


HUNK_RE = re.compile(r'^@@\s*(?:-(\d+)(?:,\d+)?\s+\+(\d+)(?:,\d+)?|(.+?)(?::(\d+))?)\s*@@(.*)$')


def diff_html(code: str) -> str:
    """差分を行ごとに色分けする。「>> 指摘」の行は直前の行に付く注記として行の下に出す ([優先] などの札も付けられる)。

    見出しが `@@ -a,b +c,d @@` か `@@ <path>:<行> @@` なら、行番号を左に出す (<path>:<行> は根拠と同じくエディタへのリンク)。
    注記の付いた行は、札の色で塗って指している行を示す。
    """
    rows, old, new = [], None, None
    target = None  # 直前のコード行の rows での位置。注記が付いたら塗る
    for line in code.split('\n'):
        note = re.match(r'^>>\s*(?:\[([^\]]+)\]\s*)?(.*)$', line)
        if note:
            label, text = note.groups()
            kind = {'優先': ' priority', '推測': ' guess', '未検証': ' unverified'}.get(label or '', '')
            tag = f'<span class="tag{kind}">{html.escape(label)}</span> ' if label else ''
            if target is not None:
                rows[target] = rows[target].replace('<div class="', f'<div class="d-target{kind} ', 1)
            rows.append(f'<div class="d-note{kind}">{tag}{inline(text)}</div>')
            continue
        hunk = HUNK_RE.match(line)
        if hunk:
            a, c, path, at, rest = hunk.groups()
            old, new = (int(a), int(c)) if c else (None, int(at) if at else None)
            head = (source_link(f'{path.strip()}:{at}') if path and at else None) or html.escape(line, quote=False)
            if path and at and head.startswith('<a'):
                head = f'@@ {head} @@{html.escape(rest, quote=False)}'
            rows.append(f'<div class="d-hunk">{head}</div>')
            target = None
            continue
        if line.startswith('\\') and old is not None:  # 「\ No newline at end of file」は行を数えない
            rows.append(f'<div class="d-hunk"><span class="ln"></span><span class="tx">{html.escape(line, quote=False)}</span></div>')
            continue
        excerpt = new is not None and old is None  # @@ path:行 @@ の抜粋: 先頭の記号に関係なく全行が 1 行
        cls = 'd-ctx' if excerpt else 'd-add' if line.startswith('+') else 'd-del' if line.startswith('-') else 'd-ctx'
        num = ''
        if excerpt:
            num, new = str(new), new + 1
        elif new is not None:
            if cls == 'd-del':
                num, old = (str(old) if old is not None else ''), (old + 1 if old is not None else None)
            else:
                num, new = str(new), new + 1
                old = old + 1 if old is not None and cls == 'd-ctx' else old
        target = len(rows)
        rows.append(f'<div class="{cls}"><span class="ln">{num}</span><span class="tx">{html.escape(line, quote=False) or " "}</span></div>')
    numbered = ' numbered' if any('<span class="ln">' in r and '<span class="ln"></span>' not in r for r in rows) else ''
    return f'<pre class="diff{numbered}"><code>' + ''.join(rows) + '</code></pre>'


# ---- 自由な節の本文 (段落・小見出し・リスト・表・コード・図・引用・横棒) ----------

LIST_RE = re.compile(r'^(\s*)([-*]|\d+\.)\s+(.+)$')
BLOCK_START = re.compile(r'^\s*(#{2,3}\s|[-*]\s|\d+\.\s|\||>|```|:::)')


def split_row(row: str):
    cells = re.sub(r'^\||\|$', '', row.strip()).replace('\\|', '\x01').split('|')
    return [c.strip().replace('\x01', '|') for c in cells]


def render_table(rows):
    data = [r for r in rows if not re.fullmatch(r'\s*\|[\s\-:|]+\|\s*', r)]
    if not data:
        return ''
    header, body = split_row(data[0]), [split_row(r) for r in data[1:]]
    thead = '<tr>' + ''.join(f'<th>{inline(c)}</th>' for c in header) + '</tr>'
    trs = []
    for cells in body:
        cells += [''] * (len(header) - len(cells))  # 足りないセルを埋めて列をずらさない
        trs.append('<tr>' + ''.join(f'<td>{inline(c)}</td>' for c in cells) + '</tr>')

    def table(part):
        return f'<table><thead>{thead}</thead><tbody>\n' + '\n'.join(part) + '\n</tbody></table>'
    if len(trs) <= TABLE_FOLD:
        return table(trs)
    return (table(trs[:TABLE_FOLD]) + f'\n<details class="rest"><summary>残り {len(trs) - TABLE_FOLD} 行を表示</summary>\n'
            + table(trs[TABLE_FOLD:]) + '\n</details>')


def render_list(entries):
    """(字下げ幅, 番号付きか, 本文) の列から入れ子のリストを作る。字下げは幅でなく出現した幅の順位を深さにする。"""
    levels = sorted({e[0] for e in entries})
    out, stack, open_li = [], [], []
    for indent, ordered, text in entries:
        depth, tag = levels.index(indent), 'ol' if ordered else 'ul'
        while len(stack) > depth + 1:
            if open_li.pop():
                out.append('</li>')
            out.append(f'</{stack.pop()}>')
        if len(stack) == depth + 1:
            if open_li[-1]:
                out.append('</li>')
                open_li[-1] = False
            if stack[-1] != tag:  # 箇条書きと番号付きが隣り合ったら別のリストにする
                out.append(f'</{stack[-1]}><{tag}>')
                stack[-1] = tag
        else:
            out.append(f'<{tag}>')
            stack.append(tag)
            open_li.append(False)
        out.append(f'<li>{inline(text)}')
        open_li[-1] = True
    while stack:
        if open_li.pop():
            out.append('</li>')
        out.append(f'</{stack.pop()}>')
    return ''.join(out)


def bar_html(spec: str):
    label, _, raw = spec.partition('|')
    digits = re.sub(r'\D', '', raw)
    pct = 0 if raw.strip().startswith('-') or not digits else min(100, int(digits[:4]))
    return (f'<div class="bar-row"><div class="bar-label">{inline(label.strip())}</div>'
            f'<div class="bar-track"><div class="bar-fill" style="width:{pct}%"></div></div>'
            f'<div class="bar-value">{pct}%</div></div>')


def render_blocks(lines):
    out, i, n = [], 0, len(lines)
    while i < n:
        line = lines[i]
        m = re.match(r'^\s*```(\w*)', line)
        if m:
            buf, i = [], i + 1
            while i < n and not re.match(r'^\s*```', lines[i]):
                buf.append(lines[i])
                i += 1
            out.append(fence_html(m.group(1), '\n'.join(buf)))
            i += 1
            continue
        m = re.match(r'^\s*:::bar\s+(.+)$', line)
        if m:
            out.append(bar_html(m.group(1)))
            i += 1
            continue
        if re.match(r'^\s*\|.*\|\s*$', line):
            rows = []
            while i < n and re.match(r'^\s*\|.*\|\s*$', lines[i]):
                rows.append(lines[i])
                i += 1
            out.append(render_table(rows))
            continue
        m = re.match(r'^###\s+(.+)$', line)
        if m:
            out.append(f'<h3>{inline(m.group(1).strip())}</h3>')
            i += 1
            continue
        if re.match(r'^\s*>', line):
            quote = []
            while i < n and re.match(r'^\s*>', lines[i]):
                quote.append(inline(re.sub(r'^\s*>\s?', '', lines[i])))
                i += 1
            out.append('<blockquote>' + '<br>'.join(quote) + '</blockquote>')
            continue
        if LIST_RE.match(line):
            entries = []
            while i < n and LIST_RE.match(lines[i]):
                lm = LIST_RE.match(lines[i])
                entries.append((len(lm.group(1).replace('\t', '    ')), lm.group(2)[0].isdigit(), lm.group(3)))
                i += 1
            out.append(render_list(entries))
            continue
        if not line.strip():
            i += 1
            continue
        para = []
        while i < n and lines[i].strip() and not BLOCK_START.match(lines[i]):
            para.append(inline(lines[i].strip()))
            i += 1
        if para:
            out.append('<p>' + ' '.join(para) + '</p>')
        else:
            i += 1
    return '\n'.join(out)


# ---- 決まった節 --------------------------------------------------------------

def split_sections(src: str):
    """フェンス (```) の中を壊さずに、## 見出しで区切る。返り値は (見出し, 行の配列) の列。"""
    sections, cur, fence = [], ('', []), False
    for line in src.replace('\r\n', '\n').split('\n'):
        if line.lstrip().startswith('```'):
            fence = not fence
        if not fence and line.startswith('## '):
            sections.append(cur)
            cur = (line[3:].strip(), [])
        else:
            cur[1].append(line)
    sections.append(cur)
    return sections


def bullets(lines):
    """「- 」で始まる項目を集める。続く字下げ行は直前の項目の続き行として持つ。"""
    items = []
    for line in lines:
        if re.match(r'^\s*[-*]\s+', line) and not line.startswith((' ', '\t')):
            items.append([re.sub(r'^\s*[-*]\s+', '', line).strip()])
        elif line.strip() and items and line.startswith((' ', '\t')):
            items[-1].append(line.strip())
        elif line.strip():
            raise InputError(f'箇条書きでない行: {line.strip()[:40]}')
    return items


def parse_title(lines):
    title_line = next((l for l in lines if l.startswith('# ')), None)
    if not title_line:
        raise InputError('1 行目に「# <状態の語> | <結論>」が無い')
    m = re.match(r'#\s*(.+?)\s*\|\s*(.+)$', title_line)
    if not m:
        raise InputError('タイトルは「# <状態の語> | <結論>」の形にする')
    state, concl = m.group(1).strip(), m.group(2).strip()
    key = re.sub(r'\s*\d+\s*件$', '', state)
    if key not in STATES:
        raise InputError(f'状態の語「{state}」は 対応不要 / 要判断 n 件 / 要対応 / 未完了 のどれかにする')
    return title_line, state, key, concl


def render_head(lines):
    title_line, state, key, concl = parse_title(lines)
    cls = ' '.join(c for c in ('state', STATES[key]) if c)
    parts = [f'<h1><span class="{cls}">{html.escape(state)}</span>{inline(concl)}</h1>']
    rest = lines[lines.index(title_line) + 1:]
    sub, nxt, pts, figs, fence = [], None, [], [], None
    for line in rest:
        if fence is not None:
            if line.lstrip().startswith('```'):
                figs.append(fence_html(fence[0], '\n'.join(fence[1]), figure_wrap=False))
                fence = None
            else:
                fence[1].append(line)
        elif line.lstrip().startswith('```'):
            fence = (line.strip()[3:].strip() or 'svg', [])
        elif re.match(r'^次\s*[:：]', line):
            nxt = re.sub(r'^次\s*[:：]\s*', '', line)
        elif re.match(r'^[-*]\s+', line):
            pts.append(re.sub(r'^[-*]\s+', '', line))
        elif line.strip():
            sub.append(line.strip())
    if sub:
        parts.append(f'<p class="sub">{inline(" ".join(sub))}</p>')
    if nxt:
        parts.append(f'<div class="next"><b>次にすること</b><span>{inline(nxt)}</span></div>')
    else:
        parts.append(NEXT_SLOT)  # 要判断があれば render_body() が「下の n 問に答える」を入れる
    parts += figs
    if pts:
        parts.append('<ul class="points">' + ''.join(f'<li>{inline(p)}</li>' for p in pts) + '</ul>')
    return parts, concl


def render_decision(title, lines):
    rows, kinds = [], []
    for line in lines:
        m = re.match(r'^(推奨|他案)\s*[:：]\s*(.+)$', line.strip())
        if m:
            cls = 'rec' if m.group(1) == '推奨' else 'alt'
            kinds.append(cls)
            # 案の名前 (「 — 」の前) で返答の文を作り、ボタンでコピーさせる。答えは会話に貼って受ける
            name = re.split(r'\s+[—–-]{1,2}\s+', m.group(2), maxsplit=1)[0].replace('`', '').replace('**', '').strip()
            question = re.sub(r'^要判断\s*[:：]\s*', '', title)
            reply = f'要判断「{question}」は「{name}」で進めて'
            btn = f'<button type="button" class="copy reply" data-copy="{html.escape(reply)}">この案で返答をコピー</button>'
            # data-q / data-name は、複数の要判断の答えをまとめてコピーするボタン (SHEET_JS) が読む
            rows.append(f'<div class="choice {cls}" data-q="{html.escape(question)}" data-name="{html.escape(name)}">'
                        f'<b>{m.group(1)}</b><p>{inline(m.group(2))}</p>{btn}</div>')
        elif line.strip():
            raise InputError(f'要判断の中は「推奨:」「他案:」の行だけ: {line.strip()[:40]}')
    if not kinds or kinds[0] != 'rec':
        raise InputError(f'要判断「{title}」の最初の行は「推奨:」にする')
    return f'<section class="decision"><h3>{inline(title)}</h3>' + ''.join(rows) + '</section>'


def plain(text: str) -> str:
    """行内記法の印 (**、札、リンク) を外した素の文。鍵や依頼文に使う。コード表記の ` は残す。"""
    text = re.sub(r'\[!(?:red|yellow|green|blue|gray)\s+([^\]]+)\]', r'\1', text)
    text = re.sub(r'\[([^\]]+)\]\([^)]*\)', r'\1', text)
    return re.sub(r'\s+', ' ', text.replace('**', '')).strip()


def item_key(name: str, seen: dict) -> str:
    """項目の行の鍵 (前回との差分に使う)。名前で見分け、同じ名前が 2 回目以降に出たら「#2」のように番号を付ける。

    内容は鍵に含めない。内容を書き直した行は同じ項目のまま扱い、「新」を付けない。
    """
    base = plain(name)
    seen[base] = seen.get(base, 0) + 1
    return base if seen[base] == 1 else f'{base}#{seen[base]}'


def action_request(name, act, ev):
    """対応案を、会話に貼ればそのまま依頼になる 1 文にする。"""
    text = f'「{plain(name)}」を対応して: {plain(act)}'
    return text + (f' (根拠: {", ".join(plain(e) for e in ev)})' if ev else '')


def render_items(title, lines, ctx=None):
    cols = ['項目', '確認したこと・根拠']
    m = re.match(r'^項目\s*[:：]\s*(.+)$', title)
    if m:
        cols = [c.strip() for c in m.group(1).split('/')]
        if len(cols) != 2 or not all(cols):
            raise InputError(f'列名は「## 項目: <1 列目> / <2 列目>」の 2 つだけ (対応案の列は「対応:」から自動で付く): {title[:40]}')
    rows, has_action = [], False
    for item in bullets(lines):
        m = re.match(r'^(?:\[([^\]]+)\]\s*)?(.+?)\s*[:：]\s*(.+)$', item[0])
        if not m:
            raise InputError(f'項目は「- [ラベル] 名前: 内容」の形にする: {item[0][:40]}')
        label, name, body = m.groups()
        ev, act = [], ''
        for extra in item[1:]:
            e = re.match(r'^(根拠|対応)\s*[:：]\s*(.+)$', extra)
            if not e:
                raise InputError(f'項目の続き行は「根拠:」「対応:」だけ: {extra[:40]}')
            if e.group(1) == '根拠':
                ev.append(e.group(2))
            else:
                act, has_action = e.group(2), True
        rows.append((label, name, body, ev, act))
    ctx = ctx if ctx is not None else {}
    prev = ctx.get('prev')
    if not rows:
        raise InputError('「## 項目」に項目が無い')
    head = ''.join(f'<th>{html.escape(c)}</th>' for c in cols + (['対応案'] if has_action else []))
    widths = ['20%', '44%', '36%'] if has_action else ['24%', '76%']

    def table(part):
        out = ['<table class="items"><colgroup>' + ''.join(f'<col style="width:{w}">' for w in widths) + '</colgroup>',
               f'<thead><tr>{head}</tr></thead><tbody>']
        for label, name, body, ev, act in part:
            tag = ''
            # 確認済みは既定の状態なので札を出さない。札は例外 (優先・推測・未検証など) の行だけに付く
            if label and label != '確認済み':
                kind = {'優先': ' priority', '推測': ' guess', '未検証': ' unverified'}.get(label, '')
                tag = f'<span class="tag{kind}">{html.escape(label)}</span>'
            key = item_key(name, ctx.setdefault('seen', {}))
            if prev is not None and key not in prev:  # 同じ --name の前回のシートに無かった行
                tag += '<span class="tag tag-blue">新</span>'
            tag += '<br>' if tag else ''
            request = action_request(name, act, ev) if act else ''
            ctx.setdefault('items', []).append({'key': key, 'label': label or '', 'name': plain(name),
                                                'act': plain(act), 'request': request})
            # 依頼のコピーは SHEET_JS が data-act から足す (静的な字数の検査に数えない)
            attrs = f' id="item-{len(ctx["items"])}"'
            attrs += f' data-act="{html.escape(request)}"' if act else ''
            evs = ''.join(f'<span class="evidence-line">{inline(mark_sources(e))}</span>' for e in ev)
            cell = f'<td><p>{inline(body)}</p>{evs}</td>'
            out.append(f'<tr{attrs}><th scope="row">{tag}{inline(name)}</th>{cell}'
                       + (f'<td><p>{inline(act)}</p></td>' if has_action else '') + '</tr>')
        out.append('</tbody></table>')
        return '\n'.join(out)

    first = [r for r in rows if r[0] == '優先']
    rest = [r for r in rows if r[0] != '優先']
    if first and rest and len(rows) >= FOLD_ROWS:
        return (table(first) + f'\n<details class="rest"><summary>ほかの {len(rest)} 件</summary>\n'
                + table(rest) + '\n</details>')
    return table(first + rest)


def gone_html(prev, items):
    """前回のシートにあって今回ない行。項目の節がいくつあっても、ページ全体で 1 回だけ数える。"""
    now = {it['key'] for it in items}
    gone = [k for k in (prev or []) if k not in now]
    if not gone:
        return ''
    names = ''.join(f'<li>{html.escape(k)}</li>' for k in gone)
    return (f'<details class="gone"><summary>前回のシートにあって今回ない {len(gone)} 件 (済んだか名前を変えた行)</summary>'
            f'<ul>{names}</ul></details>')


def render_body(src: str, prev=None, ctx=None):
    """本文の HTML 片、結論、節の (id, 見出し) の列、本文の語 (種別の判定用) を返す。形には依らない。

    prev は同じ --name の前回のシートの項目の鍵の列 (無ければ None)。ctx には状態・項目・要判断の数を集め、
    wrap() がページの report-data に埋める (保存先の一覧と次回の差分が読む)。
    """
    ctx = ctx if ctx is not None else {}
    ctx['prev'] = prev
    sections = split_sections(src)
    body, concl = render_head(sections[0][1])
    toc = []
    n_dec = sum(1 for t, _ in sections[1:] if t.startswith('要判断'))
    seen = 0
    for n, (title, lines) in enumerate(sections[1:], 1):
        sid = f'sec-{n}'
        if title.startswith('要判断'):
            part = render_decision(title, lines)
            ctx.setdefault('first_dec', sid)
            seen += 1
            if n_dec >= 2 and seen == n_dec:  # 最後の要判断の下に、選んだ案をまとめて返すボタン
                part += ('\n<div class="reply-all"><button type="button" class="copy reply-all-btn">選んだ案をまとめてコピー</button>'
                         '<span>各問の「この案で返答をコピー」で選び直せる。選んでいない問いは推奨で返す</span></div>')
        elif re.match(r'^項目(\s*[:：]|$)', title):
            part = render_items(title, lines, ctx)
        elif title == '注意点':
            part = ('<h2>注意点</h2><div class="warn"><ul>'
                    + ''.join(f'<li>{inline(" ".join(i))}</li>' for i in bullets(lines)) + '</ul></div>')
        elif title.startswith('付録'):
            summary = re.sub(r'^付録\s*[:：]?\s*', '', title) or '経緯'
            text = '\n'.join(lines).strip('\n')
            part = f'<details><summary>{inline(summary)}</summary><pre>{html.escape(text, quote=False)}</pre></details>'
        else:  # 自由な節: 普通の Markdown として描く
            part = f'<h2 class="sec">{inline(title)}</h2>\n<div class="content">\n{render_blocks(lines)}\n</div>'
        body.append(f'<div class="block" id="{sid}">\n{part}\n</div>')
        toc.append((sid, title))
        if part.startswith('<table class="items"'):
            ctx['last_items'] = len(body) - 1
    gone = gone_html(prev, ctx.get('items', []))
    if gone and 'last_items' in ctx:  # 最後の項目の節の下に置く。項目の節が無ければ本文の最後に置く
        at = ctx['last_items']
        body[at] = body[at][:-len('\n</div>')] + '\n' + gone + '\n</div>'
    elif gone:
        body.append(gone)
    ctx.update(decisions=n_dec, state=parse_title(sections[0][1])[1], concl=concl)
    auto_next = f'<div class="next"><b>次にすること</b><span>下の {n_dec} 問に答える</span></div>' if n_dec else ''
    body = [auto_next if b == NEXT_SLOT else b for b in body]
    words = ' '.join([concl] + [t for t, _ in sections[1:]])
    return '\n'.join(body), concl, toc, words


# ---- 静的な判定 --------------------------------------------------------------

def load_checker():
    spec = importlib.util.spec_from_file_location('check_sheet', CHECKER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


CHECK = load_checker()


def choose_layout(body_html: str) -> str:
    """本文の文章の字数 (検査と同じ数え方) が上限以内なら 'sheet'、超えたら 'detail'。"""
    total, _ = CHECK.prose_length(body_html)
    return 'detail' if total > CHECK.REPORT_PROSE_LIMIT else 'sheet'


def infer_kind(words: str) -> str:
    """タイトルと見出しの語から種別を決める。KIND_RULES の上から順に見て、最初に当たったもの。"""
    for kind, pattern in KIND_RULES:
        if re.search(pattern, words, flags=re.I):
            return kind
    return 'investigation'


def read_config(path=CONFIG):
    """output-config.toml の [output] base_dir、[output.subdirs]、[output.prefixes] だけを読む。"""
    conf = {'base_dir': '~/reports', 'subdirs': {}, 'prefixes': {}}
    if not path.is_file():
        return conf
    section = ''
    for raw in path.read_text(encoding='utf-8').splitlines():
        line = re.sub(r'#.*$', '', raw).strip()
        m = re.fullmatch(r'\[(.+)\]', line)
        if m:
            section = m.group(1)
            continue
        m = re.fullmatch(r'(\S+)\s*=\s*"(.*)"', line)
        if not m:
            continue
        if section == 'output' and m.group(1) == 'base_dir':
            conf['base_dir'] = m.group(2)
        elif section in ('output.subdirs', 'output.prefixes'):
            conf[section.split('.')[1]][m.group(1)] = m.group(2)
    return conf


def keep_path(kind: str, conf=None):
    """残すレポートの保存先: <base_dir>/<サブディレクトリ>/<接頭辞><3 桁の連番>.html。番号は既存の最大 + 1。"""
    conf = conf or read_config()
    _, subdir, prefix = KINDS[kind]
    subdir = conf['subdirs'].get(kind, subdir)
    prefix = conf['prefixes'].get(kind, prefix)
    base = Path(os.path.expanduser(conf['base_dir']))
    out_dir = base / subdir if subdir else base
    nums = [int(m.group(1)) for p in (out_dir.glob(f'{prefix}*.html') if out_dir.is_dir() else [])
            if (m := re.fullmatch(re.escape(prefix) + r'(\d+)\.html', p.name))]
    return out_dir / f'{prefix}{(max(nums) + 1) if nums else 1:03d}.html'


def scratch_path(name):
    slug = re.sub(r'[^A-Za-z0-9-]+', '-', name or 'report').strip('-') or 'report'
    base = os.environ.get('ORCA_CHAT_SCRATCH_DIR') or str(Path(tempfile.gettempdir()) / 'report-sheets')
    return Path(base) / f'{slug}-{secrets.token_hex(2)}.html'


def plan_paths(layout, kind, out=None, name=None, save=False):
    """書き出す先の列。先頭が本体。Orca では scratch の写しも足す (会話に貼れるのは scratch の中だけ)。"""
    if out:
        return [Path(out).resolve()]
    paths = []
    if layout == 'detail' or save:
        paths.append(keep_path(kind))
    if os.environ.get('ORCA_CHAT_SCRATCH_DIR') or not paths:
        paths.append(scratch_path(name))
    return paths


# ---- 組み立て ----------------------------------------------------------------

MERMAID = '''<script type="module">
  // 表示側のテーマに合わせるため、prefers-color-scheme ではなく実際の背景の明るさで配色を選ぶ
  const bg = getComputedStyle(document.body).backgroundColor.match(/\\d+(\\.\\d+)?/g) || [255, 255, 255];
  const dark = (0.299 * bg[0] + 0.587 * bg[1] + 0.114 * bg[2]) < 128;
  try {
    const { default: mermaid } = await import('https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.esm.min.mjs');
    mermaid.initialize({ startOnLoad: false, theme: dark ? 'dark' : 'neutral', securityLevel: 'strict',
                         fontFamily: getComputedStyle(document.body).fontFamily });
    await mermaid.run({ querySelector: 'pre.mermaid' });
    // 横に長い図は元の 7 割までしか縮めず、はみ出すぶんは枠の中で横スクロールさせる
    for (const svg of document.querySelectorAll('pre.mermaid svg')) {
      const natural = svg.viewBox.baseVal && svg.viewBox.baseVal.width;
      const box = svg.parentElement.clientWidth - 32;
      if (!natural || natural <= box) continue;
      svg.style.maxWidth = 'none';
      svg.style.width = Math.round(Math.max(box, natural * 0.7)) + 'px';
    }
  } catch (e) {
    for (const el of document.querySelectorAll('pre.mermaid:not([data-processed])')) {
      const note = document.createElement('div');
      note.className = 'mermaid-note';
      note.textContent = '図を描画できませんでした。以下は図の定義です。';
      el.parentNode.insertBefore(note, el);
    }
  }
</script>'''


SHEET_JS = """<script>
  // シートの仕掛け: コピー (要判断の返答・まとめての返答・対応案の依頼・コード) と、印刷時の畳みの展開。
  // クリップボードが使えない枠では選択して execCommand に戻る
  (function () {
    function copy(text, btn) {
      var done = function () { var t = btn.textContent; btn.textContent = 'コピーした'; setTimeout(function () { btn.textContent = t; }, 1400); };
      var fallback = function () {
        var ta = document.createElement('textarea'); ta.value = text; document.body.appendChild(ta); ta.select();
        try { document.execCommand('copy'); done(); } catch (e) { btn.textContent = 'コピーできない'; }
        document.body.removeChild(ta);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(done, fallback); else fallback();
    }
    document.querySelectorAll('pre:not(.mermaid) > code').forEach(function (code) {
      var b = document.createElement('button'); b.type = 'button'; b.className = 'copy code-copy'; b.textContent = 'コピー';
      code.parentNode.appendChild(b);
      b.addEventListener('click', function () {
        var text = code.classList && code.parentNode.classList.contains('diff')
          ? Array.prototype.map.call(code.querySelectorAll('div:not(.d-note)'), function (d) { return (d.querySelector('.tx') || d).textContent; }).join('\\n')
          : code.textContent;
        copy(text, b);
      });
    });
    document.querySelectorAll('button[data-copy]').forEach(function (b) {
      b.addEventListener('click', function () {
        copy(b.getAttribute('data-copy'), b);
        var choice = b.closest('.choice');
        if (!choice) return;  // 選んだ案として印を付け、まとめての返答に使う
        choice.parentNode.querySelectorAll('.choice').forEach(function (c) { c.classList.remove('picked'); });
        choice.classList.add('picked');
      });
    });
    document.querySelectorAll('.reply-all-btn').forEach(function (b) {
      b.addEventListener('click', function () {
        var lines = [];
        document.querySelectorAll('section.decision').forEach(function (sec) {
          var c = sec.querySelector('.choice.picked') || sec.querySelector('.choice.rec');
          if (c) lines.push((lines.length + 1) + '. 「' + c.getAttribute('data-q') + '」は「' + c.getAttribute('data-name') + '」');
        });
        copy('要判断への返答:\\n' + lines.join('\\n') + '\\nこの内容で進めて', b);
      });
    });
    document.querySelectorAll('tr[data-act]').forEach(function (tr) {
      var b = document.createElement('button'); b.type = 'button'; b.className = 'copy act-copy'; b.textContent = '依頼をコピー';
      b.addEventListener('click', function () { copy(tr.getAttribute('data-act'), b); });
      tr.lastElementChild.appendChild(b);
    });
    // 印刷・PDF では畳みをすべて開き、印刷が済んだら元に戻す。印刷前の通知が続いても、最初の状態だけを覚える
    var closed = null;
    window.addEventListener('beforeprint', function () {
      if (closed) return;
      closed = Array.prototype.filter.call(document.querySelectorAll('details'), function (d) { return !d.open; });
      closed.forEach(function (d) { d.open = true; });
    });
    window.addEventListener('afterprint', function () {
      (closed || []).forEach(function (d) { d.open = false; });
      closed = null;
    });
  })();
</script>"""


def slug(name):
    return re.sub(r'[^A-Za-z0-9-]+', '-', name or 'report').strip('-') or 'report'


def sheet_id(concl, name=None, kept=None):
    """同じレポートの版を見分ける名前。前回との差分と、保存先の一覧で版をまとめるのに使う。

    --name を最優先にする。保存先の連番は作り直すたびに変わるので、--name が無いときだけ使う。
    """
    if name:
        return slug(name)
    if kept:
        return kept
    return hashlib.sha1(concl.encode('utf-8')).hexdigest()[:10]


def report_data(ctx, layout, kind, sid):
    """ページに埋める機械向けの要約。保存先の一覧 (write_index) と、同じ --name の次回の差分 (load_previous) が読む。"""
    data = {'id': sid, 'state': ctx.get('state', ''), 'concl': ctx.get('concl', ''), 'kind': kind, 'layout': layout,
            'created': datetime.datetime.now().isoformat(timespec='minutes'), 'decisions': ctx.get('decisions', 0),
            'items': ctx.get('items', [])}
    # 「<」をすべて \\u003c にする。本文の </script> や <!-- で script 要素が途中で閉じたり続いたりしないように
    text = json.dumps(data, ensure_ascii=False).replace('<', '\\u003c')
    return f'<script type="application/json" id="report-data">{text}</script>\n'


def jump_bar(ctx, layout):
    """詳細の形で、要判断と優先の項目の数を上に留めて出し、押すと最初のものへ飛べるようにする。"""
    if layout != 'detail':
        return ''
    links = []
    if ctx.get('decisions'):
        links.append(f'<a href="#{ctx.get("first_dec", "")}">要判断 {ctx["decisions"]}</a>')
    prio = [i for i, it in enumerate(ctx.get('items', []), 1) if it['label'] == '優先']
    if prio:
        links.append(f'<a href="#item-{prio[0]}">優先 {len(prio)}</a>')
    return f'<nav class="jump">{" ".join(links)}</nav>\n' if links else ''


def wrap(body, concl, toc, layout, meta, ctx=None, kind='investigation', sid=None):
    ctx = ctx or {}
    # 目次は出さない。節の行き来は上に留めた要判断・優先の帯 (jump_bar) で足りる
    parts = [jump_bar(ctx, layout) + f'<div class="meta">{html.escape(meta)}</div>', body]
    page = TEMPLATE.read_text(encoding='utf-8')
    tab = concl if len(concl) <= 40 else concl[:39] + '…'
    return (page.replace('{{LAYOUT}}', ' detail' if layout == 'detail' else '')
                .replace('{{TAB_TITLE}}', html.escape(tab))
                .replace('{{BODY}}', '\n'.join(parts))
                .replace('{{SCRIPTS}}', report_data(ctx, layout, kind, sid or sheet_id(concl))
                         + (MERMAID if 'class="mermaid"' in body else '') + SHEET_JS))


def build(src: str, meta: str, layout=None, prev=None):
    """本文から HTML を作る。layout を省くと choose_layout() で決める。"""
    ctx = {}
    body, concl, toc, words = render_body(src, prev, ctx)
    return wrap(body, concl, toc, layout or choose_layout(body), meta, ctx, infer_kind(words))


def repo_name():
    return repo_root().name


def git_head():
    """'ブランチ@短い SHA'。Git の外や detached では取れる分だけ返す。"""
    def run(*args):
        try:
            r = subprocess.run(['git', *args], capture_output=True, text=True, timeout=5)
            return r.stdout.strip() if r.returncode == 0 else ''
        except (OSError, subprocess.SubprocessError):
            return ''
    branch, sha = run('rev-parse', '--abbrev-ref', 'HEAD'), run('rev-parse', '--short', 'HEAD')
    return f'{branch}@{sha}' if branch and sha else sha


def default_meta(layout, kind, doc_id=None):
    """タイトル上の小さな行。いつ・どのリポジトリのどの版を見て書いたかを後から分かるようにする。"""
    when = datetime.datetime.now().strftime('%Y-%m-%d %H:%M')
    head = (KINDS[kind][0], doc_id) if layout == 'detail' or doc_id else ()
    return ' · '.join(p for p in ('REPORT', *head, when, repo_name(), git_head()) if p)


# ---- 前回のシートと保存先の一覧 ---------------------------------------------------

DATA_RE = re.compile(r'<script type="application/json" id="report-data">(.*?)</script>', re.DOTALL)


def read_data(path: Path):
    """保存したページの report-data を読む。無い (古いページ)・壊れている・形が違うときは None。

    返す辞書は、文字列の欄 (id・state・concl・kind・created) と、key が文字列の項目だけを持つ。
    """
    try:
        m = DATA_RE.search(path.read_text(encoding='utf-8'))
        raw = json.loads(m.group(1).replace('<\\/', '</')) if m else None
    except (OSError, ValueError):
        return None
    if not isinstance(raw, dict):
        return None
    data = {k: raw[k] for k in ('id', 'state', 'concl', 'kind', 'created', 'layout') if isinstance(raw.get(k), str)}
    items = raw.get('items') if isinstance(raw.get('items'), list) else []
    data['items'] = [{k: it[k] for k in ('key', 'label', 'name', 'act') if isinstance(it.get(k), str)}
                     for it in items if isinstance(it, dict) and isinstance(it.get('key'), str)]
    return data


def load_previous(out=None, name=None, base=None):
    """同じ出力先 (--out) か同じ --name で前に作ったシートの項目の鍵。前回が無ければ None (差分の札を出さない)。

    --name のときは scratch の写しと保存先 (base) の同じ id の版を合わせ、書いた時刻が最も新しいものを前回とする。
    Orca の外の --save や詳細は scratch に写しを置かないので、保存先も探す。
    """
    cands = []
    if out and Path(out).is_file():
        cands = [Path(out)]
    elif name:
        scratch = Path(os.environ.get('ORCA_CHAT_SCRATCH_DIR') or Path(tempfile.gettempdir()) / 'report-sheets')
        s = slug(name)
        if scratch.is_dir():
            cands = [p for p in scratch.glob(f'{s}-*.html') if re.fullmatch(re.escape(s) + r'-[0-9a-f]{4}\.html', p.name)]
        if base and Path(base).is_dir():
            cands += [p for p in Path(base).rglob('*.html')
                      if p.name != 'index.html' and (read_data(p) or {}).get('id') == s]
        cands.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    for p in cands:
        data = read_data(p)
        if data is not None:
            return [it['key'] for it in data['items']]
    return None


INDEX_JS = """<script>
  // 絞り込み: 種別・状態・語
  (function () {
    var q = document.getElementById('f-text'), k = document.getElementById('f-kind'), s = document.getElementById('f-state');
    function apply() {
      var text = q.value.trim().toLowerCase();
      document.querySelectorAll('tr[data-kind]').forEach(function (tr) {
        var ok = (!k.value || tr.getAttribute('data-kind') === k.value) && (!s.value || tr.getAttribute('data-state') === s.value)
          && (!text || tr.textContent.toLowerCase().indexOf(text) >= 0);
        tr.style.display = ok ? '' : 'none';
      });
    }
    [q, k, s].forEach(function (el) { el.addEventListener('input', apply); });
  })();
</script>"""


def write_index(base: Path):
    """保存先の直下に index.html を作り直す。残したレポートの一覧と、要対応・未完了のレポートに残る優先の項目を載せる。

    同じ id の版が複数あれば、優先の項目は最新の版からだけ集める (古い版は一覧の表には残す)。
    """
    rows, open_items, latest = [], [], set()
    pages = []
    for p in base.rglob('*.html'):
        if p.name == 'index.html':
            continue
        data = read_data(p)
        if data is None:  # report-data の無い古いページはタイトルだけ拾う
            m = re.search(r'<title>(.*?)</title>', p.read_text(encoding='utf-8', errors='replace'), re.DOTALL)
            data = {'concl': html.unescape(m.group(1)) if m else p.stem, 'kind': p.parent.name if p.parent != base else '',
                    'items': []}
        data.setdefault('created', datetime.datetime.fromtimestamp(p.stat().st_mtime).isoformat(timespec='minutes'))
        pages.append((p, data))
    for p, data in sorted(pages, key=lambda x: x[1]['created'], reverse=True):
        href = html.escape(urllib.parse.quote(p.relative_to(base).as_posix()))
        state = re.sub(r'\s*\d+\s*件$', '', data.get('state', ''))
        kind = data.get('kind', '')
        concl = html.escape(data.get('concl', p.stem))
        rows.append(f'<tr data-kind="{html.escape(kind)}" data-state="{html.escape(state)}">'
                    f'<td>{html.escape(data["created"].replace("T", " "))}</td><td>{html.escape(KINDS.get(kind, (kind,))[0])}</td>'
                    f'<td>{html.escape(data.get("state", ""))}</td><td><a href="{href}">{concl}</a></td></tr>')
        sid = data.get('id')
        if sid and sid in latest:
            continue
        if sid:
            latest.add(sid)
        if state in ('要対応', '未完了'):
            for it in data['items']:
                if it.get('label') == '優先':
                    open_items.append(f'<tr><th scope="row">{html.escape(it.get("name", ""))}</th>'
                                      f'<td>{html.escape(it.get("act", ""))}</td><td><a href="{href}">{concl}</a></td></tr>')
    kinds = ''.join(f'<option value="{k}">{v[0]}</option>' for k, v in KINDS.items())
    states = ''.join(f'<option>{s}</option>' for s in STATES)
    body = [f'<div class="meta">REPORTS · {html.escape(str(base))}</div>',
            f'<h1>保存したレポート {len(rows)} 件</h1>']
    if open_items:
        body.append('<h2>要対応・未完了のレポートに残る優先の項目</h2><table class="items"><thead><tr>'
                    '<th>項目</th><th>対応案</th><th>レポート</th></tr></thead><tbody>' + ''.join(open_items) + '</tbody></table>')
    body.append('<h2>一覧</h2><div class="filters"><input id="f-text" type="search" placeholder="語で絞る">'
                f'<select id="f-kind"><option value="">すべての種別</option>{kinds}</select>'
                f'<select id="f-state"><option value="">すべての状態</option>{states}</select></div>'
                '<table class="index"><thead><tr><th>作成</th><th>種別</th><th>状態</th><th>結論</th></tr></thead><tbody>'
                + ''.join(rows) + '</tbody></table>')
    page = (TEMPLATE.read_text(encoding='utf-8').replace('{{LAYOUT}}', ' index').replace('{{TAB_TITLE}}', '保存したレポート')
            .replace('{{BODY}}', '\n'.join(body)).replace('{{SCRIPTS}}', INDEX_JS))
    out = base / 'index.html'
    out.write_text(page, encoding='utf-8')
    return out


def say(msg):
    try:
        print(msg)
    except UnicodeEncodeError:  # Windows の cp932 コンソール対策
        sys.stdout.buffer.write(msg.encode('utf-8', 'replace') + b'\n')


def main():
    ap = argparse.ArgumentParser(description='Markdown から報告シートを作る。形・種別・保存先は本文から決める')
    ap.add_argument('source', help='本文の Markdown。- なら標準入力')
    ap.add_argument('--name', help='scratch に置くファイル名の頭 (英数字とハイフン)')
    ap.add_argument('--out', help='保存先を決め打ちする (このときは他の場所へ書かない)')
    ap.add_argument('--meta', help='タイトル上の小さな行 (省略時は REPORT · 種別 · 番号 · 日付 · リポジトリ名)')
    ap.add_argument('--save', action='store_true', help='ユーザーが保存を頼んだとき。シートでも output-config.toml の保存先へ残す')
    a = ap.parse_args()
    try:
        src = sys.stdin.buffer.read().decode('utf-8-sig') if a.source == '-' else Path(a.source).read_text(encoding='utf-8-sig')
    except (OSError, UnicodeDecodeError) as e:
        say(f'new-sheet: 本文を読めない — {e}')
        sys.exit(2)
    base = Path(os.path.expanduser(read_config()['base_dir']))
    prev = load_previous(a.out, a.name, base)
    ctx = {}
    try:
        body, concl, toc, words = render_body(src, prev, ctx)
    except InputError as e:
        say(f'new-sheet: 書式の誤り — {e}\n  書式は references/sheet-input.md')
        sys.exit(2)
    layout, kind = choose_layout(body), infer_kind(words)
    paths = plan_paths(layout, kind, a.out, a.name, a.save)
    kept = paths[0] if (layout == 'detail' or a.save) and not a.out else None
    sid = sheet_id(concl, a.name, kept.relative_to(base).with_suffix('').as_posix() if kept else None)
    meta = a.meta or default_meta(layout, kind, kept.stem if kept else None)
    page = wrap(body, concl, toc, layout, meta, ctx, kind, sid)
    # 書く前に検査する。NG のシートは保存先にも一覧にも残さない (scratch と --out には直す材料として書く)
    errors, warns, _, _ = CHECK.check_sheet(page)
    if errors and kept:
        paths = paths[1:] or [scratch_path(a.name)]
        kept = None
    for p in paths:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(page, encoding='utf-8')
    index = write_index(base) if kept else None

    shape = f'形: {"詳細" if layout == "detail" else "シート"}' + (f' / 種別: {kind}' if kept else '')
    if errors and (layout == 'detail' or a.save) and not a.out:
        shape += ' / NG のため保存先と一覧には書いていない'
    if prev is not None:
        shape += f' / 前回との差分: 新 {sum(1 for it in ctx.get("items", []) if it["key"] not in prev)} 件'
    out = [f'new-sheet: {paths[0]}', f'  {shape}', f'  url  {paths[0].as_uri()}']
    out += [f'  写し {p}' for p in paths[1:]]
    if index:
        out.append(f'  一覧 {index}')
    orca = os.environ.get('ORCA_CHAT_SCRATCH_DIR')
    shown = next((p for p in paths if orca and p.parent == Path(orca).resolve()), None)
    if shown:
        title = html.unescape(page.split('<title>')[1].split('</title>')[0]).replace('"', '')
        out.append(f'  会話に貼る行: ::orca-visual{{file="{shown.name}" title="{title}"}}')
    out += [f'  NG  {e}' for e in errors] + [f'  ??  {w}' for w in warns]
    if not errors and not warns:
        out.append('  OK  不備なし')
    say('\n'.join(out))
    sys.exit(1 if errors else 0)


if __name__ == '__main__':
    main()
