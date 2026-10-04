# Orca 設定

`settings.json` は現在の Orca 設定から抽出した、外観・エディタ・ターミナル・
ワークスペース表示の設定です。保存対象は `tools/Export-OrcaSettings.py` の
`SETTING_KEYS` に明示しています。

```powershell
python tools/Export-OrcaSettings.py
```

既定では `%APPDATA%\orca\profiles\local-default\profile-state.db` を読み取り専用で
開きます。Orca 起動中でも実行できます。別のプロファイルを使う場合は
`--database <profile-state.db のパス>` を指定してください。

認証情報、アカウント、プロキシ、環境変数、任意コマンド、ローカルパス、
登録リポジトリ、会話・作業履歴、設定移行フラグは保存しません。

現在の Orca は設定を SQLite 内で管理しており、この JSON を設定ファイルとして
直接読み込みません。復元は JSON を参照して Orca の設定画面で行ってください。
`Sync-AppSettings.ps1` の同期対象には含めていません。
