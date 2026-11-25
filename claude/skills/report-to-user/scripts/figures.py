"""report-to-user — 短い記法から報告シートの SVG を描く (new-sheet.py が読み込む)。

座標を手で書かずに図を足せるようにする。色は雛形の CSS が付けるので、ここでは fill や stroke を書かない。

flow (流れ・食い違い・前後): 1 行が 1 段。箱を `->` でつなぎ、`!` を前に付けた箱を要点として赤くする。
  `段名: ` で始めると左端に段の名前を出す。続く段で同じ列の箱がどちらも `!` なら、縦の点線で結ぶ。
  `# ` で始まる行は図の上に出す条件の文。

    # 保存に失敗したとき
    画面: 保存を押す -> 「保存しました」 -> !一覧に出る
    実際: 保存を押す -> 書き込みに失敗 -> !一覧に無い

bars (量): 1 行が 1 本。`ラベル | 値` で、値の最初の数で棒の長さを決め、値の文字はそのまま棒の端に出す。
  `!` を前に付けた行を要点として赤くする。`# ` で始まる行は図の上に出す文。

    # 閾値ごとに残る差し戻し
    今 (5 行・300 字) | 158 回
    !7 行・400 字 | 88 回
"""
import html
import re

W = 960
PAD = 16
CHAR_W = {True: 8.5, False: 15}   # ASCII かどうかで 1 字の幅を見積もる (font-size 14px)
LINE_H = 20


def text_w(s: str) -> float:
    return sum(CHAR_W[ord(c) < 128] for c in s)


def wrap(s: str, width: float):
    """見積もった幅で折り返す。英数字の語は途中で切らない。"""
    tokens = re.findall(r'[\x21-\x7e]+|\s+|.', s)
    lines, cur = [], ''
    for t in tokens:
        # 閉じ括弧・句読点は行頭に送らない
        if cur and text_w(cur + t) > width and not t.isspace() and not re.match(r'^[)\]）」』、。,.]', t):
            lines.append(cur.rstrip())
            cur = t
        else:
            cur += t
    if cur.strip():
        lines.append(cur.rstrip())
    return lines or ['']


def text_el(x, y, lines, anchor='middle', cls=''):
    """lines を y を中心に縦に並べた <text>。"""
    top = y - (len(lines) - 1) * LINE_H / 2 + 5
    c = f' class="{cls}"' if cls else ''
    if len(lines) == 1:
        return f'<text x="{x:.0f}" y="{top:.0f}" text-anchor="{anchor}"{c}>{html.escape(lines[0])}</text>'
    spans = ''.join(f'<tspan x="{x:.0f}" dy="{0 if i == 0 else LINE_H}">{html.escape(l)}</tspan>'
                    for i, l in enumerate(lines))
    return f'<text x="{x:.0f}" y="{top:.0f}" text-anchor="{anchor}"{c}>{spans}</text>'


def svg(height, body, label):
    return (f'<svg viewBox="0 0 {W} {height:.0f}" width="100%" role="img" aria-label="{html.escape(label)}">'
            + ''.join(body) + '</svg>')


def split_caption(code: str):
    caption, rows = [], []
    for line in code.splitlines():
        if not line.strip():
            continue
        if line.lstrip().startswith('#'):
            caption.append(line.lstrip().lstrip('#').strip())
        else:
            rows.append(line.strip())
    return ' '.join(caption), rows


def key_name(s: str):
    s = s.strip()
    return (True, s[1:].strip()) if s.startswith('!') else (False, s)


