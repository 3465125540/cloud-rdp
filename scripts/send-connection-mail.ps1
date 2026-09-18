<#
.SYNOPSIS
  把本次开机的 RDP 连接信息（Tailscale IP / 账号 / 密码）发到用户邮箱。

.DESCRIPTION
  仓库是公开的，RDP 账号密码按用户要求写死在 workflow（明文打印、方便直接取用），
  同时主动发一封邮件到用户邮箱，省得每次去翻 Actions 日志。
  正文刻意写在脚本里而不是 YAML 的 here-string —— YAML 块标量的缩进规则
  会把顶格的 here-string 正文判成语法错误。

.NOTES
  读取环境变量：
    TS_IP         Tailscale IP（由 workflow 第 0c 步写入）
    RDP_USER      用户名
    RDP_PASSWORD  密码
  其余 MAIL_* 由 send-mail.ps1 自己读。
  退出码：未配置邮箱 -> 0（跳过）；发送失败 -> 1（调用方 continue-on-error 兜住）。
  诊断日志：默认 D:\cloudrdp-sys\_state\mail.log（用 -LogPath 覆盖）。
#>

[CmdletBinding()]
param(
    [string]$Ip = $env:TS_IP,
    [string]$User = $env:RDP_USER,
    [string]$Pass = $env:RDP_PASSWORD,
    [string]$Elapsed = '',
    # 诊断日志：0e 步带 continue-on-error，失败会被静默吞掉 —— 落盘才查得到原因
    [string]$LogPath = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $sysDir = if ($env:CLOUDRDP_SYS_DIR) { $env:CLOUDRDP_SYS_DIR } elseif (Test-Path 'D:\') { 'D:\cloudrdp-sys' } else { 'C:\cloudrdp-sys' }
    $LogPath = Join-Path (Join-Path $sysDir '_state') 'mail.log'
}

if (-not $Ip) { $Ip = '(未取到，见 Tailscale 后台 github-rdp-server*)' }
if (-not $User) { $User = 'a' }
if (-not $Pass) { $Pass = '(未取到，见公共桌面 _CloudRDP_*.txt)' }

$lines = @(
    'CloudRDP 已开机，现在就能连。'
    ''
    "  Tailscale IP : $Ip"
    "  用户名       : $User"
    "  密码         : $Pass"
    ''
    '怎么连：Win+R 输入 mstsc -> 地址填上面的 IP -> 用上面的账号密码登录。'
    ''
    '注意：'
    '  * 必须先连上同一个 Tailscale 网络（tailnet）。'
    '  * 看不到 IP 时，到 https://login.tailscale.com/admin/machines 找 github-rdp-server*'
    '  * 此刻后台仍在初始化（C盘瘦身 / 数据恢复 / 中文环境 / 软件重装），预计 30~60 分钟。'
    '    想用满血环境，等 Actions 日志出现【ENV READY】再登录更稳妥。'
    ''
    '-- 由 GitHub Actions 自动发送'
)
$body = ($lines -join "`r`n")

$mailScript = Join-Path $PSScriptRoot 'send-mail.ps1'
if (-not (Test-Path -LiteralPath $mailScript)) { throw "找不到 $mailScript" }

Write-Host "[connmail] 准备发送连接信息到邮箱（IP=$Ip），日志：$LogPath"
& $mailScript -Subject "CloudRDP 连接信息（$Ip）" -BodyText $body -LogPath $LogPath -DryRun:$DryRun
exit $LASTEXITCODE
