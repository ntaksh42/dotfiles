#!/usr/bin/env python3
"""report-to-user — Markdown から報告シートの HTML を作り、検査して場所を出す。

  python new-sheet.py <本文.md | -> [--name <英数字>] [--out <path>] [--meta <文字列>] [--save]

本文は「-」で標準入力から読める (Bash の heredoc で 1 回の呼び出しで済む)。書式は references/sheet-input.md。

形と保存先は呼び出し側が選ばず、この生成器が本文から決める:
  - 形: 本文の文章が 800 字以内なら「シート」、超えたら「詳細」(目次・長い表の畳み・字数の上限なし)。choose_layout()
  - 種別: タイトルと見出しの語から review / bug / security / proposal / research / investigation を決める。infer_kind()
  - 保存先: 詳細と --save は output-config.toml の保存先へ連番で残す。シートは ORCA_CHAT_SCRATCH_DIR か
    一時ディレクトリの report-sheets/ に置く。Orca では残すものも scratch に写しを置いて会話に貼れるようにする。
    --out を渡すとそこだけに書く。
最後に assets/check-sheet.py の検査をかけ、NG があれば終了コード 1。標準ライブラリのみ (python3.8+)。
"""
import argparse
import datetime
import html
import importlib.util
import os
import re
import secrets
import subprocess
import sys
import tempfile
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent.parent
TEMPLATE = SKILL_DIR / 'templates' / 'sheet.html'
CHECKER = SKILL_DIR / 'assets' / 'check-sheet.py'
CONFIG = SKILL_DIR / 'output-config.toml'
FOLD_ROWS = 6        # 優先の行があり、項目がこの数以上なら、優先以外の行を畳む
TABLE_FOLD = 15      # 自由な節の表は、データ行がこの数を超えたら残りを畳む
TOC_MIN = 5          # 詳細で節がこの数以上なら目次を出す
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
            out.append(f'<code>{html.escape(code, quote=False)}</code>')
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
    attr = f' data-lang="{html.escape(lang)}"' if lang else ''
    return f'<pre{attr}><code>{html.escape(code, quote=False)}</code></pre>'


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
    rows = []
    for line in lines:
        m = re.match(r'^(推奨|他案)\s*[:：]\s*(.+)$', line.strip())
        if m:
            cls = 'rec' if m.group(1) == '推奨' else 'alt'
            rows.append(f'<div class="choice {cls}"><b>{m.group(1)}</b><p>{inline(m.group(2))}</p></div>')
        elif line.strip():
            raise InputError(f'要判断の中は「推奨:」「他案:」の行だけ: {line.strip()[:40]}')
    if not rows or 'rec' not in rows[0]:
        raise InputError(f'要判断「{title}」の最初の行は「推奨:」にする')
    return f'<section class="decision"><h3>{inline(title)}</h3>' + ''.join(rows) + '</section>'


def render_items(title, lines):
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
                tag = f'<span class="tag{kind}">{html.escape(label)}</span><br>'
            evs = ''.join(f'<span class="evidence-line">{inline(e)}</span>' for e in ev)
            cell = f'<td><p>{inline(body)}</p>{evs}</td>'
            out.append(f'<tr><th scope="row">{tag}{inline(name)}</th>{cell}'
                       + (f'<td><p>{inline(act)}</p></td>' if has_action else '') + '</tr>')
        out.append('</tbody></table>')
        return '\n'.join(out)

    first = [r for r in rows if r[0] == '優先']
    rest = [r for r in rows if r[0] != '優先']
    if first and rest and len(rows) >= FOLD_ROWS:
        return (table(first) + f'\n<details class="rest"><summary>ほかの {len(rest)} 件</summary>\n'
                + table(rest) + '\n</details>')
    return table(first + rest)


def render_body(src: str):
    """本文の HTML 片、結論、節の (id, 見出し) の列、本文の語 (種別の判定用) を返す。形には依らない。"""
    sections = split_sections(src)
    body, concl = render_head(sections[0][1])
    toc = []
    for n, (title, lines) in enumerate(sections[1:], 1):
        sid = f'sec-{n}'
        if title.startswith('要判断'):
            part = render_decision(title, lines)
        elif re.match(r'^項目(\s*[:：]|$)', title):
            part = render_items(title, lines)
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
    n_dec = sum(1 for t, _ in sections[1:] if t.startswith('要判断'))
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


def wrap(body, concl, toc, layout, meta):
    parts = [f'<div class="meta">{html.escape(meta)}</div>', body]
    if layout == 'detail' and len(toc) >= TOC_MIN:
        links = ''.join(f'<li><a href="#{sid}">{inline(t)}</a></li>' for sid, t in toc)
        # 目次は見出しのすぐ下 (h1 の直後のまとまりの後) ではなく、本文の最初の節の前に置く
        first = body.find('<div class="block"')
        nav = f'<nav class="toc"><b>目次</b><ol>{links}</ol></nav>\n'
        parts[1] = body[:first] + nav + body[first:] if first >= 0 else body + nav
    page = TEMPLATE.read_text(encoding='utf-8')
    tab = concl if len(concl) <= 40 else concl[:39] + '…'
    return (page.replace('{{LAYOUT}}', ' detail' if layout == 'detail' else '')
                .replace('{{TAB_TITLE}}', html.escape(tab))
                .replace('{{BODY}}', '\n'.join(parts))
                .replace('{{SCRIPTS}}', MERMAID if 'class="mermaid"' in body else ''))


def build(src: str, meta: str, layout=None):
    """本文から HTML を作る。layout を省くと choose_layout() で決める。"""
    body, concl, toc, _ = render_body(src)
    return wrap(body, concl, toc, layout or choose_layout(body), meta)


def repo_name():
    cwd = Path.cwd()
    try:
        top = subprocess.run(['git', 'rev-parse', '--show-toplevel'], capture_output=True, text=True, timeout=5)
        if top.returncode == 0 and top.stdout.strip():
            cwd = Path(top.stdout.strip())
    except (OSError, subprocess.SubprocessError):
        pass
    return cwd.name


def default_meta(layout, kind, doc_id=None):
    date = datetime.date.today().isoformat()
    if layout == 'detail' or doc_id:
        return ' · '.join(p for p in ('REPORT', KINDS[kind][0], doc_id, date, repo_name()) if p)
    return f'REPORT · {date} · {repo_name()}'


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
    try:
        body, concl, toc, words = render_body(src)
    except InputError as e:
        say(f'new-sheet: 書式の誤り — {e}\n  書式は references/sheet-input.md')
        sys.exit(2)
    layout, kind = choose_layout(body), infer_kind(words)
    paths = plan_paths(layout, kind, a.out, a.name, a.save)
    kept = paths[0] if (layout == 'detail' or a.save) and not a.out else None
    meta = a.meta or default_meta(layout, kind, kept.stem if kept else None)
    page = wrap(body, concl, toc, layout, meta)
    for p in paths:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(page, encoding='utf-8')

    errors, warns, _, _ = CHECK.check_sheet(page)
    shape = f'形: {"詳細" if layout == "detail" else "シート"}' + (f' / 種別: {kind}' if kept else '')
    out = [f'new-sheet: {paths[0]}', f'  {shape}', f'  url  {paths[0].as_uri()}']
    out += [f'  写し {p}' for p in paths[1:]]
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
