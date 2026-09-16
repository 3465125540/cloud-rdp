<#
.SYNOPSIS
  无外部依赖的 SMTP 发信（隐式 SSL / STARTTLS / 明文），用于把 RDP 连接信息发到用户邮箱。

.DESCRIPTION
  为什么不用 System.Net.Mail.SmtpClient：
    它只会发 STARTTLS，无法连接 465 端口（隐式 SSL）—— 而 QQ / 163 邮箱默认就是 465。
  这里直接用 TcpClient + SslStream 走完整 SMTP 对话，ssl / starttls / none 三条路都通。

  另注意：SslStream.AuthenticateAsClient($host) 单参重载在 .NET Framework 上用的是
  SslProtocols.Default（含已被现代服务器禁用的 TLS1.0），必须显式传协议位。

.NOTES
  环境变量（全部来自 GitHub Secrets，绝不写进仓库）：
    MAIL_SMTP_HOST   SMTP 服务器，如 smtp.qq.com
    MAIL_SMTP_PORT   端口，默认 465（465=隐式SSL / 587=STARTTLS / 25=明文）
    MAIL_USER        发件邮箱（登录账号）
    MAIL_PASS        SMTP 授权码（不是邮箱登录密码）
    MAIL_TO          收件人；多个用 , ; 或空格分隔
  可选环境变量：
    MAIL_FROM        发件人地址，默认 = MAIL_USER
    MAIL_FROM_NAME   发件人显示名，默认 CloudRDP
    MAIL_CC          抄送
    MAIL_SECURITY    auto(默认，按端口推断) / ssl / starttls / none
    MAIL_SUBJECT     主题，默认「CloudRDP 连接信息」
    MAIL_BODY        正文

  行为约定：
    * 关键配置缺失时 → 打印提示并 exit 0（视为「未启用邮箱」，不算失败）。
    * 发信失败 → 抛异常，exit 非 0；调用方用 continue-on-error 兜住，不阻断开机。
    * -DryRun → 不联网，只打印将发送的 MIME 内容（用于本地验证）。
#>

[CmdletBinding()]
param(
    [string]$SmtpHost,
    [int]$SmtpPort = 0,
    [ValidateSet('auto', 'ssl', 'starttls', 'none')][string]$Security = 'auto',
    [string]$SmtpUser,
    [string]$SmtpPass,
    [string]$MailFrom,
    [string]$FromName,
    [string]$MailTo,
    [string]$MailCc,
    [string]$Subject,
    [string]$BodyText,
    [int]$TimeoutSec = 45,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 0. 回填环境变量
if (-not $SmtpHost) { $SmtpHost = $env:MAIL_SMTP_HOST }
if ($SmtpPort -le 0) {
    $SmtpPort = if ($env:MAIL_SMTP_PORT) { [int]$env:MAIL_SMTP_PORT } else { 465 }
}
if ($Security -eq 'auto' -and $env:MAIL_SECURITY) {
    $v = $env:MAIL_SECURITY.Trim().ToLower()
    if (@('ssl', 'starttls', 'none') -contains $v) { $Security = $v }
}
if ($Security -eq 'auto') {
    $Security = switch ($SmtpPort) { 465 { 'ssl' } 587 { 'starttls' } 25 { 'none' } default { 'ssl' } }
}
if (-not $SmtpUser) { $SmtpUser = $env:MAIL_USER }
if (-not $SmtpPass) { $SmtpPass = $env:MAIL_PASS }
if (-not $MailFrom) {
    $MailFrom = if ($env:MAIL_FROM) { $env:MAIL_FROM } else { $SmtpUser }
}
if (-not $FromName) {
    $FromName = if ($env:MAIL_FROM_NAME) { $env:MAIL_FROM_NAME } else { 'CloudRDP' }
}
if (-not $MailTo) { $MailTo = $env:MAIL_TO }
if (-not $MailCc) { $MailCc = $env:MAIL_CC }
if (-not $Subject) {
    $Subject = if ($env:MAIL_SUBJECT) { $env:MAIL_SUBJECT } else { 'CloudRDP 连接信息' }
}
if (-not $BodyText) { $BodyText = $env:MAIL_BODY }

# ---------------------------------------------------------------- 1. 缺配置则优雅跳过
$missing = @()
if (-not $SmtpHost) { $missing += 'MAIL_SMTP_HOST' }
if (-not $SmtpUser) { $missing += 'MAIL_USER' }
if (-not $SmtpPass) { $missing += 'MAIL_PASS' }
if (-not $MailTo)   { $missing += 'MAIL_TO' }
if (-not $BodyText) { $missing += 'MAIL_BODY' }
if ($missing.Count -gt 0) {
    Write-Host ("[mail] 未配置 " + ($missing -join ', ') + " —— 跳过发信（不算失败）")
    exit 0
}

# ---------------------------------------------------------------- 2. 工具函数
function ConvertTo-B64([string]$s) {
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s))
}

function Format-Rfc2047([string]$s) {
    # 纯 ASCII 直接用；含中文则 RFC2047 B 编码，避免邮件客户端乱码
    if ($s -match '^[\x20-\x7E]*$') { return $s }
    return '=?UTF-8?B?' + (ConvertTo-B64 $s) + '?='
}

