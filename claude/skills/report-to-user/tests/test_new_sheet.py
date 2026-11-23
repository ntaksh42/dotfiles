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
        self.assertIn('class="choice rec picked"', page)
        self.assertIn('class="item-act"', page)
        self.assertIn('class="item priority"', page)

    def test_escapes_html_outside_svg(self):
        page = ns.build(FULL, 'REPORT')
        self.assertIn('&lt;script&gt;', page)
        self.assertIn('ok 1 &lt;b&gt;', page)
        self.assertNotIn('<script>', page.split('</main>')[0])

    def test_two_columns_without_action(self):
        page = ns.build('# 対応不要 | 済んだ\n\n## 項目: 関数 / 役割\n- mkcd: 作って移動\n', 'R')
        self.assertNotIn('class="item-act"', page)
        self.assertIn('<strong class="item-name">mkcd</strong>', page)

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

    def test_lanes_put_priority_first(self):
        rows = '- [推測] g: 怪しい\n  対応: 確かめる\n' + ''.join(f'- r{i}: 軽い\n' for i in range(3)) + '- [優先] p: 直す\n  対応: 直す\n'
        page = ns.build('# 要対応 | x\n## 項目\n' + rows, 'R')
        body = page.split('<main>')[1]
        self.assertLess(body.index('>p<'), body.index('>r0<'))
        self.assertLess(body.index('>r0<'), body.index('>g<'))
        self.assertIn('class="item priority"', page)
        self.assertRegex(page, r'<details class="item priority"[^>]* open>')
        self.assertRegex(page, r'<details class="item guess"[^>]*>(?!.*open)')
        self.assertNotIn('ほかの', page)
        few = ns.build('# 要対応 | x\n## 項目\n- [優先] p: 直す\n- r: 軽い\n', 'R')
        self.assertNotIn('class="counts"', few)
        one = ns.build('# 対応不要 | x\n## 項目\n- a: b\n- c: d\n', 'R')
        self.assertNotIn('class="lane-h"', one)

    def test_no_figure_warning_for_decision_sheet(self):
        page = ns.build('# 要判断 1 件 | x\n次: 選ぶ\n## 要判断: q\n推奨: a — 理由\n', 'R')
        _, warns, _, _ = checker.check_sheet(page)
        self.assertFalse(any('図が無い' in w for w in warns), warns)
        plain = ns.build('# 対応不要 | x\n', 'R')
        self.assertTrue(any('図が無い' in w for w in checker.check_sheet(plain)[1]))

    def test_next_only_when_written(self):
        # 要判断があっても「次」の行は足さない。タイトルの「要判断 n 件」で伝わる
        page = ns.build('# 要判断 2 件 | x\n## 要判断: a\n推奨: a — r\n## 要判断: b\n推奨: b — r\n', 'R')
        self.assertNotIn('class="next"', page)
        self.assertIn('<h3>a</h3>', page)
        self.assertLess(page.index('reply-all-btn'), page.index('class="meta foot"'))
        page = ns.build('# 要判断 1 件 | x\n次: 先に再起動する\n## 要判断: a\n推奨: a — r\n', 'R')
        self.assertIn('先に再起動する', page)

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
        self.assertNotIn('<script', page.split('</main>')[0])

    def test_short_body_is_sheet_long_body_is_detail(self):
        short = ns.build('# 対応不要 | x\n## 背景\n' + 'あ' * 700 + '\n', 'R')
        self.assertIn('<!-- report-sheet -->', short)
        long = ns.build('# 対応不要 | x\n## 背景\n' + 'あ' * 801 + '\n', 'R')
        self.assertIn('<!-- report-sheet detail -->', long)
        # 付録の中は数えない
        appendix = ns.build('# 対応不要 | x\n## 付録: ログ\n' + 'あ' * 2000 + '\n', 'R')
        self.assertIn('<!-- report-sheet -->', appendix)

    def test_detail_skips_sheet_limits_but_keeps_title_limit(self):
        fig = '```svg\n<svg viewBox="0 0 9 9"><g class="key"><rect/></g></svg>\n```\n'
        src = '# 要対応 | x\n' + fig + ''.join(f'- 点{i}\n' for i in range(7)) + '## 背景\n' + 'あ' * 900 + '\n'
        errors, warns, _, _ = checker.check_sheet(ns.build(src, 'R'))
        self.assertEqual((errors, warns), ([], []))
        # 詳細でも図は求める
        _, warns, _, _ = checker.check_sheet(ns.build(src.replace(fig, ''), 'R'))
        self.assertTrue(any('図が無い' in w for w in warns), warns)
        long_title = ns.build('# 要対応 | ' + 'あ' * 61 + '\n## 背景\n' + 'い' * 900 + '\n', 'R')
        self.assertTrue(any('結論' in e for e in checker.check_sheet(long_title)[0]))

    def test_detail_has_no_toc(self):
        body = ''.join(f'## 節{i}\n' + 'あ' * 200 + '\n' for i in range(5))
        page = ns.build('# 対応不要 | x\n' + body, 'R')
        self.assertIn('<!-- report-sheet detail -->', page)
        self.assertNotIn('<nav class="toc">', page)

    def test_long_table_folds(self):
        rows = ''.join(f'| r{i} | v |\n' for i in range(18))
        page = ns.build('# 対応不要 | x\n## 表\n| a | b |\n|---|---|\n' + rows, 'R')
        self.assertIn('残り 3 行を表示', page)

    def test_svg_and_links_are_sanitized(self):
        src = ('# 対応不要 | x\n```svg\n<svg onload="alert(1)"><script>x</script><g class="key"><rect/></g></svg>\n```\n'
               '## 背景\n[悪い](javascript:alert(1)) と [良い](https://example.com)\n')
        page = ns.build(src, 'R')
        self.assertNotIn('onload', page)
        self.assertNotIn('<script>x', page.split('</main>')[0])
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

    # ---- 読んだ後に動くための仕掛け ----

    def test_evidence_links_existing_files_only(self):
        src = ('# 対応不要 | x\n## 項目\n- a: b\n'
               '  根拠: scripts/new-sheet.py:10 と missing.py:3 と `tests/test_new_sheet.py:1`\n')
        with mock.patch.object(ns, 'repo_root', return_value=ROOT):
            page = ns.build(src, 'R')
        self.assertRegex(page, r'href="vscode://file/[^"]*/scripts/new-sheet\.py:10"')
        self.assertRegex(page, r'href="vscode://file/[^"]*/tests/test_new_sheet\.py:1"')
        self.assertIn('<code>missing.py:3</code>', page)
        self.assertNotIn('missing.py:3"', page)

    def test_decision_rows_are_picked_not_copied(self):
        page = ns.build('# 要判断 1 件 | x\n## 要判断: 上限\n推奨: **5 行** — 理由\n他案: 8 行 — 利点 / 代償\n', 'R')
        # 案ごとのコピーボタンは無く、案の行を押して選ぶ。押す前は推奨が選ばれている
        self.assertNotIn('data-copy=', page)
        self.assertIn('class="choice rec picked" role="radio" tabindex="0" aria-checked="true" data-q="上限" data-name="5 行"', page)
        self.assertIn('class="choice alt" role="radio" tabindex="0" aria-checked="false" data-q="上限" data-name="8 行"', page)
        self.assertIn('role="radiogroup"', page)

    def test_diff_fence(self):
        page = ns.build('# 対応不要 | x\n## 差分\n```diff\n@@ -1 +1 @@\n-old\n+new\n>> [優先] ここが危ない\n ctx\n```\n', 'R')
        for cls in ('d-hunk', 'd-del', 'd-ctx', 'd-target priority d-add', 'd-note priority'):
            self.assertIn(f'class="{cls}"', page)
        self.assertIn('<span class="tag priority">優先</span> ここが危ない', page)
        self.assertIn('<pre class="diff numbered">', page)
        self.assertIn('<span class="ln">1</span><span class="tx">-old</span>', page)
        self.assertIn('<span class="ln">2</span><span class="tx"> ctx</span>', page)

    def test_diff_fence_with_path_line_header(self):
        src = '# 対応不要 | x\n## 箇所\n```diff\n@@ scripts/new-sheet.py:10 @@\n a\n b\n>> [推測] ここ\n```\n'
        with mock.patch.object(ns, 'repo_root', return_value=ROOT):
            page = ns.build(src, 'R')
        self.assertRegex(page, r'<div class="d-hunk">@@ <a class="src" href="vscode://file/[^"]*new-sheet\.py:10"')
        self.assertIn('<div class="d-target guess d-ctx"><span class="ln">11</span>', page)
        plain = ns.build('# 対応不要 | x\n## 箇所\n```diff\n@@ どこか @@\n a\n```\n', 'R')
        self.assertIn('<pre class="diff">', plain)  # 行が分からない見出しでは番号を出さない
        self.assertIn(r".join('\n')", page)  # JS の文字列の中で改行文字にならない

    # ---- 開く・判断する・残す ----

    def test_default_meta_has_time_and_head(self):
        with mock.patch.object(ns, 'git_head', return_value='main@abc1234'), \
                mock.patch.object(ns, 'repo_name', return_value='repo'):
            meta = ns.default_meta('sheet', 'bug')
            self.assertRegex(meta, r'^REPORT · \d{4}-\d\d-\d\d \d\d:\d\d · repo · main@abc1234$')
            self.assertIn('不具合 · bug001', ns.default_meta('detail', 'bug', 'bug001'))

    def test_report_data_and_action_row(self):
        src = '# 要対応 | x\n## 項目\n- [優先] 表: 誤検出\n  根拠: a.mjs:3\n  対応: **先に**除く\n- 他: ok\n'
        page = ns.build(src, 'R')
        data = ns.DATA_RE.search(page).group(1)
        self.assertIn('"state": "要対応"', data)
        self.assertIn('"key": "表"', data)
        self.assertIn('data-act="「表」を対応して: 先に除く (根拠: a.mjs:3)"', page)
        self.assertEqual(page.count('data-act='), 1)
        self.assertIn('@media print', page)
        self.assertIn('beforeprint', page)
        self.assertNotIn('localStorage', page)  # 済みのチェックは外した
        self.assertNotIn('type = \'checkbox\'', page)

    def test_item_keys_unique_by_name(self):
        src = '# 対応不要 | x\n## 項目\n- 解析: 入力が空だと落ちる\n- 解析: 入力が空だと落ちる別件\n'
        ctx = {}
        ns.render_body(src, None, ctx)
        self.assertEqual([it['key'] for it in ctx['items']], ['解析', '解析#2'])

    def test_diff_against_previous(self):
        src = '# 対応不要 | x\n## 項目\n- 残る: 書き直した\n- 足した: 新しい\n'
        page = ns.build(src, 'R', prev=['残る', '消えた'])
        self.assertEqual(page.count('<span class="tag tag-blue">新</span>'), 1)  # 内容を書き直した行は新でない
        self.assertIn('前回のシートにあって今回ない 1 件', page)
        self.assertIn('<li>消えた</li>', page)
        self.assertNotIn('tag-blue">新', ns.build(src, 'R'))  # 前回が無ければ札を出さない

    def test_gone_rows_counted_once_per_page(self):
        src = '# 対応不要 | x\n## 項目\n- A: 1\n## 項目: 名前 / 中身\n- B: 2\n'
        page = ns.build(src, 'R', prev=['A', 'B', 'C'])
        self.assertEqual(page.count('class="gone"'), 1)
        self.assertIn('前回のシートにあって今回ない 1 件', page)
        self.assertIn('<li>C</li>', page)
        no_items = ns.build('# 対応不要 | x\n## 背景\nあ\n', 'R', prev=['A'])
        self.assertIn('前回のシートにあって今回ない 1 件', no_items)

    def test_load_previous_by_name(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.dict(os.environ, {'ORCA_CHAT_SCRATCH_DIR': d}):
            self.assertIsNone(ns.load_previous(name='t'))
            (Path(d) / 't-ab12.html').write_text(ns.build('# 対応不要 | x\n## 項目\n- a: b\n', 'R'), encoding='utf-8')
            (Path(d) / 'tx-ab12.html').write_text('x', encoding='utf-8')
            self.assertEqual(ns.load_previous(name='t'), ['a'])

    def test_load_previous_from_kept_reports(self):
        # Orca の外の --save: scratch に写しが無くても、保存先から同じ id の最新の版を探す
        with tempfile.TemporaryDirectory() as d, mock.patch.dict(os.environ, {'ORCA_CHAT_SCRATCH_DIR': str(Path(d) / 'none')}):
            base = Path(d) / 'reports'
            (base / 'bugs').mkdir(parents=True)
            scratch = Path(d) / 'scratch'
            scratch.mkdir()
            files = [scratch / 'demo-ab12.html', base / 'bugs' / 'bug001.html', base / 'bugs' / 'bug002.html']
            for n, (p, name) in enumerate(zip(files, ('scratch', 'old', 'new'))):
                ctx = {}
                body, concl, toc, _ = ns.render_body(f'# 対応不要 | x\n## 項目\n- {name}: b\n', None, ctx)
                p.write_text(ns.wrap(body, concl, toc, 'sheet', 'R', ctx, 'bug', 'demo'), encoding='utf-8')
                os.utime(p, (1_700_000_000 + n, 1_700_000_000 + n))
            with mock.patch.dict(os.environ, {'ORCA_CHAT_SCRATCH_DIR': str(scratch)}):
                # scratch の写しより、後に書いた保存先の版を前回とする
                self.assertEqual(ns.load_previous(name='demo', base=base), ['new'])
                self.assertIsNone(ns.load_previous(name='other', base=base))

    def test_sheet_id_prefers_name(self):
        self.assertEqual(ns.sheet_id('x', 'demo', 'bugs/bug002'), 'demo')
        self.assertEqual(ns.sheet_id('x', None, 'bugs/bug002'), 'bugs/bug002')

    def test_read_data_rejects_bad_shapes(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'a.html'
            for raw in ('[1]', '{"items": [{"name": "no key"}, 3, {"key": "k", "label": 5}]}'):
                p.write_text(f'<script type="application/json" id="report-data">{raw}</script>', encoding='utf-8')
                data = ns.read_data(p)
                if raw == '[1]':
                    self.assertIsNone(data)
                else:
                    self.assertEqual(data['items'], [{'key': 'k'}])
            (Path(d) / 'b.html').write_text('<script type="application/json" id="report-data">[1, 2]</script>', encoding='utf-8')
            self.assertIn('保存したレポート 2 件', ns.write_index(Path(d)).read_text(encoding='utf-8'))

    def test_embedded_data_does_not_trip_checker(self):
        src = "# 対応不要 | `<input type='radio'>` と <!-- <script> と " + '<li>' * 6 + '\n'
        page = ns.build(src, 'R')
        self.assertNotIn('<input', ns.DATA_RE.search(page).group(1))
        self.assertEqual(page.count('</script>'), 2)  # report-data と SHEET_JS だけ
        errors, _, _, _ = checker.check_sheet(page)
        self.assertEqual(errors, [])
        self.assertIn('"concl": "`\\u003cinput', page)

    def test_excerpt_numbers_every_line_and_no_newline_marker(self):
        page = ns.build('# 対応不要 | x\n## 箇所\n```diff\n@@ f.py:10 @@\n-x = 1\n y\n```\n', 'R')
        self.assertIn('<span class="ln">10</span><span class="tx">-x = 1</span>', page)
        self.assertIn('<span class="ln">11</span><span class="tx"> y</span>', page)
        uni = ns.build('# 対応不要 | x\n## 差分\n```diff\n@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b\n c\n```\n', 'R')
        self.assertIn('<span class="ln">2</span><span class="tx"> c</span>', uni)

    def test_decision_first_row_must_be_recommendation_by_kind(self):
        with self.assertRaises(ns.InputError):
            ns.build('# 要判断 1 件 | x\n## 要判断: A\n他案: rec を含む — p / q\n', 'R')

    def test_one_reply_button_below_last_decision(self):
        one = '# 要判断 1 件 | x\n## 要判断: A\n推奨: a — r\n'
        self.assertEqual(ns.build(one, 'R').count('class="copy reply-all-btn"'), 1)
        two = one.replace('1 件', '2 件') + '## 要判断: B\n推奨: b — r\n他案: c — p / q\n'
        page = ns.build(two, 'R')
        self.assertEqual(page.count('class="copy reply-all-btn"'), 1)
        self.assertLess(page.index('data-q="B"'), page.index('reply-all-btn'))
        self.assertIn('data-q="B" data-name="c"', page)

    def test_jump_bar_only_in_detail(self):
        src = '# 要判断 1 件 | x\n## 要判断: A\n推奨: a — r\n## 項目\n- [優先] p: q\n'
        self.assertIn('<nav class="jump"><a href="#sec-1">要判断 1</a> <a href="#item-1">優先 1</a></nav>',
                      ns.build(src, 'R', layout='detail'))
        self.assertNotIn('<nav class="jump">', ns.build(src, 'R'))

    def test_write_index(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d)
            (base / 'bugs').mkdir()
            (base / 'bugs' / 'bug001.html').write_text(
                ns.build('# 要対応 | 落ちる原因\n## 項目\n- [優先] 解析: 壊れる\n  対応: 直す\n- 他: ok\n', 'R'), encoding='utf-8')
            (base / 'old #3%.html').write_text('<title>古い報告</title>', encoding='utf-8')
            page = ns.write_index(base).read_text(encoding='utf-8')
        self.assertIn('保存したレポート 2 件', page)
        self.assertIn('href="bugs/bug001.html"', page)
        self.assertIn('href="old%20%233%25.html"', page)
        self.assertIn('古い報告', page)
        self.assertIn('<th scope="row">解析</th><td>直す</td>', page)
        self.assertNotIn('<th scope="row">他</th>', page)

    def test_write_index_takes_open_items_from_latest_version(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d)
            for n, created in ((1, '2026-01-01T00:00'), (2, '2026-02-01T00:00')):
                page = ns.wrap(*ns.render_body(f'# 要対応 | 版{n}\n## 項目\n- [優先] 甲{n}: 壊れる\n', None, ctx := {})[:3],
                               'sheet', 'R', ctx, 'bug', 'demo')
                page = page.replace(ns.DATA_RE.search(page).group(1).split('"created": "')[1].split('"')[0], created, 1)
                (base / f'bug00{n}.html').write_text(page, encoding='utf-8')
            index = ns.write_index(base).read_text(encoding='utf-8')
        self.assertIn('<th scope="row">甲2</th>', index)
        self.assertNotIn('<th scope="row">甲1</th>', index)
        self.assertIn('版1', index)  # 古い版も一覧の表には残す

    def test_checker_warns_figure_copying_items(self):
        svg = ''.join(f'<text>{n}</text>' for n in ('alpha', 'beta', 'gamma'))
        src = (f'# 対応不要 | x\n```svg\n<svg viewBox="0 0 9 9"><g class="key"><rect/></g>{svg}</svg>\n```\n'
               '## 項目\n- alpha: 1\n- beta: 2\n- gamma: 3\n')
        _, warns, _, _ = checker.check_sheet(ns.build(src, 'R'))
        self.assertTrue(any('書き写し' in w for w in warns), warns)
        # 3 つのうち 2 つ (6 割以上) でも警告する
        _, warns, _, _ = checker.check_sheet(ns.build(src.replace('<text>gamma</text>', ''), 'R'))
        self.assertTrue(any('書き写し' in w for w in warns), warns)
        _, warns, _, _ = checker.check_sheet(ns.build(src.replace('<text>beta</text><text>gamma</text>', ''), 'R'))
        self.assertFalse(any('書き写し' in w for w in warns), warns)

    def test_checker_wants_figures_for_heavy_findings_in_detail(self):
        fig = '```svg\n<svg viewBox="0 0 9 9"><g class="key"><rect/></g></svg>\n```\n'
        src = '# 要対応 | x\n' + fig + '## 項目\n- [優先] a: b\n- [優先] c: d\n## 背景\n' + 'あ' * 900 + '\n'
        _, warns, _, _ = checker.check_sheet(ns.build(src, 'R'))
        self.assertTrue(any('図が 1 枚' in w for w in warns), warns)
        _, warns, _, _ = checker.check_sheet(ns.build(src + '## 何が起きるか\n' + fig, 'R'))
        self.assertFalse(any('図が 1 枚' in w for w in warns), warns)


if __name__ == '__main__':
    unittest.main()
