# skill の棚卸し

使っていない skill を見つけ、Claude の skill 一覧から外して、毎ターンのコンテキスト消費を減らす手順。skill は消さずに `skillOverrides` で一覧での扱いを変えるので、いつでも戻せる。

## 1. 集める

どちらも `claude -p` で動く。Git Bash では先頭の `/` がパスに変換されるので `MSYS_NO_PATHCONV=1` を付ける。PowerShell では不要。

```bash
MSYS_NO_PATHCONV=1 claude -p "/skill-doctor"   # skill ごとの一覧消費、7 日間のトークン、使用回数、最終使用日
MSYS_NO_PATHCONV=1 claude -p "/context"        # Skills 行の合計と割合、skill ごとのトークン
```

- `/context` の Skills 行は、一覧の予算を当てたあとの大きさで、モデルが実際に受け取る量と同じ
- `/skill-doctor` の使用回数は、このマシンの直近 7 日間のセッションから数えたもの。別のマシンでの使用は入らない

## 2. 外し方を決める

`skillOverrides` の値は 4 つある。指定しない skill は `on` と同じ扱いになる。

| 値 | Claude の一覧 | `/` メニュー | 向くもの |
|---|---|---|---|
| `on` | 名前と説明 | 出る | 自動で使ってほしいもの |
| `name-only` | 名前だけ | 出る | まれに使い、名前で用途が分かるもの |
| `user-invocable-only` | 出ない | 出る | 明示的に呼ぶときだけ使うもの、この環境に道具が無いもの |
| `off` | 出ない | 出ない | ユーザーが不要と言ったものだけ |

判断の目安:

- 説明に「明示的に頼まれたときだけ使う」とある skill は `user-invocable-only` にする
- デスクトップアプリ専用など、この環境で道具が使えない skill は `user-invocable-only` にする
- Office ファイルや PDF のように、扱う対象が来たときだけ要る skill は `name-only` にする
- 出力の質を保つための skill（hook が読み込みを求めるもの、検証やデバッグの手順）は、使用回数が 0 でも `on` のまま残す
- 用途が重なる skill が複数あるときは、よく使う方を残して他を `name-only` にする
- `off` は提案しない。ユーザーが求めたときだけ使う

キーの書き方:

- 自作や `~/.claude/skills` の skill は名前だけを書く（例: `crit`）
- claude.ai から同期された skill は `anthropic-skills:<名前>` と書く
- plugin の skill は個別に外せない。plugin ごと `/plugin` で無効にする案として報告する

一覧の予算も確かめる。予算は既定でコンテキストの 1% で、超えると使用回数の少ない skill から説明が落ちる。出力の質を保つ skill は使用回数が少ないことが多く、先に落ちやすい。`/context` の Skills 行が 1% に近い、またはコンテキストの小さいモデルを使うことがあるなら、`skillListingBudgetFraction` を 0.03 程度に上げる案を添える。

## 3. 見せて承認を取る

report-to-user のシートで、外す候補を値ごとの表にして見せる。列は skill、今の使用回数、変える値、理由にする。変更前の Skills 行のトークン数も書く。承認を得るまで書き換えない。

## 4. 適用する

- 実際に読まれる user 設定は、`CLAUDE_CONFIG_DIR` があればその下の `settings.json`、無ければ `~/.claude/settings.json`。両方あるなら両方に入れる
- 既存の `skillOverrides` に追加する形でマージする。ファイル全体を書き直さず、元の改行コード（CRLF か LF）を保つ。書き換える前に控えを取る
- 恒久化するため、正本の `<dotfiles>/claude/settings.template.json` にも同じ内容を入れる（`install.ps1` がテンプレートで settings.json を上書きするため）

## 5. 確かめる

- 書き換えたファイルを JSON として読み込めるか確かめる
- `/context` を再実行し、Skills 行が減ったこと、`user-invocable-only` にした skill が一覧から消えたこと、`name-only` にした skill が 20 トークン未満になったことを確かめる
- 報告には変更前後の Skills 行のトークン数と、値ごとの件数を書く

戻すときは `skillOverrides` から該当のキーを消す。