function Format-AddrHeader([string]$name, [string]$addr) {
    if ([string]::IsNullOrWhiteSpace($name)) { return $addr }
    return '"' + (Format-Rfc2047 $name) + '" <' + $addr + '>'
}

function Split-Addrs([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return @() }
    return @($s -split '[,;\s]+' | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
}

$toList = @(Split-Addrs $MailTo)
$ccList = @(Split-Addrs $MailCc)
if ($toList.Count -eq 0) {
    Write-Host "[mail] MAIL_TO 解析后为空 —— 跳过发信（不算失败）"
    exit 0
}

# ---------------------------------------------------------------- 3. 组装 MIME
$b64 = ConvertTo-B64 $BodyText
$sb = [System.Text.StringBuilder]::new()
for ($i = 0; $i -lt $b64.Length; $i += 76) {
    $n = [Math]::Min(76, $b64.Length - $i)
    [void]$sb.Append($b64.Substring($i, $n)).Append("`r`n")
}
$bodyB64 = $sb.ToString().TrimEnd()

$hdr = [System.Text.StringBuilder]::new()
[void]$hdr.Append('From: ' + (Format-AddrHeader $FromName $MailFrom) + "`r`n")
[void]$hdr.Append('To: ' + ($toList -join ', ') + "`r`n")
if ($ccList.Count -gt 0) { [void]$hdr.Append('Cc: ' + ($ccList -join ', ') + "`r`n") }
[void]$hdr.Append('Subject: ' + (Format-Rfc2047 $Subject) + "`r`n")
# 必须 ToUniversalTime()：'r' 只格式化本地时间再拼字面量 "GMT"，直接用会差一个时区
[void]$hdr.Append('Date: ' + (Get-Date).ToUniversalTime().ToString('r') + "`r`n")
[void]$hdr.Append('Message-ID: <' + [guid]::NewGuid().ToString('N') + '@cloudrdp>' + "`r`n")
[void]$hdr.Append("MIME-Version: 1.0`r`n")
[void]$hdr.Append("Content-Type: text/plain; charset=utf-8`r`n")
[void]$hdr.Append("Content-Transfer-Encoding: base64`r`n")
[void]$hdr.Append("X-Mailer: CloudRDP`r`n")
[void]$hdr.Append("`r`n")
$payload = $hdr.ToString() + $bodyB64

# ---------------------------------------------------------------- 4. DryRun
if ($DryRun) {
    Write-Host '[mail][dry-run] 不联网，仅展示将发送的内容'
    Write-Host "  服务器   : $SmtpHost`:$SmtpPort（$Security）"
    Write-Host "  认证账号 : $SmtpUser"
    Write-Host "  发件人   : $FromName <$MailFrom>"
    Write-Host "  收件人   : $($toList -join ', ')"
    if ($ccList.Count -gt 0) { Write-Host "  抄送     : $($ccList -join ', ')" }
    Write-Host "  主题     : $Subject"
    Write-Host '  -------- 正文（解码后）--------'
    Write-Host $BodyText
    Write-Host '  -------- 原始 MIME --------'
    Write-Host $payload
    exit 0
}

# ---------------------------------------------------------------- 5. SMTP 对话
function New-SmtpReader([System.IO.Stream]$s) {
    return [System.IO.StreamReader]::new($s, [System.Text.Encoding]::ASCII, $false, 4096, $true)
}
function New-SmtpWriter([System.IO.Stream]$s) {
    $w = [System.IO.StreamWriter]::new($s, [System.Text.Encoding]::ASCII, 4096, $true)
    $w.NewLine = "`r`n"
    $w.AutoFlush = $true
    return $w
}
function Read-SmtpReply($reader, [string]$tag) {
    $lines = [System.Collections.Generic.List[string]]::new()
    while ($true) {
        $line = $reader.ReadLine()
        if ($null -eq $line) { throw "[$tag] SMTP 连接被对端关闭（读到 EOF）" }
        $lines.Add($line)
        # 末行形如 "250 xxx"（第 4 位是空格）；多行应答中间是 "250-xxx"
        if ($line.Length -ge 4 -and $line[3] -eq ' ') { break }
        if ($line.Length -eq 3) { break }
    }
    $last = $lines[$lines.Count - 1]
    $code = 0
    if ($last.Length -ge 3) { [void][int]::TryParse($last.Substring(0, 3), [ref]$code) }
    return [pscustomobject]@{ Code = $code; Lines = @($lines.ToArray()) }
}
function Invoke-SmtpCmd($writer, $reader, [string]$cmd, [int[]]$expect, [string]$tag) {
    if (-not [string]::IsNullOrEmpty($cmd)) {
        $writer.Write($cmd + "`r`n")
        $writer.Flush()
    }
    $r = Read-SmtpReply $reader $tag
    if ($expect -and ($expect -notcontains $r.Code)) {
        throw "[$tag] 期望 $($expect -join '/')，实际 $($r.Code)：$($r.Lines -join ' | ')"
    }
    return $r
}

# 显式协议位：单参 AuthenticateAsClient 在 .NET Framework 上会退化成 TLS1.0
$proto = [System.Security.Authentication.SslProtocols]::Tls12
try { $proto = $proto -bor [System.Security.Authentication.SslProtocols]::Tls13 } catch { }
$certColl = New-Object System.Security.Cryptography.X509Certificates.X509CertificateCollection

function Connect-Tls([System.IO.Stream]$raw, [string]$hostName, [int]$timeoutMs, $proto, $certColl) {
    $ssl = [System.Net.Security.SslStream]::new($raw, $false)
    $ssl.ReadTimeout = $timeoutMs
    $ssl.WriteTimeout = $timeoutMs
    $ssl.AuthenticateAsClient($hostName, $certColl, $proto, $false)
    return $ssl
}

$timeoutMs = $TimeoutSec * 1000
$client = $null; $stream = $null; $reader = $null; $writer = $null
try {
    Write-Host "[mail] 连接 $SmtpHost`:$SmtpPort（$Security）..."
    $client = [System.Net.Sockets.TcpClient]::new()
    $iar = $client.BeginConnect($SmtpHost, $SmtpPort, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne($timeoutMs, $false)) {
        throw "连接 $SmtpHost`:$SmtpPort 超时（$TimeoutSec 秒）"
    }
    $client.EndConnect($iar)
    $client.ReceiveTimeout = $timeoutMs
    $client.SendTimeout = $timeoutMs
    $stream = $client.GetStream()

    if ($Security -eq 'ssl') {
        $stream = Connect-Tls $stream $SmtpHost $timeoutMs $proto $certColl
    }

    $reader = New-SmtpReader $stream
    $writer = New-SmtpWriter $stream

    Invoke-SmtpCmd $writer $reader $null @(220) 'greeting' | Out-Null
    $ehlo = Invoke-SmtpCmd $writer $reader ("EHLO " + $env:COMPUTERNAME) @(250) 'EHLO'

    if ($Security -eq 'starttls') {
        Invoke-SmtpCmd $writer $reader 'STARTTLS' @(220) 'STARTTLS' | Out-Null
        $writer.Dispose(); $reader.Dispose()      # leaveOpen=true，不会关掉底层流
        $stream = Connect-Tls $stream $SmtpHost $timeoutMs $proto $certColl
        $reader = New-SmtpReader $stream
        $writer = New-SmtpWriter $stream
        $ehlo = Invoke-SmtpCmd $writer $reader ("EHLO " + $env:COMPUTERNAME) @(250) 'EHLO(2)'
    }

    # ---- AUTH：优先 LOGIN，失败再退 PLAIN ----
    $mechs = ''
    foreach ($l in $ehlo.Lines) { if ($l -match '(?i)AUTH\s+(.+)$') { $mechs = $Matches[1] } }
    $authed = $false
    if ($mechs -eq '' -or $mechs -match '(?i)LOGIN') {
        try {
            Invoke-SmtpCmd $writer $reader 'AUTH LOGIN' @(334) 'AUTH LOGIN' | Out-Null
            Invoke-SmtpCmd $writer $reader (ConvertTo-B64 $SmtpUser) @(334) 'AUTH user' | Out-Null
            Invoke-SmtpCmd $writer $reader (ConvertTo-B64 $SmtpPass) @(235) 'AUTH pass' | Out-Null
            $authed = $true
        } catch {
            Write-Host "[mail] AUTH LOGIN 失败，改用 AUTH PLAIN：$_"
        }
    }
    if (-not $authed) {
        $plain = ConvertTo-B64 ("`0" + $SmtpUser + "`0" + $SmtpPass)
        Invoke-SmtpCmd $writer $reader ('AUTH PLAIN ' + $plain) @(235) 'AUTH PLAIN' | Out-Null
    }

    Invoke-SmtpCmd $writer $reader ('MAIL FROM:<' + $MailFrom + '>') @(250) 'MAIL FROM' | Out-Null
    foreach ($a in $toList) { Invoke-SmtpCmd $writer $reader ('RCPT TO:<' + $a + '>') @(250, 251) 'RCPT TO' | Out-Null }
    foreach ($a in $ccList) { Invoke-SmtpCmd $writer $reader ('RCPT TO:<' + $a + '>') @(250, 251) 'RCPT TO(cc)' | Out-Null }
    Invoke-SmtpCmd $writer $reader 'DATA' @(354) 'DATA' | Out-Null
    $writer.Write($payload + "`r`n.`r`n")
    $writer.Flush()
    Invoke-SmtpCmd $writer $reader $null @(250) 'DATA end' | Out-Null
    try { Invoke-SmtpCmd $writer $reader 'QUIT' @(221) 'QUIT' | Out-Null } catch { }

    Write-Host "[mail] 已发送：$($toList -join ', ')"
    exit 0
} catch {
    Write-Host "[mail] 发送失败：$_" -ForegroundColor Red
    exit 1
} finally {
    foreach ($x in @($writer, $reader, $stream, $client)) {
        if ($x) { try { $x.Dispose() } catch { } }
    }
}