def flow(code: str) -> str:
    caption, lines = split_caption(code)
    rows = []
    for line in lines:
        m = re.match(r'^([^:：]{1,16})[:：]\s*(.*)$', line)
        label, rest = (m.group(1).strip(), m.group(2)) if m and '->' not in m.group(1) else ('', line)
        boxes = [key_name(b) for b in rest.split('->') if b.strip()]
        if boxes:
            rows.append((label, boxes))
    if not rows:
        raise ValueError('flow の図に箱が無い — 「段名: 箱 -> 箱 -> !要点の箱」の形で 1 行 1 段に書く')
    n = max(len(b) for _, b in rows)
    gap = 44 if n > 1 else 0
    label_w = max((text_w(l) for l, _ in rows), default=0)
    label_w = min(label_w + 20, 180) if label_w else 0
    bw = (W - 2 * PAD - label_w - gap * (n - 1)) / n
    body, y = [], PAD
    if caption:
        body.append(text_el(PAD, y + 8, wrap(caption, W - 2 * PAD), anchor='start', cls='cap'))
        y += 18 + LINE_H * len(wrap(caption, W - 2 * PAD))
    prev = None   # (列ごとの要点か, 下端の y)
    for label, boxes in rows:
        wrapped = [wrap(name, bw - 20) for _, name in boxes]
        bh = max(46, max(len(w) for w in wrapped) * LINE_H + 22)
        if prev is not None:
            y += 40
        cy = y + bh / 2
        if label:
            body.append(text_el(PAD, cy, wrap(label, label_w - 12), anchor='start'))
        for i, ((key, _), lines_) in enumerate(zip(boxes, wrapped)):
            x = PAD + label_w + i * (bw + gap)
            box = (f'<rect x="{x:.0f}" y="{y:.0f}" width="{bw:.0f}" height="{bh:.0f}" rx="8"/>'
                   + text_el(x + bw / 2, cy, lines_))
            body.append(f'<g class="key">{box}</g>' if key else f'<g>{box}</g>')
            if i:
                x0, x1 = x - gap + 4, x - 6
                body.append(f'<g><line x1="{x0:.0f}" y1="{cy:.0f}" x2="{x1:.0f}" y2="{cy:.0f}"/>'
                            f'<path d="M{x1 - 8:.0f} {cy - 6:.0f} L{x1:.0f} {cy:.0f} L{x1 - 8:.0f} {cy + 6:.0f}"/></g>')
            if prev is not None and i < len(prev[0]) and prev[0][i] and key:
                cx = x + bw / 2
                body.append(f'<g class="key"><line x1="{cx:.0f}" y1="{prev[1]:.0f}" x2="{cx:.0f}" y2="{y:.0f}" '
                            f'stroke-dasharray="6 5"/></g>')
        prev = ([k for k, _ in boxes], y + bh)
        y += bh
    label = caption or ' / '.join(' → '.join(n for _, n in b) for _, b in rows)
    return svg(y + PAD, body, label)


NUM = re.compile(r'-?\d+(?:\.\d+)?')


def bars(code: str) -> str:
    caption, lines = split_caption(code)
    rows = []
    for line in lines:
        name, sep, value = line.rpartition('|')
        if not sep:
            raise ValueError(f'bars の行に「|」が無い: {line} — 「ラベル | 値」の形で書く')
        key, name = key_name(name)
        m = NUM.search(value.replace(',', ''))
        if not m:
            raise ValueError(f'bars の値に数が無い: {line}')
        rows.append((key, name, value.strip(), float(m.group(0))))
    if not rows:
        raise ValueError('bars の図に行が無い — 「ラベル | 値」を 1 行 1 本で書く')
    top = max(v for *_, v in rows) or 1
    label_w = min(max(text_w(n) for _, n, _, _ in rows) + 24, 380)
    value_w = max(text_w(v) for _, _, v, _ in rows) + 16
    area = W - 2 * PAD - label_w - value_w
    body, y = [], PAD
    if caption:
        body.append(text_el(PAD, y + 8, wrap(caption, W - 2 * PAD), anchor='start', cls='cap'))
        y += 18 + LINE_H * len(wrap(caption, W - 2 * PAD))
    for key, name, value, v in rows:
        lines_ = wrap(name, label_w - 16)
        h = max(36, len(lines_) * LINE_H + 12)
        cy = y + h / 2
        bw = max(2, area * max(v, 0) / top)
        x = PAD + label_w
        row = (text_el(PAD, cy, lines_, anchor='start')
               + f'<rect class="bar" x="{x:.0f}" y="{cy - 12:.0f}" width="{bw:.0f}" height="24" rx="3"/>'
               + text_el(x + bw + 8, cy, [value], anchor='start'))
        body.append(f'<g class="key">{row}</g>' if key else f'<g>{row}</g>')
        y += h + 8
    label = caption or ' / '.join(f'{n} {v}' for _, n, v, _ in rows)
    return svg(y - 8 + PAD, body, label)


RENDER = {'flow': flow, 'bars': bars}
