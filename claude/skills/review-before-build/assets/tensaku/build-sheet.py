#!/usr/bin/env python3
"""レビュー 添削モード (tensaku) — 記事 Markdown から、人がブラウザで直接書き換える編集画面 (HTML 1 枚) を作る。

  python3 build-sheet.py <記事.md> <label> "<タイトル>" -o <出力.html>

例:
  python3 build-sheet.py docs/intro.md intro-01 "はじめに (下書き)" -o review/intro-01.html

- 記事 Markdown を template.html (このスクリプトと同じディレクトリ) に焼き込み、自己完結の HTML を出力する。
  出力は file:// で開けて、サーバもネットワークも要らない (Web フォントだけ届けば使う)。
- label は回答の 1 行目「【レビュー回答】<label>」になる。agent が回答をどのシートのものか見分けるための短い名前
  (英数字とハイフン推奨。例: intro-01)。
- 人が [貼り付ける文章を作る] を押すと、【レビュー回答】固定形 (語単位の差分行 + 完成形 Markdown 全文) が
  クリップボードに入る。人はそれを Claude Code のターミナルに貼る。
- 標準ライブラリだけで動く (python3.8 以上)。
"""
import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
TEMPLATE = HERE / 'template.html'

PLACEHOLDERS = ('__SOURCE_JSON__', '__SOURCE_PATH_JSON__', '__TITLE_JSON__', '__LABEL_JSON__', '__TITLE_HTML__', '__LABEL_HTML__')


def js_str(s: str) -> str:
    """JS 文字列リテラル化。</script> で <script> ブロックが割れないよう "</" をエスケープ。"""
    return json.dumps(s, ensure_ascii=False).replace('</', '<\\/')


def html_esc(s: str) -> str:
    return (s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
            .replace('"', '&quot;').replace("'", '&#39;'))


def build_sheet(article_path: Path, label: str, title: str, source_path: str) -> str:
    src = article_path.read_text(encoding='utf-8')
    if not TEMPLATE.is_file():
        sys.exit(f'build-sheet: template.html が見つからない: {TEMPLATE}')
    tpl = TEMPLATE.read_text(encoding='utf-8')
    rep = {
        '__SOURCE_JSON__': js_str(src),
        '__SOURCE_PATH_JSON__': js_str(source_path),
        '__TITLE_JSON__': js_str(title),
        '__LABEL_JSON__': js_str(label),
        '__TITLE_HTML__': html_esc(title),
        '__LABEL_HTML__': html_esc(label),
    }
    out = tpl
    for k in PLACEHOLDERS:
        if k not in out:
            sys.exit(f'build-sheet: template.html にプレースホルダ {k} が無い')
        out = out.replace(k, rep[k])
    for k in PLACEHOLDERS:
        if k in out:
            sys.exit(f'build-sheet: プレースホルダ {k} が置換後も残った')
    return out


def main() -> None:
    ap = argparse.ArgumentParser(
        description='レビュー 添削モード: 記事 Markdown → 人が直接書き換える編集画面 (自己完結 HTML 1 枚)。',
        epilog='生成した HTML を人に開いてもらい、[貼り付ける文章を作る] で出たテキストを Claude Code に貼ってもらう。',
    )
    ap.add_argument('article', help='記事 Markdown ファイル (この内容が編集画面に焼き込まれる)')
    ap.add_argument('label', help='回答の 1 行目「【レビュー回答】<label>」に入る短い名前 (例: intro-01)')
    ap.add_argument('title', help='画面の見出しに出すタイトル (例: "はじめに (下書き)")')
    ap.add_argument('-o', '--out', default=None, help='出力 HTML のパス (省略 = 標準出力)')
    ap.add_argument('--source-path', default=None,
                    help='画面の footer と下書き保存キーに使う記事の論理パス (初期値 = article に渡した値)')
    a = ap.parse_args()

    article = Path(a.article)
    if not article.is_file():
        sys.exit(f'build-sheet: 記事が見つからない: {article}')
    if not a.label.strip():
        sys.exit('build-sheet: label が空')
    source_path = a.source_path if a.source_path is not None else a.article

    sheet = build_sheet(article, a.label.strip(), a.title, source_path)
    if a.out:
        out = Path(a.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(sheet, encoding='utf-8')
        # as_uri() は Windows で file:///C:/... 形式 (スラッシュ 3 本 + 空白の %20) を返す。
        # f'file://{path}' だと file://C:\... になりブラウザで開けない。
        msg = f'sheet: {out} ({len(sheet.encode("utf-8"))} bytes) — ブラウザで開く: {out.resolve().as_uri()}'
        # Windows の既定 stderr は cp932 で、日本語が化ける環境がある。落とさず出す。
        try:
            print(msg, file=sys.stderr)
        except UnicodeEncodeError:
            sys.stderr.buffer.write(msg.encode('utf-8', 'replace') + b'\n')
    else:
        sys.stdout.write(sheet)


if __name__ == '__main__':
    main()
