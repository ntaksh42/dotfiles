"""new-sheet.py の単体テスト。python -m unittest claude/skills/report-to-user/tests/test_new_sheet.py"""
import importlib.util
import unittest
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
- [先に対応] 表の検出: `|---|` を誤検出 <script>
  根拠: reply-check.mjs:17
  対応: フェンスを先に除く
- 単体テスト: 通過

## 注意点
- 実機では未検証

## 付録: 実行ログ
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

    def test_rejects_bad_input(self):
        for src in ('結論だけ', '# 様子見 | x', '# 要対応 | x\n## 要判断: q\n他案: a\n', '# 要対応 | x\n## 雑多\n- a\n'):
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
        page = ns.build('# 対応不要 | ' + 'あ' * 81 + '\n', 'R')
        errors, _, _, _ = checker.check_sheet(page)
        self.assertTrue(any('結論' in e for e in errors), errors)

    def test_six_bullets_is_ng(self):
        page = ns.build('# 対応不要 | x\n' + ''.join(f'- 点{i}\n' for i in range(6)), 'R')
        errors, _, _, _ = checker.check_sheet(page)
        self.assertTrue(any('箇条書き' in e for e in errors), errors)

    def test_five_bullets_and_80_chars_pass(self):
        src = '# 対応不要 | ' + 'あ' * 80 + '\n' + ''.join(f'- 点{i}\n' for i in range(5))
        errors, _, _, _ = checker.check_sheet(ns.build(src, 'R'))
        self.assertEqual(errors, [])


if __name__ == '__main__':
    unittest.main()
