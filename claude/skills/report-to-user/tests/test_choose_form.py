"""choose-form.py の単体テスト。python -m unittest claude/skills/report-to-user/tests/test_choose_form.py"""
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('choose_form', ROOT / 'scripts' / 'choose-form.py')
cf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cf)


class ChooseFormTest(unittest.TestCase):
    def test_short_answer_is_chat(self):
        self.assertEqual(cf.choose('なぜ動かない？', items=0, chars=150, lines=2)[0], '会話')

    def test_one_decision_stays_in_chat(self):
        form, reason = cf.choose('どうすべき？', chars=120, lines=3, decisions=1)
        self.assertEqual(form, '会話')
        self.assertIn('[判断]', reason)

    def test_list_questions_go_to_sheet(self):
        for q in ('ほかに改善ネタはない？', 'コマンドの一覧がほしい', '手順を教えて', '何がある？'):
            self.assertEqual(cf.choose(q, chars=50)[0], '報告シート', q)

    def test_list_word_with_one_item_stays_in_chat(self):
        for q in ('他に設定ファイルある？', 'テスト通った？まとめて'):
            form, reason = cf.choose(q, items=1, chars=60, lines=1)
            self.assertEqual(form, '会話', q)
            self.assertIn('1 項目', reason)
        self.assertEqual(cf.choose('他に設定ファイルある？', items=2, chars=60)[0], '報告シート')

    def test_list_kinds_go_to_sheet(self):
        for k in ('list', 'compare', 'steps', 'commands'):
            self.assertEqual(cf.choose(kind=k)[0], '報告シート', k)

    def test_margin_below_hook_limits(self):
        # 今日 hook に差し戻された 307 字・404 字の返信は、どちらもシートになる
        self.assertEqual(cf.choose(chars=307)[0], '報告シート')
        self.assertEqual(cf.choose(items=4)[0], '報告シート')
        self.assertEqual(cf.choose(lines=4)[0], '報告シート')
        self.assertEqual(cf.choose(decisions=2)[0], '報告シート')
        self.assertEqual(cf.choose(chars=200, lines=3, items=3)[0], '会話')

    def test_html_report_request(self):
        for q in ('結果を HTML レポートにまとめて保存して', 'レポートを保存して', '調査結果をHTMLにまとめて'):
            form, why = cf.choose(q, items=1)
            self.assertEqual(form, '報告シート', q)
            self.assertIn('--save', why, q)
        self.assertIn('--save', cf.choose(kind='report')[1])

    def test_special_forms(self):
        self.assertEqual(cf.choose(kind='ui')[0], '比較シート')
        self.assertEqual(cf.choose(kind='manuscript', chars=5000)[0], '原稿ファイル')


if __name__ == '__main__':
    unittest.main()
