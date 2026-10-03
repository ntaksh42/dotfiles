#!/usr/bin/env python3
"""jp_lint.py - AI 生成の日本語について、書き直しの候補を出す（標準ライブラリのみ）。

スコアは出さない。出力は候補であり、合否の判定ではない。
ルールは Zenn の技術記事（AI 普及前 250 本、2026 年 250 本）で出現率を比べ、
差が出たものだけを残した。数値の根拠は references/vocab.md にある。
"""
import argparse
import json
import re
import string
import sys
import unicodedata
from dataclasses import asdict, dataclass


@dataclass
class Finding:
    rule: str
    severity: str  # warn: 直す候補 / info: 参考 / hint: 端的化の候補
    line: int  # 0 は文書全体
    message: str
    snippet: str = ""


# 比喩動詞の6形。2026 年の記事にだけ現れた形を持つ（普及前の250本には 0 件）。
# 「効く」「回す」「拾う」などは技術的な用法が多いので、単独では検出しない。
METAPHOR_VERBS = [
    (r"(黙って|静かに|そっと)[ぁ-ん]{0,3}(無視|捨て|切り捨て|スキップ|破棄|止ま|落ち|壊れ|失敗|消え|劣化|崩れ|上書き)", "黙って・静かに＋失敗"),
    (r"(側|方向)[にへ]倒[すしせれ]", "〜側に倒す"),
    (r"(時間|工数|半日|一日|丸一日)[をが]?溶[かけ]", "時間を溶かす"),
    (r"[0-9一二三ひと]つ?ずつ[^。、]{0,4}潰", "一つずつ潰す"),
    (r"(地味|じわじわ|ボディブロー)[にと]?[^。、]{0,4}効", "地味に効く"),
    (r"(設計|実装|内部|詳細|仕組み|領域|本質)[^。、]{0,3}(に|へ|まで)踏み込", "〜に踏み込む"),
]

# --concise の対象。冗長な言い回しは普及前の記事のほうが多く、AI らしさの指標ではない。
# 端的にする作業の候補としてだけ出し、終了コードには影響させない。
WORDY_FORMS = [
    (r"ことができ(る|ます|ない|ません|た|ました)", "「できる」に縮める"),
    (r"を(行|実施)(う|い|っ|し)", "動詞にする（「確認を行う」→「確認する」）"),
    (r"において|における", "「で」「の」にする"),
    (r"ということ|という点", "「こと」「点」にする"),
    (r"まず最初|違和感を感じ|後で後悔|あらかじめ事前|一番最も|必ず必要", "二重表現"),
    (r"(次の|以下の)(点|通り|3つ|ような)|注目すべき点|挙げられます", "予告だけの文。中身の文と1文にする"),
    (r"いかがでしたでしょうか|参考になれば幸いです", "定型の結び"),
]

# 2026 年に急増した語。語自体は正当なので、3 種以上が重なったときだけ info にする。
SURGE_WORDS = ["実測", "照合", "突き合わせ", "入口", "落とし穴", "事故", "取り違え",
               "断定", "要点", "別物", "疑う", "混ざ"]
SURGE_KINDS_MIN = 3

# 密度の目安は、AI 普及前の記事の 90 パーセンタイル。短い文書は密度が跳ねるので対象外にする。
BOLD_MAX_PER_1K = 3.9
NEGATION_MAX_PER_1K = 0.55
DENSITY_MIN_CHARS = 800

DASHES = re.compile(r"[—―─]+")
BOLD_PAIR = re.compile(r"\*\*([^*\n]+?)\*\*")
NEGATION = re.compile(r"ではなく")
FRONT_MATTER = re.compile(r"---\r?\n.*?\r?\n---\r?\n", re.S)


def prose_lines(text):
    """フロントマター、コードブロック、引用、表を除いた (行番号, 行) を返す。インラインコードも消す。"""
    head = FRONT_MATTER.match(text)
    skip = head.group(0).count("\n") if head else 0
    kept, in_fence = [], False
    for no, raw in enumerate(text.splitlines(), 1):
        stripped = raw.lstrip()
        if no <= skip:
            continue
        if stripped.startswith("```"):
            in_fence = not in_fence
        elif not in_fence and not stripped.startswith((">", "|")):
            kept.append((no, re.sub(r"`[^`]*`", "", raw)))
    return kept


