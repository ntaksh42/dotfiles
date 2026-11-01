#!/usr/bin/env python3
"""[判断] コメント JSON を Crit のセッションへ投稿し、全件載ったかを確かめる。

  python3 post-judgments.py --session <id> <judgments.json>

Crit (v0.23.2 で確認) の daemon は、プレビュー・live のレビューファイルに review_type と
cli_args を書かないことがある。その状態の `crit comment` は selector 付きのピンを
「--selector is only supported for live and preview reviews」
「preview review has no HTML file」で拒否する。
このスクリプトは、セッションの起動引数から両方を補ってから投稿する。

プレビューでは全体コメント (scope: review) を投稿できない。標準モードの JSON はピンだけにする。

終了コード 0 = 全件投稿済み / 1 = 失敗。標準ライブラリのみ (python3.8+)。
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

CRIT_HOME = Path.home() / '.crit'


def say(msg: str) -> None:
    try:
        print(msg)
    except UnicodeEncodeError:              # Windows の cp932 コンソール対策
        sys.stdout.buffer.write(msg.encode('utf-8', 'replace') + b'\n')


def crit(*args: str) -> str:
    r = subprocess.run(['crit', *args], capture_output=True, text=True, encoding='utf-8')
    if r.returncode != 0:
        say(f'post-judgments: crit {args[0]} が失敗: {(r.stderr or r.stdout).strip()}')
        sys.exit(1)
    return r.stdout


def ensure_pin_fields(session: str) -> None:
    """プレビュー・live のレビューファイルに review_type と cli_args が無ければ補う。"""
    info_path = CRIT_HOME / 'sessions' / f'{session}.json'
    if not info_path.is_file():
        say(f'post-judgments: セッションが見つからない: {info_path} (crit status --json で id を確かめる)')
        sys.exit(1)
    info = json.loads(info_path.read_text(encoding='utf-8'))
    args = info.get('args') or []
    if not args or args[0] not in ('preview', 'live'):
        return                              # ファイル・差分のレビューでは不要
    review = Path(info.get('review_path') or CRIT_HOME / 'reviews' / session) / 'review.json'
    data = json.loads(review.read_text(encoding='utf-8')) if review.is_file() else {}
    if data.get('review_type') == args[0] and data.get('cli_args'):
        return
    data['review_type'] = args[0]
    data.setdefault('cli_args', args)
    data.setdefault('cwd', info.get('cwd', ''))
    review.parent.mkdir(parents=True, exist_ok=True)
    review.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')


def count(session: str) -> int:
    return len(json.loads(crit('comments', '--session', session, '--json') or '[]'))


def main() -> None:
    ap = argparse.ArgumentParser(description='[判断] コメント JSON を Crit に投稿する (プレビューのピンも通す)。')
    ap.add_argument('--session', required=True, help='crit のセッション id')
    ap.add_argument('comments', help='crit comment --json 形式の JSON ファイル')
    a = ap.parse_args()

    entries = json.loads(Path(a.comments).read_text(encoding='utf-8'))
    pins = sum(1 for e in entries if e.get('selector'))
    if pins:
        ensure_pin_fields(a.session)
    before = count(a.session)
    crit('comment', '--session', a.session, '--json', '--file', a.comments, '--author', 'Claude Code')
    added = count(a.session) - before
    if added != len(entries):
        say(f'post-judgments: 投稿 {len(entries)} 件のうち {added} 件しか載っていない')
        sys.exit(1)
    say(f'post-judgments: {len(entries)} 件を投稿した (うちピン {pins} 件)')


if __name__ == '__main__':
    main()
