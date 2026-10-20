# PSReadLine の履歴ファイルを新しい順・重複なしで出力する。引数の語をすべて含む項目だけに絞る。
# 複数行の項目は、最終行以外の行末がバッククォート（hooks/cmdHistory/register.tsx の parseHistory と同じ規則）
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Words)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$max = 3000
$limit = 30

$path = Join-Path $env:APPDATA 'Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt'
if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    Write-Output 'PowerShell の履歴が見つかりませんでした。'
    exit 0
}

$items = [System.Collections.Generic.List[string]]::new()
$pending = [System.Collections.Generic.List[string]]::new()
foreach ($line in [IO.File]::ReadAllLines($path)) {
    if ($line.EndsWith('`')) { $pending.Add($line.Substring(0, $line.Length - 1)); continue }
    $pending.Add($line)
    $item = ($pending -join "`n").Trim()
    $pending.Clear()
    if ($item -ne '') { $items.Add($item) }
}
$items.Reverse()
$list = @($items | Select-Object -Unique -First $max)
foreach ($w in @($Words | Where-Object { $_ })) { $list = @($list | Where-Object { $_.IndexOf($w, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) }

if ($list.Count -eq 0) { Write-Output '一致する履歴がありません。'; exit 0 }
$n = [Math]::Min($limit, $list.Count)
for ($i = 0; $i -lt $n; $i++) { Write-Output ('{0,2}. {1}' -f ($i + 1), $list[$i]) }
if ($list.Count -gt $n) { Write-Output "(ほか $($list.Count - $n) 件。語を足して絞り込めます)" }
