# ---------------------------------------------------------------------------
# §9 Help - list the commands this profile provides
# ---------------------------------------------------------------------------

# Catalog of commands defined above (data-driven; keep in sync when adding commands)
$script:ProfileHelp = [ordered]@{
    'Navigation & files'    = @(
        @{ Cmd = 'mkcd <path>'; Desc = 'ディレクトリを作成して移動' }
        @{ Cmd = 'size [path]'; Desc = 'ファイル/フォルダのサイズ一覧 (MB, 降順)' }
        @{ Cmd = '.. / ... / ....'; Desc = '1/2/3 階層上へ移動' }
        @{ Cmd = 'up [n]'; Desc = 'n 階層上へ移動 (既定 1)' }
        @{ Cmd = 'repos'; Desc = '~/source/repos へジャンプ' }
        @{ Cmd = 'll / la / lt'; Desc = '一覧表示 (eza があればアイコン/git 付き)' }
        @{ Cmd = 'ff'; Desc = 'fzf でファイルを絞り込んで開く' }
        @{ Cmd = 'fcd'; Desc = 'fzf でディレクトリを絞り込んで cd' }
        @{ Cmd = 'touch <path>'; Desc = 'ファイル作成 / タイムスタンプ更新' }
        @{ Cmd = 'backup-file <f>'; Desc = '<名前>.bak-日時 でバックアップ作成' }
        @{ Cmd = 'reload'; Desc = 'プロファイルを再読込' }
        @{ Cmd = 'Measure-ProfileStartup'; Desc = 'プロファイル起動時間を別プロセスで計測' }
        @{ Cmd = 'profile'; Desc = 'プロファイルを編集 (code/notepad)' }
        @{ Cmd = 'Update-Profile [-Force]'; Desc = 'GitHub 上のリポジトリ版でプロファイルを更新 (差分確認・バックアップ・再読込)' }
    )
    'Git / GitHub'          = @(
        @{ Cmd = 'gs'; Desc = '状態を短い形式で表示 (ブランチ情報つき)' }
        @{ Cmd = 'gl'; Desc = 'コミット履歴を枝分かれ図つきで直近 20 件表示' }
        @{ Cmd = 'ga / gaa'; Desc = '指定ファイルをステージ / 変更すべてをステージ' }
        @{ Cmd = 'gb'; Desc = 'ブランチ一覧の表示・操作' }
        @{ Cmd = 'gd / gds'; Desc = '作業ツリーの差分 / ステージ済みの差分を表示' }
        @{ Cmd = 'gp / gpf'; Desc = 'プッシュ / 他者の更新を上書きしない安全な強制プッシュ' }
        @{ Cmd = 'gsta/gstp/gstl'; Desc = '変更を退避 / 退避した変更を復元 / 退避の一覧表示' }
        @{ Cmd = 'gcm <msg>'; Desc = 'メッセージ付きでコミット' }
        @{ Cmd = 'gco [branch]'; Desc = 'ブランチ切替 (引数なしは fzf で選択)' }
        @{ Cmd = 'git-undo'; Desc = '直前のコミットを取り消し、変更はステージ済みのまま残す' }
        @{ Cmd = 'git-switch'; Desc = 'fzf でブランチ切替 (ローカルに無ければ origin から作成して追跡)' }
        @{ Cmd = 'git-clean-branches'; Desc = 'マージ済みのローカルブランチを確認後に一括削除 (main/master/develop は残す)' }
        @{ Cmd = 'git-reset-clean'; Desc = '変更破棄 + 未追跡・ignore 対象も削除して完全クリーン (-Ref/-Force)' }
        @{ Cmd = 'git-root'; Desc = 'リポジトリのルートへ移動' }
        @{ Cmd = 'git-clone <url>'; Desc = 'クローンして、そのフォルダへ移動' }
        @{ Cmd = 'git-log-browse'; Desc = 'fzf でコミットを閲覧 (差分プレビュー。delta があれば色付き)' }
        @{ Cmd = 'lg'; Desc = 'lazygit を起動 (あれば)' }
        @{ Cmd = 'prc/prv/prl/prs'; Desc = 'GitHub PR の作成 / ブラウザ表示 / 一覧 / 状況 (gh があれば)' }
        @{ Cmd = 'git-fetch / gf'; Desc = '全リモートを取得して削除済みを掃除 (大文字小文字違いの ref 衝突を回避)' }
        @{ Cmd = 'git-pull / gpl'; Desc = '安全な pull: 未コミット変更を退避 → 衝突ファイルを .git/pull-backup へ避難 → pull → 復元 (引数は git pull へ)' }
        @{ Cmd = 'gita-pull-all'; Desc = 'gita 全リポジトリの nul ファイルを掃除して pull (-Fallback で切替先指定)' }
        @{ Cmd = 'gita-scan [path]'; Desc = '直下の git リポジトリを gita に一括登録' }
        @{ Cmd = 'git-help'; Desc = 'この Git コマンド一覧だけを表示' }
    )
    'Visual Studio / build' = @(
        @{ Cmd = 'vsdev'; Desc = '現セッションを VS Developer 環境化' }
        @{ Cmd = 'sln'; Desc = '最寄りの .sln を VS で開く' }
        @{ Cmd = 'vs [path]'; Desc = '指定パスを VS で開く' }
        @{ Cmd = 'db / dr / dt'; Desc = 'dotnet build / run / test' }
        @{ Cmd = 'msb'; Desc = 'msbuild' }
    )
    'Tools & system'        = @(
        @{ Cmd = 'cat <file>'; Desc = 'bat 連携 (あれば)' }
        @{ Cmd = 'sudo <cmd>'; Desc = 'gsudo 連携 (あれば)' }
        @{ Cmd = 'z / zi'; Desc = 'zoxide スマート cd (あれば)' }
        @{ Cmd = 'refreshenv / Update-SessionPath'; Desc = 'PATH を再読込 (インストール後に)' }
        @{ Cmd = 'phelp [keyword]'; Desc = 'このコマンド一覧を表示 (キーワードで絞り込み)' }
        @{ Cmd = 'clip / paste'; Desc = 'クリップボードへ書込 / 読出' }
        @{ Cmd = 'myip'; Desc = '公開 IP アドレスを表示' }
        @{ Cmd = 'port <n>'; Desc = 'ポートを使用中のプロセスを表示' }
        @{ Cmd = 'killport <n>'; Desc = 'ポートを使用中のプロセスを強制終了' }
    )
    'Claude Code'           = @(
        @{ Cmd = 'fable-orchest / ccf'; Desc = 'Fable が立案・Sonnet 5.5 が実行の構成で claude 起動' }
        @{ Cmd = 'fable-orchest-opus / ccfo'; Desc = 'Fable が立案・Opus 5.5 が実行の構成で claude 起動' }
        @{ Cmd = 'opus-orchest / cco'; Desc = 'Opus 5.5 が立案・Sonnet 5.5 が実行の構成で claude 起動' }
        @{ Cmd = 'fable-orchest-plan / ccfp'; Desc = 'ccf を plan モードで起動（立案を承認してから実行）' }
        @{ Cmd = 'cc / ccop'; Desc = 'Opus 5.5 で claude 起動（司令塔プロンプトなし、既定コマンド）' }
        @{ Cmd = 'ccp'; Desc = 'cc を plan モードで起動' }
        @{ Cmd = 'ccs'; Desc = 'Sonnet 5.5 で claude 起動（軽作業向け）' }
        @{ Cmd = 'cch'; Desc = 'Haiku 5.5 で claude 起動（最軽量・高速）' }
        @{ Cmd = 'ccc'; Desc = '直近の会話を継続 (claude --continue)' }
        @{ Cmd = 'ccr'; Desc = 'セッションを選んで再開 (claude --resume)' }
    )
    'Codex'                 = @(
        @{ Cmd = 'cx'; Desc = 'codex 素の起動（config.toml の既定に従う）' }
        @{ Cmd = 'cxr'; Desc = '読み取り専用で起動（調査・コードリーディング向け）' }
        @{ Cmd = 'cxa'; Desc = '承認なしで自動実行（サンドボックス内に限定）' }
        @{ Cmd = 'cxh'; Desc = '推論強度 high で起動（設計判断・難しいデバッグ）' }
        @{ Cmd = 'cxrev'; Desc = 'コードレビューを実行 (codex review)' }
        @{ Cmd = 'cxc'; Desc = '直近セッションを継続 (codex resume --last)' }
        @{ Cmd = 'cxs'; Desc = 'セッションを選んで再開 (codex resume)' }
        @{ Cmd = 'cxfa'; Desc = 'サンドボックスを外して起動（承認は残る）' }
        @{ Cmd = 'cxyolo'; Desc = '承認・サンドボックスとも無効化' }
    )
    'Dev environment'       = @(
        @{ Cmd = 'Show-DevEnv'; Desc = '開発ツールの導入状況を一覧' }
        @{ Cmd = 'Install-DevTools [-Yes]'; Desc = '未導入ツールを一括インストール (-Yes で全確認に y)' }
        @{ Cmd = 'Update-DevTools'; Desc = 'winget/PS モジュールを更新' }
        @{ Cmd = 'Install-ExtraTools [-Name DevDeck,RdpManager] [-Yes]'; Desc = '一部の端末だけに入れる自作アプリを導入・更新（Install-DevTools には含まれない）' }
        @{ Cmd = 'Set-WindowsSettings [-Check]'; Desc = 'Windows 設定（レジストリ）を適用 (-Check で差分のみ)' }
        @{ Cmd = 'Enable-SshServer'; Desc = '接続される側: OpenSSH Server を導入・自動起動・pwsh を既定シェルに (要管理者)' }
        @{ Cmd = 'Add-SshHost <host> <user> [-Alias]'; Desc = '接続する側: 鍵を作って相手に登録し ~/.ssh/config に追記' }
    )
    'Aliases'               = @(
        @{ Cmd = 'cop'; Desc = 'copilot' }
        @{ Cmd = 'g'; Desc = 'git' }
        @{ Cmd = 'which'; Desc = 'Get-Command' }
    )
}