def _is_punct(ch):
    return ch in string.punctuation or unicodedata.category(ch).startswith(("P", "S"))


def _can_flank(before, after, opening):
    """CommonMark で ** が太字の開始（または終了）として働くか。

    開始なら右側、終了なら左側の文字を見る。その文字が記号のとき、反対側が文字だと働かない。
    """
    inner, outer = (after, before) if opening else (before, after)
    if not inner or inner.isspace():
        return False
    if _is_punct(inner) and outer and not outer.isspace():
        return _is_punct(outer)
    return True


def broken_bold(line):
    """太字として表示されない ** の対を返す（例: 文字に接する **「…」**）。"""
    def at(i):
        return line[i] if 0 <= i < len(line) else ""

    return [m.group(0) for m in BOLD_PAIR.finditer(line)
            if not (_can_flank(at(m.start() - 1), at(m.start() + 2), True)
                    and _can_flank(at(m.end() - 3), at(m.end()), False))]


def _around(line, m):
    return line[max(0, m.start() - 12):m.end() + 12]


def _per_1k(count, chars):
    return count / chars * 1000


def lint(text, concise=False):
    lines = prose_lines(text)
    body = "\n".join(line for _, line in lines)
    chars = len(re.sub(r"\s", "", body)) or 1
    found = []

    for no, line in lines:
        for pattern, label in METAPHOR_VERBS:
            found += [Finding("metaphor_verb", "warn", no, f"比喩動詞「{label}」", _around(line, m))
                      for m in re.finditer(pattern, line)]
        found += [Finding("dash", "warn", no, "ダッシュ記号。助詞や読点でつなぐ", _around(line, m))
                  for m in DASHES.finditer(line)]
        found += [Finding("broken_bold", "warn", no, "太字として表示されない書き方（記号の内側だけを太字にするか、空白を入れる）", pair)
                  for pair in broken_bold(line)]
        if concise:
            for pattern, hint in WORDY_FORMS:
                found += [Finding("wordy", "hint", no, hint, _around(line, m))
                          for m in re.finditer(pattern, line)]

    if chars >= DENSITY_MIN_CHARS:
        bold = _per_1k(len(BOLD_PAIR.findall(body)), chars)
        if bold > BOLD_MAX_PER_1K:
            found.append(Finding("bold_density", "warn", 0, f"太字が1000字あたり {bold:.1f} 個（目安 {BOLD_MAX_PER_1K} 以下）"))
        neg = _per_1k(len(NEGATION.findall(body)), chars)
        if neg > NEGATION_MAX_PER_1K:
            found.append(Finding("negation_density", "warn", 0,
                                 f"「ではなく」が1000字あたり {neg:.2f} 回（目安 {NEGATION_MAX_PER_1K} 以下）。論点を担わない否定対比は肯定文にする"))
    surge = [w for w in SURGE_WORDS if w in body]
    if len(surge) >= SURGE_KINDS_MIN:
        found.append(Finding("surge_vocab", "info", 0, "2026年に急増した語が複数: " + "、".join(surge) + "（正当な用法なら残す）"))
    return {"findings": [asdict(f) for f in found], "chars": chars}


def main():
    parser = argparse.ArgumentParser(description="AI 生成日本語の書き直し候補を出す")
    parser.add_argument("path", help="対象ファイル（- なら標準入力）")
    parser.add_argument("--format", choices=["text", "json"], default="text")
    parser.add_argument("--concise", action="store_true", help="冗長な言い回しの候補（hint）も出す")
    args = parser.parse_args()
    sys.stdout.reconfigure(encoding="utf-8")  # Windows の既定（cp932）では文字化けする
    if args.path == "-":
        text = sys.stdin.read()
    else:
        with open(args.path, encoding="utf-8") as fp:
            text = fp.read()
    result = lint(text, concise=args.concise)
    if args.format == "json":
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    for f in result["findings"]:
        where = f"L{f['line']}" if f["line"] else "全体"
        print(f"{where} [{f['severity']}] {f['message']}")
        if f["snippet"]:
            print(f"  > {f['snippet']}")
    warns = sum(f["severity"] == "warn" for f in result["findings"])
    print(f"-- warn {warns} 件（{result['chars']}字）。候補であり、合否ではない。")
    return 1 if warns else 0


if __name__ == "__main__":
    sys.exit(main())
