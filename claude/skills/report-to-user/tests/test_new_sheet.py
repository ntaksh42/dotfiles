"""new-sheet.py の単体テスト。python -m unittest claude/skills/report-to-user/tests/test_new_sheet.py"""
import importlib.util
import os
import tempfile
import unittest
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('new_sheet', ROOT / 'scripts' / 'new-sheet.py')
ns = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ns)
cspec = importlib.util.spec_from_file_location('check_sheet', ROOT / 'assets' / 'check-sheet.py')
checker = importlib.util.module_from_spec(cspec)
cspec.loader.exec_module(checker)

FULL = """# 要判断 1 件 | 閾値だけ決めてほしい
テスト 12 件は通過した。
次: 閾値を選ぶ

```svg
<svg viewBox="0 0 100 50"><g class="key"><rect x="1" y="1" width="20" height="20"/></g></svg>
```

## 要判断: 行数の上限
推奨: **5 行のまま** — 誤検知 0 件
他案: 8 行 — 止まりにくい / 長文が残る

## 項目
- [優先] 表の検出: `|---|` を誤検出 <script>
  根拠: reply-check.mjs:17
  対応: フェンスを先に除く
- 単体テスト: 通過

## 注意点
- 実機では未検証

## 付録: 調査の経緯
ok 1 <b>
"""


