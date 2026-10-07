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
        @{ Cmd = 'gs'; Desc = 'git status -sb' }
        @{ Cmd = 'gl'; Desc = 'git log をグラフ表示 (直近 20)' }
        @{ Cmd = 'git-undo'; Desc = '直前コミットを取り消し (staging へ戻す)' }
        @{ Cmd = 'ga / gaa'; Desc = 'git add / git add -A' }
        @{ Cmd = 'gb'; Desc = 'git branch' }
        @{ Cmd = 'gd / gds'; Desc = 'git diff / git diff --staged' }
        @{ Cmd = 'gp / gpf'; Desc = 'git push / push --force-with-lease' }
        @{ Cmd = 'gpl'; Desc = '安全な git pull: 衝突ファイルを .git/pull-backup へ退避 + 未コミット変更を自動 stash/復元 (引数は git pull へ)' }
        @{ Cmd = 'gf'; Desc = 'git fetch --all --prune (大文字小文字違いの ref 衝突を回避)' }
        @{ Cmd = 'gsta/gstp/gstl'; Desc = 'git stash push/pop/list' }
        @{ Cmd = 'gcm <msg>'; Desc = 'git commit -m' }
        @{ Cmd = 'gco [branch]'; Desc = 'checkout (引数なしは fzf で選択)' }
        @{ Cmd = 'lg'; Desc = 'lazygit (あれば)' }
        @{ Cmd = 'prc/prv/prl/prs'; Desc = 'gh pr create/view/list/status (あれば)' }
        @{ Cmd = 'groot'; Desc = 'リポジトリのルートへ cd' }
        @{ Cmd = 'gclone <url>'; Desc = 'clone して cd' }
        @{ Cmd = 'glog'; Desc = 'fzf でコミット閲覧 (delta プレビュー)' }
        @{ Cmd = 'clean-pull-all'; Desc = 'gita 全リポジトリを掃除して pull (-Fallback で切替先指定)' }
        @{ Cmd = 'git-switch'; Desc = 'fzf でブランチ切替 (無ければ origin から作成)' }
        @{ Cmd = 'git-clean-branches'; Desc = 'マージ済みローカルブランチを一括削除' }
        @{ Cmd = 'git-nuke'; Desc = 'reset --hard + clean -ffdx で完全クリーン (-Ref/-Force)' }
        @{ Cmd = 'gita-scan [path]'; Desc = '直下の git リポジトリを gita に一括登録' }
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
        @{ Cmd = 'fable-orchest / ccf'; Desc = 'Fable が立案・Sonnet 5 が実行の構成で claude 起動' }
        @{ Cmd = 'fable-orchest-opus / ccfo'; Desc = 'Fable が立案・Opus 5.5 が実行の構成で claude 起動' }
        @{ Cmd = 'opus-orchest / cco'; Desc = 'Opus 5.5 が立案・Sonnet 5 が実行の構成で claude 起動' }
        @{ Cmd = 'fable-orchest-plan / ccfp'; Desc = 'ccf を plan モードで起動（立案を承認してから実行）' }
        @{ Cmd = 'cc / ccop'; Desc = 'Opus 5.5 で claude 起動（司令塔プロンプトなし、既定コマンド）' }
        @{ Cmd = 'ccp'; Desc = 'cc を plan モードで起動' }
        @{ Cmd = 'ccs'; Desc = 'Sonnet 5 で claude 起動（軽作業向け）' }
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
        @{ Cmd = 'Set-WindowsSettings [-Check]'; Desc = 'Windows 設定（レジストリ）を適用 (-Check で差分のみ)' }
    )
    'Aliases'               = @(
        @{ Cmd = 'cop'; Desc = 'copilot' }
        @{ Cmd = 'g'; Desc = 'git' }
        @{ Cmd = 'which'; Desc = 'Get-Command' }
    )
}

# Show the commands this profile provides. Optional keyword filters cmd/desc/section.
function Show-ProfileHelp {
    param([string]$Filter)

    foreach ($section in $script:ProfileHelp.Keys) {
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
