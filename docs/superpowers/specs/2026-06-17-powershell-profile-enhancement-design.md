# PowerShell プロファイル強化 設計書

- 作成日: 2026-06-17
- 対象ファイル: `app-settings/pwsh/Microsoft.PowerShell_profile.ps1`(単一ファイル)
- ステータス: 設計合意待ち

## 1. 概要・目的

Windows + PowerShell 7 環境の日常作業(Git/GitHub・C#/C++/Visual Studio・dotnet ビルド・AI CLI・ファイル操作)を加速し、さらに**新マシンの環境構築をプロファイル内の関数だけで完結**できる「全部入り」プロファイルにする。

設計方針はユーザ要望に基づく:
- **単一ファイルに全部書く**(モジュール分割や別ローダは作らない)
- 配布は**手動コピー**($PROFILE へコピーする運用。install スクリプトは作らない)
- 環境構築補助は「シェルから呼べる関数」として同梱する

## 2. 設計原則

1. **起動を軽く保つ** — 重い処理(VS 開発環境取り込み、ツール一括導入)は起動時に実行しない。呼び出し時のみ動く関数にする。起動時の処理はコマンド存在判定など軽量なものに限る。
2. **任意ツールは存在ガード** — `eza`/`bat`/`fzf`/`zoxide`/`gsudo`/`lazygit`/`gh` など未導入のマシンでも**エラーなくロード**でき、その上で `Install-DevTools` で揃えられる。これが「補助」の本質。
3. **既存資産は全保持** — 現行プロファイルの機能を壊さない(§5 参照)。
4. **冪等** — `Install-DevTools` は導入済みをスキップし、何度実行しても安全。
5. **コード規約** — `$ErrorActionPreference` はプロファイル全体では設定せず、破壊的・失敗しうる関数内で局所的に扱う(プロファイルが途中で停止すると以降が読み込まれないため)。コメントは既存の英日混在スタイルに合わせる。

## 3. ファイル構成(単一ファイル内のセクション)

### §0 ヘッダ / エンコーディング / 内部ヘルパー

- コンソール入出力を UTF-8 に明示設定(文字化け防止。現環境は既に UTF-8 だが新マシンでの一貫性のため):
  `[Console]::OutputEncoding = [Console]::InputEncoding = [System.Text.UTF8Encoding]::new()`
- `Test-Cmd` — コマンド存在判定ヘルパー。結果を script スコープの hashtable にキャッシュし、起動・各関数のガードで再利用する。

```powershell
$script:_cmdCache = @{}
function Test-Cmd {
    param([Parameter(Mandatory)][string]$Name)
    if (-not $script:_cmdCache.ContainsKey($Name)) {
        $script:_cmdCache[$Name] = [bool](Get-Command $Name -ErrorAction SilentlyContinue)
    }
    $script:_cmdCache[$Name]
}
```

### §1 エイリアス(既存維持)

`cc`→claude / `cop`→copilot / `g`→git / `which`→Get-Command。

### §2 ナビゲーション / ファイル操作

| 名前 | 機能 | 備考 |
|---|---|---|
| `mkcd`(既存) | ディレクトリ作成して移動 | 維持 |
| `size`(既存) | ファイル/フォルダのサイズ表示 | 維持 |
| `..` `...` `....` | 1〜3 階層上へ移動 | 関数定義 |
| `up [N]` | N 階層上へ移動(既定 1) | |
| `repos` | `~\source\repos` へ移動 | |
| `ll` / `la` / `lt` | 一覧表示。`eza` があれば eza(色・git・アイコン・ツリー)、無ければ `Get-ChildItem` | 存在ガード |
| `ff` | `fd`+`fzf` でファイルを絞り込み、既定アプリで開く | `fd`/`fzf` ガード |
| `fcd` | `fd`+`fzf` でディレクトリを絞り込み `cd` | 同上 |
| `touch` | ファイル作成(既存ならタイムスタンプ更新) | |
| `reload` | `. $PROFILE` でプロファイル再読込 | |
| `Edit-Profile`(別名 `profile`) | $PROFILE をエディタで開く(code → notepad の順でフォールバック) | |

### §3 Git / GitHub

| 名前 | 機能 |
|---|---|
| `gs`(既存) | `git status -sb` |
| `gl`(既存) | `git log --oneline --graph --decorate -20` |
| `git-undo`(既存) | 直前コミットを取り消し(soft reset) |
| `ga` / `gaa` | `git add` / `git add -A` |
| `gcm <msg>` | `git commit -m`(メッセージ必須を検証) |
| `gco [branch]` | `git checkout`。引数なしは `fzf` でブランチ選択(`fzf` ガード) |
| `gb` | `git branch` |
| `gd` / `gds` | `git diff` / `git diff --staged` |
| `gp` / `gpl` / `gf` | `git push` / `git pull` / `git fetch --all --prune` |
| `lg` | `lazygit` 起動(ガード) |
| `prc` / `prv` / `prl` / `prs` | `gh pr create` / `view --web` / `list` / `status`(`gh` ガード) |
| `groot` | git リポジトリのルートへ `cd` |
| `gclone <url>` | clone してそのフォルダへ `cd` |
| `glog` | fzf + delta でコミットを対話ブラウズ(差分プレビュー、`fzf` ガード) |

### §4 C#/C++ / Visual Studio / ビルド

検証済み: VS Community 2026 が `C:\Program Files\Microsoft Visual Studio\18\Community` に存在し、`Launch-VsDevShell.ps1` / `Microsoft.VisualStudio.DevShell.dll` / `devenv.exe` を確認済み。`vswhere` も動作。

| 名前 | 機能 | 実装 |
|---|---|---|
| `vsdev` | 現在のセッションに VS 開発者環境を取り込む(cl/msbuild 等が使えるようになる) | `vswhere -latest -property installationPath` で特定 → `Microsoft.VisualStudio.DevShell.dll` を Import → `Enter-VsDevShell`。**呼んだ時だけ実行**(起動時は走らせない) |
| `sln` | カレント階層から上方向に最寄りの `*.sln` を探し `devenv` で開く | 複数一致は `fzf`(無ければ一覧)で選択 |
| `vs [path]` | 指定パス(既定はカレント)を `devenv` で開く | |
| `db` / `dr` / `dt` | `dotnet build` / `run` / `test` | |
| `msb` | `msbuild`(`vsdev` 実行後に有効) | |
| `Find-Sln`(内部) | sln 探索ヘルパー | `sln`/ビルド系で共用 |

### §5 ツール連携(採用ツールを「使える」状態にする / すべて存在ガード)

- **zoxide**: `Invoke-Expression (& zoxide init powershell | Out-String)` → 賢い `cd` の `z`
- **Starship**: `Invoke-Expression (&starship init powershell)` → git 状態・言語バージョンを表示するプロンプト(グリフは Nerd Font 推奨)
- **bat**: `cat` をページャ/シンタックスハイライト表示に。fzf プレビューにも使用
- **gsudo**: `sudo` 関数として昇格実行
- **PSFzf**: モジュールがあれば Import。**キーバインドは `Ctrl+t`(パス挿入)/ `Alt+c`(cd)に割り当て**、`Ctrl+r` は既存の自前履歴(下記§7)を維持して共存
- **Terminal-Icons**: モジュールがあれば Import(一覧表示にアイコン)
- **ネイティブタブ補完**(検証済みの公式スニペット、各コマンド存在時のみ登録):
  - `dotnet`(`dotnet complete` ベース)
  - `gh`(`gh completion -s powershell`)
  - `winget`(`winget complete` ベース)
- **`refreshenv`**(別名で `Update-SessionPath`): Machine+User の PATH を再取得して `$env:PATH` を更新。`Install-DevTools` 後にシェル再起動なしで新ツールを使えるようにする
- **`clip` / `paste`**: `Set-Clipboard` / `Get-Clipboard` の短縮
- **`myip`**: 公開 IP アドレスを表示(`api.ipify.org`、タイムアウト 5 秒)
- **`killport <port>` / `port <port>`**: `Get-NetTCPConnection` で該当ポートの待受プロセスを表示/停止(開発サーバ向け)

### §6 環境構築補助(呼べる関数)

#### `Show-DevEnv`
期待ツールの導入状況を表で表示する(新マシンで「何が足りないか」を一目で把握)。対象: winget/git/gh/fzf/rg/jq/yq/dotnet/claude/copilot/zoxide/eza/bat/fd/delta/gsudo/lazygit/gita と PS モジュール(PSFzf/Terminal-Icons)。

#### `Install-DevTools [-Force]`
データ駆動でツールを一括導入。導入済みはスキップ(冪等)。一括実行前に確認プロンプト(`-Force` で省略)。**4 バックエンド対応**: winget / winget(msstore ソース)/ pip / PSGallery。

**ツール早見(各ツールの役割と使い方):**

| ツール | 説明 | プロファイルでの使い方 |
|---|---|---|
| Files | モダンなタブ型ファイルマネージャ(エクスプローラ代替) | GUIアプリ |
| Everything | 全ファイル名を瞬時に検索するインデックス検索 | GUIアプリ(EverythingToolbar の前提) |
| EverythingToolbar | Everything をタスクバーから即検索 | GUIアプリ |
| Microsoft PC Manager | PC 最適化・クリーンアップ(Microsoft 製) | GUIアプリ |
| Flow Launcher | キーボード起動ランチャ(アプリ/ファイル/コマンド) | GUIアプリ |
| starship | git 状態・言語バージョンを表示する高速クロスシェルプロンプト | プロンプト(Nerd Font 推奨) |
| zoxide | 学習型の賢い `cd`。よく行くフォルダを記憶し部分一致でジャンプ | `z <部分名>` で移動 |
| eza | 色・アイコン・git・ツリー対応の `ls` 強化版 | `ll`/`la`/`lt`(eza があれば自動採用) |
| bat | シンタックスハイライト+行番号+git差分マーカー付きの `cat` | `cat <file>`、fzf プレビュー |
| fd | `.gitignore` 考慮の高速・簡潔な `find` | `ff`/`fcd`(fzf と組合せ) |
| delta | `git diff`/`git log` を色付き整形するページャ | git の pager に設定(導入時に確認) |
| gsudo | Windows 版 `sudo`(同じ窓で昇格実行) | `sudo <command>` |
| lazygit | git 操作のターミナル UI(stage/commit/branch/rebase) | `lg` で起動 |
| PSFzf | fzf を PSReadLine に統合 | `Ctrl+t`(パス挿入)/`Alt+c`(cd) |
| Terminal-Icons | 一覧表示にファイルアイコン | `ll`/`la` の表示に反映 |
| gita | 複数 git リポジトリを一括管理する CLI | `gita ls` 等(別途利用) |
| git | Git 本体 | 全 git 系コマンドの基盤 |
| gh | GitHub 公式 CLI | `prc`/`prv`/`prl`/`prs` |
| fzf | 汎用ファジーファインダ | `gco`/`ff`/`sln`/`Ctrl+r` 等で使用 |

ツール定義(すべて winget ID / コマンドは照合済み):

| カテゴリ | ツール | Backend | ID / コマンド | 検出 | 備考 |
|---|---|---|---|---|---|
| GUI | Files | winget | `FilesCommunity.Files` | `winget list` | |
| GUI | Everything | winget | `voidtools.Everything` | `winget list` | EverythingToolbar の前提 |
| GUI | EverythingToolbar | winget | `stnkl.EverythingToolbar` | `winget list` | |
| GUI | Microsoft PC Manager | winget(msstore) | `9PM860492SZD` | `winget list` | 規約同意が必要な場合あり |
| GUI | Flow Launcher | winget | `Flow-Launcher.Flow-Launcher` | `winget list` | |
| プロンプト | starship | winget | `Starship.Starship` | `Test-Cmd` | Nerd Font 推奨 |
| CLI | zoxide | winget | `ajeetdsouza.zoxide` | `Test-Cmd` | |
| CLI | eza | winget | `eza-community.eza` | `Test-Cmd` | |
| CLI | bat | winget | `sharkdp.bat` | `Test-Cmd` | |
| CLI | fd | winget | `sharkdp.fd` | `Test-Cmd` | |
| CLI | delta | winget | `dandavison.delta` | `Test-Cmd` | 導入後 git pager 設定(確認付き) |
| CLI | gsudo | winget | `gerardog.gsudo` | `Test-Cmd` | |
| Git | lazygit | winget | `JesseDuffield.lazygit` | `Test-Cmd` | |
| Git | PSFzf | PSGallery | `PSFzf` | `Get-Module -ListAvailable` | |
| Git | Terminal-Icons | PSGallery | `Terminal-Icons` | `Get-Module -ListAvailable` | |
| Git | gita | pip | `pip install --user gita` | `Test-Cmd gita` | 要 Python(検証済み: python/pip あり) |
| ベース | git | winget | `Git.Git` | `Test-Cmd` | 導入済みはスキップ |
| ベース | gh | winget | `GitHub.cli` | `Test-Cmd` | 同上 |
| ベース | fzf | winget | `junegunn.fzf` | `Test-Cmd` | 同上 |

導入コマンド方針:
- winget: `winget install --id <id> --exact --source winget --accept-package-agreements --accept-source-agreements`
- msstore: `--source msstore`(規約同意フラグ付き。対話的同意が必要なら警告して継続)
- pip: `pip install --user gita`(python/pip ガード)
- PSGallery: `Install-Module <name> -Scope CurrentUser -Force`
- **delta**: 導入後、確認の上 `git config --global core.pager delta` / `interactive.diffFilter "delta --color-only"` / `delta.navigate true` を設定(スキップ可)
- 導入後に `refreshenv` を呼び、当該セッションで即利用可能にする

#### `Update-DevTools`
`winget upgrade --all`(+ PSGallery モジュールの `Update-Module`)。

### §7 PSReadLine / 履歴(既存ブロックを維持・微強化)

既存設定(History 予測 + ListView、EditMode Windows、Up/Down 履歴検索、Ctrl+d、Ctrl+r 自前 fzf 履歴 `Invoke-FzfHistory`)は**そのまま維持**。以下を追加:
- `Set-PSReadLineOption -HistoryNoDuplicates`
- `Set-PSReadLineOption -MaximumHistoryCount 10000`
- `Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete`
- `Set-PSReadLineKeyHandler -Key Alt+a -Function SelectCommandArgument`(コマンド引数を順に選択)
- 括弧 `()`/`{}`/`[]` とクォート `"`/`'` の自動補完・スキップ(PSReadLine サンプル準拠のスマート入力ハンドラ)

`Ctrl+r` は削除機能つきの自前実装を残し、PSFzf は `Ctrl+t`/`Alt+c` に割り当てて共存させる(機能を失わない)。

## 4. 既存資産の扱い(保持リスト)

以下は壊さず維持する: エイリアス `cc`/`cop`/`g`/`which`、関数 `mkcd`/`size`/`Invoke-FzfHistory`/`gs`/`gl`/`git-undo`、PSReadLine 設定一式。

## 5. エラー処理・堅牢性

- 任意ツール依存の機能は `Test-Cmd` でガードし、未導入でもプロファイルは正常ロードする。
- 引数必須の関数(`gcm` など)は引数を検証し、不足時に使い方を表示。
- `vsdev` / `sln` は対象が見つからない場合に明確なメッセージを出す。
- `Install-DevTools` の各導入は個別に try/catch し、1 つ失敗しても残りを継続。最後に結果サマリを表示。

## 6. パフォーマンス考慮

- 起動時に行うのは存在判定・補完登録・モジュール Import・zoxide 初期化など軽量なものに限定。
- VS 開発環境取り込み(`vsdev`)とツール導入(`Install-DevTools`)は遅いため、必ず**オンデマンド関数**にする。

## 7. 検証方法(完了前チェック)

1. **構文解析**: `[System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errs)` でパースエラー 0 を確認。
2. **クリーンロード**: `pwsh -NoProfile -NoLogo -Command ". '<path>'; ..."` で当該ファイルを dot-source し、エラーなくロードされ、主要関数(`vsdev`/`gco`/`Show-DevEnv`/`Install-DevTools`/`Test-Cmd` 等)が定義されることを確認。
3. **存在ガード確認**: 未導入ツール(例: 現状の `eza`/`zoxide`)があってもロードがエラーにならないことを確認。
4. PSScriptAnalyzer があれば追加で実行(任意)。

`Install-DevTools` の実導入は副作用が大きいため、自動テストでは実行しない(ロジック・構文・冪等判定の確認に留める)。

## 8. 決定事項と不採用(根拠付き)

**決定**:
- 構造: 単一ファイル(ユーザ要望)。配布: 手動コピー(install スクリプトなし)。
- `Ctrl+r`: 自前 fzf 履歴(削除機能つき)を維持、PSFzf は `Ctrl+t`/`Alt+c`。
- `delta`: 導入後に確認付きで git pager 設定まで行う。
- コンソール UTF-8 を明示設定。

**追加採用**(初期スコープ外から後追いで採用):
- プロンプト: **Starship を採用**(`Install-DevTools` に追加し profile で init)。
- git: `groot`(リポジトリルートへ cd)/ `gclone`(clone & cd)/ `glog`(fzf+delta で対話ブラウズ)。
- 入力: PSReadLine の `Alt+a` 引数選択 + 括弧/クォート自動補完。
- 小物: `up [N]`(N 階層上へ)/ `myip`(公開 IP)。

**不採用(今回スコープ外)**:
- 端末/その他プロンプト(oh-my-posh / Windows Terminal)— 見送り。
- 開発/Windows GUI 一括導入(CMake/Ninja/LLVM/uv、PowerToys/7-Zip/ShareX/Notepad++/WinMerge)— カテゴリ未選択。
- `bat`/`fd` 以外の非★ CLI(fastfetch/dust/gdu/sd)— 後から `Install-DevTools` の定義に追記すれば拡張可能。
- 正式モジュール化(.psm1/.psd1)— 単一ファイル方針のため過剰。

## 9. 将来の拡張余地

- `Install-DevTools` のツール定義はデータ配列なので、行を足すだけで対象を増減できる(プロンプト系・GUI 系を後で追加可能)。
- プロンプト導入(Starship 等)を将来採用する場合は §5 に init を 1 行追加するだけで済む。