class NewSheetTest(unittest.TestCase):
    def test_full_sheet_passes_checker(self):
        page = ns.build(FULL, 'REPORT')
        errors, warns, _, _ = checker.check_sheet(page)
        self.assertEqual(errors, [])
        self.assertEqual(warns, [])
        self.assertIn('class="state ask"', page)
        self.assertIn('class="choice rec"', page)
        self.assertIn('<th>対応案</th>', page)
        self.assertIn('class="tag priority"', page)

    def test_escapes_html_outside_svg(self):
        page = ns.build(FULL, 'REPORT')
        self.assertIn('&lt;script&gt;', page)
        self.assertIn('ok 1 &lt;b&gt;', page)
        self.assertNotIn('<script>', page)

    def test_two_columns_without_action(self):
        page = ns.build('# 対応不要 | 済んだ\n\n## 項目: 関数 / 役割\n- mkcd: 作って移動\n', 'R')
        self.assertNotIn('対応案', page)
        self.assertIn('<th>関数</th>', page)

    def test_no_next_box_without_next_line(self):
        page = ns.build('# 対応不要 | 済んだ\n', 'R')
        self.assertNotIn('class="next"', page)
        self.assertIn('class="next"', ns.build(FULL, 'R'))

    def test_rejects_three_column_names(self):
        with self.assertRaises(ns.InputError):
            ns.build('# 要対応 | x\n## 項目: 指摘 / 根拠 / 対応案\n- a: b\n', 'R')

    def test_evidence_renders_inline_links(self):
        page = ns.build('# 対応不要 | x\n## 項目\n- a: b\n  根拠: [仕様](https://example.com/s) と `f.py:3`\n', 'R')
        self.assertIn('<a href="https://example.com/s">仕様</a>', page)
        self.assertIn('<code>f.py:3</code>', page)
        self.assertNotIn('[仕様]', page)

    def test_rejects_bad_input(self):
        for src in ('結論だけ', '# 様子見 | x', '# 要対応 | x\n## 要判断: q\n他案: a\n'):
            with self.assertRaises(ns.InputError, msg=src):
                ns.build(src, 'R')

    def test_rejects_bad_title(self):
        for src in ('# 要対応 結論に区切りが無い', '# 要判断 n 件 | x', '# | 状態の語が無い'):
            with self.assertRaises(ns.InputError, msg=src):
                ns.build(src, 'R')

    def test_rejects_bad_decision(self):
        for src in ('# 要判断 1 件 | x\n## 要判断: q\n',
                    '# 要判断 1 件 | x\n## 要判断: q\n推奨: a\n理由をここに書く\n'):
            with self.assertRaises(ns.InputError, msg=src):
                ns.build(src, 'R')

    def test_rejects_bad_items(self):
        for src in ('# 要対応 | x\n## 項目\n',
                    '# 要対応 | x\n## 項目\n- 区切りの無い項目\n',
                    '# 要対応 | x\n## 項目\n- a: b\n  メモ: c\n',
                    '# 要対応 | x\n## 項目\n- a: b\n地の文\n'):
            with self.assertRaises(ns.InputError, msg=src):
                ns.build(src, 'R')

    def test_long_title_is_ng(self):
        page = ns.build('# 対応不要 | ' + 'あ' * 61 + '\n', 'R')
        errors, _, _, _ = checker.check_sheet(page)
        self.assertTrue(any('結論' in e for e in errors), errors)

    def test_six_bullets_is_ng(self):
        page = ns.build('# 対応不要 | x\n' + ''.join(f'- 点{i}\n' for i in range(6)), 'R')
        errors, _, _, _ = checker.check_sheet(page)
        self.assertTrue(any('箇条書き' in e for e in errors), errors)

    def test_five_bullets_and_60_chars_pass(self):
        src = '# 対応不要 | ' + 'あ' * 60 + '\n' + ''.join(f'- 点{i}\n' for i in range(5))
        errors, _, _, _ = checker.check_sheet(ns.build(src, 'R'))
        self.assertEqual(errors, [])

    def test_confirmed_label_shows_no_tag(self):
        page = ns.build('# 対応不要 | x\n## 項目\n- [確認済み] a: b\n- [未検証] c: d\n', 'R')
        self.assertNotIn('>確認済み<', page)
        self.assertIn('class="tag unverified"', page)

    def test_folds_rest_when_priority_and_many_rows(self):
        rows = '- [優先] p: 直す\n' + ''.join(f'- r{i}: 軽い\n' for i in range(5))
        page = ns.build('# 要対応 | x\n## 項目\n' + rows, 'R')
        self.assertIn('<summary>ほかの 5 件</summary>', page)
        self.assertLess(page.index('>p<'), page.index('<details'))
        few = ns.build('# 要対応 | x\n## 項目\n- [優先] p: 直す\n- r: 軽い\n', 'R')
        self.assertNotIn('<details', few)

    def test_no_figure_warning_for_decision_sheet(self):
        page = ns.build('# 要判断 1 件 | x\n次: 選ぶ\n## 要判断: q\n推奨: a — 理由\n', 'R')
        _, warns, _, _ = checker.check_sheet(page)
        self.assertFalse(any('図が無い' in w for w in warns), warns)
        plain = ns.build('# 対応不要 | x\n', 'R')
        self.assertTrue(any('図が無い' in w for w in checker.check_sheet(plain)[1]))

    def test_next_is_filled_from_decisions(self):
        page = ns.build('# 要判断 2 件 | x\n## 要判断: a\n推奨: a — r\n## 要判断: b\n推奨: b — r\n', 'R')
        self.assertIn('下の 2 問に答える', page)
        page = ns.build('# 要判断 1 件 | x\n次: 先に再起動する\n## 要判断: a\n推奨: a — r\n', 'R')
        self.assertIn('先に再起動する', page)
        self.assertNotIn('問に答える', page)

    def test_filler_next_is_ng(self):
        for nxt in ('特になし', '特になし。push 済み', 'なし', '引き続き注視'):
            errors = checker.check_sheet(ns.build(f'# 対応不要 | x\n次: {nxt}\n', 'R'))[0]
            self.assertTrue(any('次:' in e for e in errors), (nxt, errors))
        for nxt in ('閾値を選ぶ', '不要なファイルを消す'):
            errors = checker.check_sheet(ns.build(f'# 要対応 | x\n次: {nxt}\n', 'R'))[0]
            self.assertEqual(errors, [], nxt)

    # ---- 自由な節と、形・種別・保存先の静的な判定 ----

    def test_free_section_renders_markdown(self):
        src = ('# 対応不要 | x\n## 背景\n段落の文。\n\n### 小見出し\n- a\n  - a1\n1. b\n'
               '| 列 | 値 |\n|---|---|\n| p \\| q | [!red 重大] |\n> 引用\n:::bar 進捗|85\n'
               '```js\nx < 1\n```\n')
        page = ns.build(src, 'R')
        self.assertIn('<h2 class="sec">背景</h2>', page)
        self.assertIn('<ul><li>a<ul><li>a1</li></ul></li></ul><ol><li>b</li></ol>', page)
        self.assertIn('<td>p | q</td>', page)
        self.assertIn('class="tag tag-red">重大</span>', page)
        self.assertIn('<blockquote>引用</blockquote>', page)
        self.assertIn('width:85%', page)
        self.assertIn('<pre data-lang="js"><code>x &lt; 1</code></pre>', page)
        self.assertNotIn('<script', page)

    def test_short_body_is_sheet_long_body_is_detail(self):
        short = ns.build('# 対応不要 | x\n## 背景\n' + 'あ' * 700 + '\n', 'R')
        self.assertIn('<!-- report-sheet -->', short)
        long = ns.build('# 対応不要 | x\n## 背景\n' + 'あ' * 801 + '\n', 'R')
        self.assertIn('<!-- report-sheet detail -->', long)
        # 付録の中は数えない
        appendix = ns.build('# 対応不要 | x\n## 付録: ログ\n' + 'あ' * 2000 + '\n', 'R')
        self.assertIn('<!-- report-sheet -->', appendix)

    def test_detail_skips_sheet_limits_but_keeps_title_limit(self):
        src = '# 要対応 | x\n' + ''.join(f'- 点{i}\n' for i in range(7)) + '## 背景\n' + 'あ' * 900 + '\n'
        errors, warns, _, _ = checker.check_sheet(ns.build(src, 'R'))
        self.assertEqual((errors, warns), ([], []))
        long_title = ns.build('# 要対応 | ' + 'あ' * 61 + '\n## 背景\n' + 'い' * 900 + '\n', 'R')
        self.assertTrue(any('結論' in e for e in checker.check_sheet(long_title)[0]))

    def test_detail_has_toc_from_five_sections(self):
        body = ''.join(f'## 節{i}\n' + 'あ' * 200 + '\n' for i in range(5))
        page = ns.build('# 対応不要 | x\n' + body, 'R')
        self.assertIn('<nav class="toc">', page)
        self.assertIn('<a href="#sec-1">節0</a>', page)
        self.assertNotIn('class="toc"', ns.build('# 対応不要 | x\n## 節\nあ\n', 'R'))

    def test_long_table_folds(self):
        rows = ''.join(f'| r{i} | v |\n' for i in range(18))
        page = ns.build('# 対応不要 | x\n## 表\n| a | b |\n|---|---|\n' + rows, 'R')
        self.assertIn('残り 3 行を表示', page)

    def test_svg_and_links_are_sanitized(self):
        src = ('# 対応不要 | x\n```svg\n<svg onload="alert(1)"><script>x</script><g class="key"><rect/></g></svg>\n```\n'
               '## 背景\n[悪い](javascript:alert(1)) と [良い](https://example.com)\n')
        page = ns.build(src, 'R')
        self.assertNotIn('onload', page)
        self.assertNotIn('<script>x', page)
        self.assertNotIn('javascript:', page)
        self.assertIn('<a href="https://example.com">良い</a>', page)

    def test_mermaid_adds_script_only_when_used(self):
        page = ns.build('# 対応不要 | x\n## 図\n```mermaid\nflowchart LR\n A-->B\n```\n', 'R')
        self.assertIn('<pre class="mermaid">', page)
        self.assertIn('mermaid.esm.min.mjs', page)
        self.assertNotIn('mermaid.esm', ns.build('# 対応不要 | x\n', 'R'))

    def test_infer_kind(self):
        cases = {'XSS の脆弱性を見つけた': 'security', 'PR #12 のレビュー結果': 'review',
                 'ログインが失敗する原因': 'bug', '生成器を統合する案': 'proposal',
                 'ライブラリの比較': 'research', 'ディレクトリ構成': 'investigation'}
        for words, kind in cases.items():
            self.assertEqual(ns.infer_kind(words), kind, words)

    def test_keep_path_numbers_from_existing(self):
        with tempfile.TemporaryDirectory() as d:
            conf = {'base_dir': d, 'subdirs': {}, 'prefixes': {}}
            first = ns.keep_path('bug', conf)
            self.assertEqual(first, Path(d) / 'bugs' / 'bug001.html')
            first.parent.mkdir(parents=True)
            (first.parent / 'bug007.html').write_text('x')
            (first.parent / 'bug008-mockup.html').write_text('x')
            self.assertEqual(ns.keep_path('bug', conf).name, 'bug008.html')

    def test_plan_paths(self):
        keep = Path('/k/bug001.html')
        with mock.patch.dict(os.environ, {'ORCA_CHAT_SCRATCH_DIR': ''}), \
                mock.patch.object(ns, 'keep_path', return_value=keep):
            sheet = ns.plan_paths('sheet', 'bug')
            self.assertEqual(len(sheet), 1)
            self.assertNotEqual(sheet[0], keep)
            self.assertEqual(ns.plan_paths('detail', 'bug'), [keep])
            self.assertEqual(ns.plan_paths('sheet', 'bug', save=True), [keep])
            self.assertEqual(ns.plan_paths('detail', 'bug', out='x.html'), [Path('x.html').resolve()])
        with mock.patch.dict(os.environ, {'ORCA_CHAT_SCRATCH_DIR': '/s'}), \
                mock.patch.object(ns, 'keep_path', return_value=keep):
            paths = ns.plan_paths('detail', 'bug', name='t')
            self.assertEqual(paths[0], keep)
            self.assertEqual(paths[1].parent, Path('/s'))


if __name__ == '__main__':
    unittest.main()
