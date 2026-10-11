# Orca 設定

`settings.json` は Orca 設定から抽出した、外観・エディタ・ターミナル・
ワークスペース表示の設定の控えです。認証情報、アカウント、プロキシ、環境変数、
任意コマンド、ローカルパス、登録リポジトリ、会話・作業履歴、設定移行フラグは含みません。

現在の Orca は設定を SQLite 内で管理しており、この JSON を設定ファイルとして
直接読み込みません。復元は JSON を参照して Orca の設定画面で行ってください。
`Install-DevTools` の配置対象には含めていません。

`keybindings.json` は Orca が直接読み込む `~/.orca/keybindings.json` の管理元です。
`Install-DevTools` が配置します。反映には Orca の再起動か、
設定の Shortcuts 画面からの再読み込みが必要です。
