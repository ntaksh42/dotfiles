import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
import jp_lint as J  # noqa: E402


def rules(text):
    return {f["rule"] for f in J.lint(text)["findings"]}


class MetaphorVerb(unittest.TestCase):
    def test_detects_each_form(self):
        for s in ["設定の誤りは黙って無視されます。",
                  "夜間の処理が静かに止まっていました。",
                  "安全側に倒す方針にしました。",
                  "調査に半日溶かしてしまいました。",
                  "不具合を一つずつ潰していきます。",
                  "この設定が地味に効いてきます。",
                  "内部実装まで踏み込んで調べました。"]:
            self.assertIn("metaphor_verb", rules(s), s)

    def test_keeps_literal_and_technical_uses(self):
        for s in ["ドアが壊れました。", "雪が溶けました。", "キャッシュが効いています。",
                  "夜のうちに精度が落ちました。", "静かに部屋を出ました。", "黙って頷きました。",
                  "気が重い一日でした。", "友人の肩を持ちました。", "ジョブを並列で回します。"]:
            self.assertNotIn("metaphor_verb", rules(s), s)


class Symbols(unittest.TestCase):
    def test_dash(self):
        self.assertIn("dash", rules("設計――とりわけ境界――が重要です。"))

    def test_broken_bold(self):
        self.assertIn("broken_bold", rules("次に**「保留」**を書きます。"))
        self.assertNotIn("broken_bold", rules("次に「**保留**」を書きます。"))
        self.assertNotIn("broken_bold", rules("これは**必須**です。"))

    def test_ignores_code_and_quote(self):
        text = "説明です。\n```\n設計――境界――\n```\n> 引用――です\n"
        self.assertEqual(rules(text), set())


class Density(unittest.TestCase):
    def test_short_text_skips_density(self):
        self.assertNotIn("bold_density", rules("**a** **b** **c** **d**"))

    def test_long_text_flags_bold(self):
        body = ("これは説明の文です。" * 90) + "**あ****い**".replace("****", "** **") * 10
        self.assertIn("bold_density", rules(body))

    def test_negation_density(self):
        body = "AではなくBです。" * 40 + "説明です。" * 120
        self.assertIn("negation_density", rules(body))


class Concise(unittest.TestCase):
    WORDY = "確認を行うことができます。まず最初に設定を開きます。"

    def test_off_by_default(self):
        self.assertNotIn("wordy", rules(self.WORDY))

    def test_hints_when_enabled(self):
        r = J.lint(self.WORDY, concise=True)["findings"]
        self.assertEqual({f["severity"] for f in r if f["rule"] == "wordy"}, {"hint"})
        self.assertGreaterEqual(sum(f["rule"] == "wordy" for f in r), 3)

    def test_hints_do_not_fail_exit_code(self):
        import subprocess, tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as fp:
            fp.write(self.WORDY)
        script = os.path.join(os.path.dirname(__file__), "..", "scripts", "jp_lint.py")
        p = subprocess.run([sys.executable, script, fp.name, "--concise"], capture_output=True)
        os.unlink(fp.name)
        self.assertEqual(p.returncode, 0)


class Surge(unittest.TestCase):
    def test_needs_three_kinds(self):
        self.assertNotIn("surge_vocab", rules("実測と照合を行う。"))
        self.assertIn("surge_vocab", rules("実測と照合と落とし穴の話。"))


if __name__ == "__main__":
    unittest.main()