# Show the commands this profile provides. Optional keyword filters cmd/desc/section.
function Show-ProfileHelp {
    param([string]$Filter, [string]$OnlySection)

    foreach ($section in $script:ProfileHelp.Keys) {
        if ($OnlySection -and $section -ne $OnlySection) { continue }
        $items = $script:ProfileHelp[$section]
        if ($Filter) {
            $items = @($items | Where-Object {
                    $_.Cmd -like "*$Filter*" -or $_.Desc -like "*$Filter*" -or $section -like "*$Filter*"
                })
        }
        if (-not $items) { continue }

        Write-Host ''
        Write-Host "[$section]" -ForegroundColor Cyan
        foreach ($i in $items) {
            Write-Host ('  {0,-22}' -f $i.Cmd) -ForegroundColor Yellow -NoNewline
            Write-Host $i.Desc -ForegroundColor Gray
        }
    }
    Write-Host ''
    Write-Host "tip: 'phelp <keyword>' で絞り込み (例: phelp git) / Ctrl+g でコマンドパレット検索 / Ctrl+r で履歴検索" -ForegroundColor DarkGray
}
Set-Alias phelp Show-ProfileHelp

# Git 系コマンドの一覧だけを表示
function git-help { Show-ProfileHelp -OnlySection 'Git / GitHub' }
