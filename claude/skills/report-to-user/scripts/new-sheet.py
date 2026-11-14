#!/usr/bin/env python3
"""report-to-user — 短い Markdown から報告シートの HTML を作り、検査して場所を出す。

  python new-sheet.py <本文.md | -> [--name <英数字>] [--out <path>] [--meta <文字列>]

本文は「-」で標準入力から読める (Bash の heredoc で 1 回の呼び出しで済む)。書式は references/sheet-input.md。
保存先は --out、無ければ ORCA_CHAT_SCRATCH_DIR、無ければ一時ディレクトリの report-sheets/。
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
STATES = {'要判断': 'ask', '要対応': 'act', '未完了': 'act', '対応不要': ''}


class InputError(Exception):
    pass


def inline(text: str) -> str:
    """1 行分の Markdown を HTML にする: `code`、**太字**、[文字](URL)。それ以外はエスケープする。"""
    out, pos = [], 0
    for m in re.finditer(r'`([^`]+)`|\*\*(.+?)\*\*|\[([^\]]+)\]\(([^)\s]+)\)', text):
        out.append(html.escape(text[pos:m.start()], quote=False))
        if m.group(1) is not None:
            out.append(f'<code>{html.escape(m.group(1), quote=False)}</code>')
        elif m.group(2) is not None:
            out.append(f'<b>{html.escape(m.group(2), quote=False)}</b>')
        else:
            out.append(f'<a href="{html.escape(m.group(4))}">{html.escape(m.group(3), quote=False)}</a>')
        pos = m.end()
    out.append(html.escape(text[pos:], quote=False))
    return ''.join(out)


def split_sections(src: str):
    """フェンス (```) の中を壊さずに、## 見出しで区切る。返り値は (見出し, 行の配列) の列。"""
    sections, cur, fence = [], ('', []), False
    for line in src.replace('\r\n', '\n').split('\n'):
        if line.startswith('```'):
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


def render_head(lines, meta):
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
    cls = ' '.join(c for c in ('state', STATES[key]) if c)
    parts = [f'<div class="meta">{html.escape(meta)}</div>',
             f'<h1><span class="{cls}">{html.escape(state)}</span>{inline(concl)}</h1>']
    rest = lines[lines.index(title_line) + 1:]
    sub, nxt, pts, svgs, fence = [], None, [], [], None
    for line in rest:
        if fence is not None:
            if line.startswith('```'):
                svgs.append('\n'.join(fence))
                fence = None
            else:
                fence.append(line)
        elif line.startswith('```'):
            fence = []
        elif re.match(r'^次\s*[:：]', line):
            nxt = re.sub(r'^次\s*[:：]\s*', '', line)
        elif re.match(r'^[-*]\s+', line):
            pts.append(re.sub(r'^[-*]\s+', '', line))
        elif line.strip():
            sub.append(line.strip())
    if sub:
        parts.append(f'<p class="sub">{inline(" ".join(sub))}</p>')
    parts.append(f'<div class="next"><b>次にすること</b><span>{inline(nxt or "対応不要")}</span></div>')
    parts += svgs
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
    m = re.match(r'^項目\s*[:：]\s*(.+?)\s*/\s*(.+)$', title)
    if m:
        cols = [m.group(1), m.group(2)]
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
    out = ['<table><colgroup>' + ''.join(f'<col style="width:{w}">' for w in widths) + '</colgroup>',
           f'<thead><tr>{head}</tr></thead><tbody>']
    for label, name, body, ev, act in rows:
        tag = ''
        if label:
            kind = ' priority' if label == '先に対応' else ' guess' if label == '推測' else ''
            tag = f'<span class="tag{kind}">{html.escape(label)}</span><br>'
        evs = ''.join(f'<code class="evidence-line">{html.escape(e)}</code>' for e in ev)
        cell = f'<td><p>{inline(body)}</p>{evs}</td>'
        out.append(f'<tr><th scope="row">{tag}{inline(name)}</th>{cell}'
                   + (f'<td><p>{inline(act)}</p></td>' if has_action else '') + '</tr>')
    out.append('</tbody></table>')
    return '\n'.join(out)


def build(src: str, meta: str):
    sections = split_sections(src)
    body, concl = render_head(sections[0][1], meta)
    for title, lines in sections[1:]:
        if title.startswith('要判断'):
            body.append(render_decision(title, lines))
        elif title.startswith('項目'):
            body.append(render_items(title, lines))
        elif title == '注意点':
            body.append('<h2>注意点</h2><div class="warn"><ul>'
                        + ''.join(f'<li>{inline(" ".join(i))}</li>' for i in bullets(lines)) + '</ul></div>')
        elif title.startswith('付録'):
            summary = re.sub(r'^付録\s*[:：]?\s*', '', title) or '経緯と実行ログ'
            text = '\n'.join(lines).strip('\n')
            body.append(f'<details><summary>{inline(summary)}</summary><pre>{html.escape(text, quote=False)}</pre></details>')
        else:
            raise InputError(f'知らない節「## {title}」。要判断 / 項目 / 注意点 / 付録 のどれかにする')
    page = TEMPLATE.read_text(encoding='utf-8')
    tab = concl if len(concl) <= 40 else concl[:39] + '…'
    return page.replace('{{TAB_TITLE}}', html.escape(tab)).replace('{{BODY}}', '\n'.join(body))


def default_meta():
    cwd = Path.cwd()
    try:
        top = subprocess.run(['git', 'rev-parse', '--show-toplevel'], capture_output=True, text=True, timeout=5)
        if top.returncode == 0 and top.stdout.strip():
            cwd = Path(top.stdout.strip())
    except (OSError, subprocess.SubprocessError):
        pass
    return f'REPORT · {datetime.date.today().isoformat()} · {cwd.name}'


def out_path(arg_out, name):
    if arg_out:
        return Path(arg_out).resolve()
    slug = re.sub(r'[^A-Za-z0-9-]+', '-', name or 'report').strip('-') or 'report'
    base = os.environ.get('ORCA_CHAT_SCRATCH_DIR') or str(Path(tempfile.gettempdir()) / 'report-sheets')
    return Path(base) / f'{slug}-{secrets.token_hex(2)}.html'


def say(msg):
    try:
        print(msg)
    except UnicodeEncodeError:  # Windows の cp932 コンソール対策
        sys.stdout.buffer.write(msg.encode('utf-8', 'replace') + b'\n')


def main():
    ap = argparse.ArgumentParser(description='短い Markdown から報告シートを作る')
    ap.add_argument('source', help='本文の Markdown。- なら標準入力')
    ap.add_argument('--name', help='ファイル名の頭 (英数字とハイフン)')
    ap.add_argument('--out', help='保存先 (省略時は Orca の scratch か一時ディレクトリ)')
    ap.add_argument('--meta', help='タイトル上の小さな行 (省略時は REPORT · 日付 · リポジトリ名)')
    a = ap.parse_args()
    try:
        src = sys.stdin.buffer.read().decode('utf-8-sig') if a.source == '-' else Path(a.source).read_text(encoding='utf-8-sig')
    except (OSError, UnicodeDecodeError) as e:
        say(f'new-sheet: 本文を読めない — {e}')
        sys.exit(2)
    try:
        page = build(src, a.meta or default_meta())
    except InputError as e:
        say(f'new-sheet: 書式の誤り — {e}\n  書式は references/sheet-input.md')
        sys.exit(2)
    path = out_path(a.out, a.name)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(page, encoding='utf-8')

    spec = importlib.util.spec_from_file_location('check_sheet', CHECKER)
    checker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(checker)
    errors, warns, _, _ = checker.check_sheet(page)
    lines = [f'  NG  {e}' for e in errors] + [f'  ??  {w}' for w in warns] or ['  OK  不備なし']
    say(f'new-sheet: {path}\n  url  {path.as_uri()}')
    if os.environ.get('ORCA_CHAT_SCRATCH_DIR') and path.parent == Path(os.environ['ORCA_CHAT_SCRATCH_DIR']).resolve():
        say(f'  会話に貼る行: ::orca-visual{{file="{path.name}" title="{html.unescape(page.split("<title>")[1].split("</title>")[0]).replace(chr(34), "")}"}}')
    say('\n'.join(lines))
    sys.exit(1 if errors else 0)


if __name__ == '__main__':
    main()
