# VSCode 設定

Visual Studio のショートカットに寄せた VSCode 設定一式。`.NET` / C++ / Python 開発を想定。

## ファイル構成

| ファイル | 内容 |
|---|---|
| `settings.json` | ユーザー設定。`%APPDATA%\Code\User\settings.json` へ配置 |
| `keybindings.json` | Visual Studio キーマップの差分補完。`%APPDATA%\Code\User\keybindings.json` へ配置 |
| `extensions.txt` | 拡張機能リスト（1 行 1 ID、`#` はコメント） |

## セットアップ

`settings.json` と `keybindings.json` は `Install-DevTools` が配置します（既存ファイルが
異なる場合は差分を表示して上書きを確認し、`.backup.<日時>` を残します）。配置後は VSCode を
再起動してください。拡張機能は `extensions.txt` を見て `code --install-extension <ID>` で入れます。

## キーマップの方針

Visual Studio キーマップの土台は拡張 **`ms-vscode.vs-keybindings`**（Microsoft 公式）が担う。
この拡張が 51 個のバインドを定義するため、`keybindings.json` には
**拡張が定義していない、かつ Visual Studio で日常的に使う操作だけ**を書く。
二重定義は避ける（`Ctrl+K Ctrl+D`, `Ctrl+Shift+L`, `Ctrl+D`, `Ctrl+Y`, `Ctrl+-` などは拡張側にある）。

### 補完しているバインド

| キー | 動作 | 備考 |
|---|---|---|
| `Ctrl+K, Ctrl+C` / `Ctrl+K, Ctrl+U` | コメント化 / 解除 | VS の主要操作だが拡張に無い |
| `Ctrl+F12` | 実装へ移動 | |
| `Ctrl+K, Ctrl+T` | 呼び出し階層 | |
| `Ctrl+M, Ctrl+M` / `Ctrl+M, Ctrl+L` / `Ctrl+M, Ctrl+O` | 折りたたみ切替 / 全展開 / リージョン折りたたみ | |
| `Ctrl+F5` | デバッグなしで開始 | VS と同じ挙動に合わせる |
| `Ctrl+Alt+B` / `Ctrl+Alt+W` / `Ctrl+Alt+I` | ブレークポイント / ウォッチ / イミディエイト | VS のデバッグウィンドウ相当 |
| `F8` / `Shift+F8` | 次 / 前のエラー | VS のエラー一覧移動 |
| `Ctrl+\, Ctrl+E` | エラー一覧（問題パネル） | |
| `Ctrl+Alt+F` / `Ctrl+Alt+G` | 検索ビュー / Git ビュー | |
| `Ctrl+Shift+R` | 最近開いたフォルダー | `Ctrl+R` が chord に使われているため（下記） |
| `Ctrl+R, Ctrl+G` | using の整理 | C# |
| `Ctrl+R, Ctrl+M` | リファクタリングメニュー | VS の「メソッドの抽出」相当 |
| `Ctrl+K, Ctrl+O` | ヘッダ / ソース切替 | C/C++ のみ |
| `Ctrl+E, Ctrl+D` / `Ctrl+E, Ctrl+F` | ドキュメント / 選択範囲のフォーマット | VS 旧バインド |
| `Ctrl+Alt+PageDown` / `PageUp` | 次 / 前のドキュメント | |
| `Ctrl+K, Ctrl+W` | すべてのドキュメントを閉じる | |

### 既定バインドの解除

- `Ctrl+,` … 拡張が「すべてに移動（QuickOpen）」に割り当てるため、VSCode 既定の
  「設定を開く」を解除している。設定画面は **`Ctrl+Alt+,`** に退避。
- `Ctrl+-` / `Ctrl+Shift+-` … VSCode 既定のズームアウトを解除し、VS と同じ
  「前へ戻る / 進む」を再定義している。

  拡張 `vs-keybindings` も `Ctrl+-` に `navigateBack` を定義しているが、
  **既定の `workbench.action.zoomOut` が勝ってしまい機能しない**。
  `zoomOut` は `Ctrl+-` と `Ctrl+numpad_subtract` の複数キーで登録されており、
  拡張側の定義だけでは打ち消せないため、ユーザー設定で明示的に解除している。

### Ctrl+R が chord のため openRecent を移動

`Ctrl+R` は拡張 `vs-keybindings` が chord の prefix として使っている
（`Ctrl+R, Ctrl+R` = 名前の変更、`Ctrl+R, Ctrl+W` = 空白表示切替）。
このリポジトリでも `Ctrl+R, Ctrl+G` / `Ctrl+R, Ctrl+M` を足している。

prefix になっているキーは単独では発火せず次のキー入力を待つため、
VSCode 既定の `Ctrl+R`（最近開いたフォルダー）は使えない。
Visual Studio でも `Ctrl+R` 単独は使わないので chord はそのまま残し、
**`Ctrl+Shift+R`** に `workbench.action.openRecent` を割り当てた。

### ズーム操作

`Ctrl+-` を「前へ戻る」に譲った結果、ズームは `Ctrl+Alt+` 系に集約した。

| キー | 動作 |
|---|---|
| `Ctrl+Alt+-` | 縮小 |
| `Ctrl+Alt+;` | 拡大 |
| `Ctrl+Alt+0` | リセット |

既定のズームキー（`Ctrl+-` / `Ctrl+=` / `Ctrl+Shift+=` / `Ctrl+numpad -` /
`Ctrl+numpad +` / `Ctrl+numpad0`）は全て解除し、割り当てを 1 か所にまとめている。
テンキーの無いキーボードでも押せることを優先した。

### 意図的に入れていないもの

- `Ctrl+W` 始まりの chord（VS のウィンドウ操作系）… 拡張が `Ctrl+W` 単体を
  `smartSelect.expand` に割り当てているため chord にできない。VS の `Ctrl+Alt+<x>` 系に寄せた。
- ブックマーク（VS の `Ctrl+K, Ctrl+K`）… 別途 Bookmarks 拡張が必要なため未設定。

## 主要な設定

- **保存時フォーマット + import 整理** … `editor.formatOnSave`, `codeActionsOnSave`
- **`bin` / `obj` / `.vs` を除外** … エクスプローラーと検索の両方（.NET 向け）
- **C# は C# Dev Kit（Roslyn）を使用** … `dotnet.server.useOmnisharp: false`
- **インレイヒント有効** … 引数名・型を表示（VS の挙動に近づける）
- **`files.autoSave: onFocusChange`** … VS と違いフォーカス移動で保存される点に注意
- **テレメトリ無効** … `telemetry.telemetryLevel: off`

## 注意

`keybindings.json` は VSCode 上では JSONC（コメント可）だが、このリポジトリの
構文チェック hook が標準 JSON としてパースするため、コメントを含めていない。
各バインドの意図は上表を参照。
