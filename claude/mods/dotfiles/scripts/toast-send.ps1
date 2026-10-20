# toast-notify の通知送信。TOAST_NOTIFY_TITLE / BODY / SESSION / LEVEL / APP を環境変数で受け取る（引数経由の注入を避ける）
# mod（hooks/toast-notify/register.ts）と scripts/lite-hook.mjs の両方がこのファイルを使う
$ErrorActionPreference = 'Stop'
$sent = $false
try { Add-Type -Namespace ToastNotify -Name Wts -MemberDefinition '[DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Ansi)] public static extern IntPtr WTSVirtualChannelOpen(IntPtr hServer, int sessionId, string name); [DllImport("wtsapi32.dll", SetLastError = true)] public static extern bool WTSVirtualChannelWrite(IntPtr h, byte[] buffer, int length, out int written); [DllImport("wtsapi32.dll")] public static extern bool WTSVirtualChannelClose(IntPtr h);'; $m = if ($env:TOAST_NOTIFY_SESSION) { $env:TOAST_NOTIFY_BODY + [Environment]::NewLine + $env:TOAST_NOTIFY_SESSION } else { $env:TOAST_NOTIFY_BODY }; $j = @{ title = $env:TOAST_NOTIFY_TITLE; message = $m; level = $env:TOAST_NOTIFY_LEVEL } | ConvertTo-Json -Compress; $p = [Text.Encoding]::ASCII.GetBytes([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($j))); $h = if ($p.Length -le 1500) { [ToastNotify.Wts]::WTSVirtualChannelOpen([IntPtr]::Zero, -1, 'CCNOTIF') } else { [IntPtr]::Zero }; if ($h -ne [IntPtr]::Zero) { try { $w = 0; $sent = [ToastNotify.Wts]::WTSVirtualChannelWrite($h, $p, $p.Length, [ref]$w) -and $w -eq $p.Length } finally { [void][ToastNotify.Wts]::WTSVirtualChannelClose($h) } } } catch { }
if ($sent) { exit 0 }
[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
[void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
$t = [Security.SecurityElement]::Escape($env:TOAST_NOTIFY_TITLE)
$b = [Security.SecurityElement]::Escape($env:TOAST_NOTIFY_BODY)
$s = [Security.SecurityElement]::Escape($env:TOAST_NOTIFY_SESSION)
$a = if ($s) { '<text placement=''attribution''>' + $s + '</text>' } else { '' }
$x = New-Object Windows.Data.Xml.Dom.XmlDocument
$x.LoadXml('<toast><visual><binding template=''ToastGeneric''><text>' + $t + '</text><text>' + $b + '</text>' + $a + '</binding></visual></toast>')
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($env:TOAST_NOTIFY_APP).Show([Windows.UI.Notifications.ToastNotification]::new($x))
