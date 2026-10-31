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
        @{ Group = '状態と履歴'; Cmd = 'gl'; Desc = 'コミット履歴を枝分かれ図つきで直近 20 件表示' }
        @{ Group = '状態と履歴'; Cmd = 'git-log-browse'; Desc = 'fzf でコミットを閲覧 (差分プレビュー。delta があれば色付き)' }
        @{ Group = '状態と履歴'; Cmd = 'lg'; Desc = 'lazygit を起動 (あれば)' }
        @{ Group = 'ブランチ'; Cmd = 'git-switch'; Desc = 'fzf でブランチ切替 (ローカルに無ければ origin から作成して追跡)' }
        @{ Group = 'ブランチ'; Cmd = 'git-worktree-switch'; Desc = '現在のリポジトリの worktree を fzf で選んで移動 (ブランチ名付き)' }
        @{ Group = 'ブランチ'; Cmd = 'git-clean-branches'; Desc = 'マージ済みのローカルブランチを確認後に一括削除 (main/master/develop は残す)' }
        @{ Group = '取得と同期'; Cmd = 'git-fetch / gf'; Desc = '全リモートを取得して削除済みを掃除 (大文字小文字違いの ref 衝突を回避)' }
        @{ Group = '取得と同期'; Cmd = 'git-pull / gpl'; Desc = '安全な pull: 未コミット変更を退避 → 衝突ファイルを .git/pull-backup へ避難 → pull → 復元 (引数は git pull へ)' }
        @{ Group = '移動とクローン'; Cmd = 'git-root'; Desc = 'リポジトリのルートへ移動' }
        @{ Group = '移動とクローン'; Cmd = 'git-clone <url>'; Desc = 'クローンして、そのフォルダへ移動' }
        @{ Group = '破壊的操作'; Cmd = 'git-reset-clean'; Desc = '変更破棄 + 未追跡・ignore 対象もリポジトリ全体から確認なしで削除 (-Ref)' }
        @{ Group = 'GitHub PR'; Cmd = 'prc/prv/prl/prs'; Desc = 'GitHub PR の作成 / ブラウザ表示 / 一覧 / 状況 (gh があれば)' }
        @{ Group = '複数リポジトリ (gita)'; Cmd = 'gita-pull-all'; Desc = 'gita 全リポジトリの nul ファイルを掃除して pull し、失敗したリポジトリを最後に一覧 (-Fallback で切替先指定)' }
        @{ Group = '複数リポジトリ (gita)'; Cmd = 'gita-scan [path]'; Desc = '直下の git リポジトリを gita に一括登録' }
        @{ Group = '複数リポジトリ (gita)'; Cmd = 'gita-doctor [-Deep]'; Desc = 'gita の登録の不備 (確認して削除) と壊れたリポジトリ (status 失敗 / HEAD 異常 / lock 残骸 / merge 途中。-Deep で fsck) を検出' }
        @{ Group = 'ヘルプ'; Cmd = 'git-help'; Desc = 'この一覧と .gitconfig の git alias をまとめて表示' }
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
        @{ Cmd = 'Enable-SshServer [-SetPrivate] [-DisablePasswordAuth]'; Desc = '接続される側: OpenSSH Server を導入・自動起動・pwsh を既定シェルに、Domain/Private で port 22 を開放 (-SetPrivate で Public を Private に、-DisablePasswordAuth で鍵のみに、要管理者)' }
        @{ Cmd = 'Add-SshHost <host> <user> [-Alias]'; Desc = '接続する側: パスフレーズ付きの鍵を作って ssh-agent と相手に登録し ~/.ssh/config に追記' }
        @{ Cmd = 'Invoke-SshAll <command> [-Path]'; Desc = '~/.ssh/hosts.txt の全ホストでコマンドを並列実行し、Host / ExitCode / Output を返す' }
    )
    'Aliases'               = @(
        @{ Cmd = 'cop'; Desc = 'copilot' }
        @{ Cmd = 'g'; Desc = 'git' }
        @{ Cmd = 'which'; Desc = 'Get-Command' }
    )
}

# Show the commands this profile provides. Optional keyword filters cmd/desc/section.
# Items carrying a Group key are printed under that group's heading, in catalog order.
# Group headings sit at indent 2 and command rows at indent 4, so the two never look alike.
function Show-ProfileHelp {
    param([string]$Filter, [string]$OnlySection, [switch]$NoTip)

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
        $lastGroup = $null
        foreach ($i in $items) {
            if ($i.Group -and $i.Group -ne $lastGroup) {
                Write-Host "  $($i.Group)" -ForegroundColor DarkCyan
                $lastGroup = $i.Group
            }
            Write-Host ('    {0,-22}' -f $i.Cmd) -ForegroundColor Yellow -NoNewline
            Write-Host $i.Desc -ForegroundColor Gray
        }
    }
    if ($NoTip) { return }
    Write-Host ''
    Write-Host "tip: 'phelp <keyword>' で絞り込み (例: phelp git) / Ctrl+g でコマンドパレット検索 / Ctrl+r で履歴検索" -ForegroundColor DarkGray
}
Set-Alias phelp Show-ProfileHelp

# .gitconfig の [alias] を `g <alias>` 形式で一覧表示する。git が無ければ何も出さない。
function Show-GitAliasHelp {
    if (-not (Test-Cmd git)) { return }
    $rows = @(git config --get-regexp '^alias\.' 2>$null | Sort-Object)
    if (-not $rows) { return }

    Write-Host ''
    Write-Host '[git alias]' -ForegroundColor Cyan
    foreach ($row in $rows) {
        $name, $body = $row -split ' ', 2
        $body = 'git ' + $body
        if ($body.Length -gt 64) { $body = $body.Substring(0, 61) + '...' }
        Write-Host ('    {0,-22}' -f ('g ' + ($name -replace '^alias\.', ''))) -ForegroundColor Yellow -NoNewline
        Write-Host $body -ForegroundColor Gray
    }
}

# Git 系コマンドと git alias をまとめて表示
function git-help {
    Show-ProfileHelp -OnlySection 'Git / GitHub' -NoTip
    Show-GitAliasHelp
    Write-Host ''
    Write-Host 'tip: 素の git を短く打つなら git alias 側 (g s / g co / g cm <msg>) / Ctrl+g でコマンドパレット検索' -ForegroundColor DarkGray
}
