<#
.HOOK
{
  "event": "PostToolUse",
  "matcher": "Edit|Write"
}
#>
# post-edit-syntax-check.ps1
# 編集直後に構文レベルの検証を行い、失敗時のみ結果をClaudeに差し戻すhook
# (success is silent, failures are verbose)
# 対象: .ps1/.psm1/.psd1 (PSパーサ), .json (パース), .py (py_compile)

param()

try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}

$raw = $input | Out-String
try {
    $data = $raw | ConvertFrom-Json
} catch {
    exit 0
}

$path = $data.tool_input.file_path
if (-not $path -or -not (Test-Path -LiteralPath $path)) { exit 0 }

$problem = $null
switch -Regex ([System.IO.Path]::GetExtension($path).ToLower()) {
    '^\.(ps1|psm1|psd1)$' {
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errs) | Out-Null
        if ($errs) {
            $problem = ($errs | Select-Object -First 3 | ForEach-Object {
                "L$($_.Extent.StartLineNumber): $($_.Message)"
            }) -join " / "
        }
    }
    '^\.json$' {
        try { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json | Out-Null }
        catch { $problem = $_.Exception.Message }
    }
    '^\.py$' {
        if (Get-Command py -ErrorAction Ignore) {
            $out = & py -m py_compile $path 2>&1
            if ($LASTEXITCODE -ne 0) { $problem = ($out | Out-String).Trim() }
        }
    }
}

if ($problem) {
    if ($problem.Length -gt 500) { $problem = $problem.Substring(0, 500) + "..." }
    [PSCustomObject]@{
        decision = "block"
        reason   = "構文チェック失敗 ($([System.IO.Path]::GetFileName($path))): $problem"
    } | ConvertTo-Json -Compress
}

exit 0
