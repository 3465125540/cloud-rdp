<#
.SYNOPSIS
  把本次开机的 RDP 连接信息（Tailscale IP / 账号 / 密码）发到用户邮箱。

.DESCRIPTION
  仓库已转公开，RDP 密码不能再写死在 workflow 里（会永久留在公网 git 历史）。
  现在密码走 Secret，Actions 日志里会被自动打码成 ***，所以改由邮件投递。
  正文刻意写在脚本里而不是 YAML 的 here-string —— YAML 块标量的缩进规则
  会把顶格的 here-string 正文判成语法错误。

.NOTES
  读取环境变量：
    TS_IP         Tailscale IP（由 workflow 第 0c 步写入）
    RDP_USER      用户名
    RDP_PASSWORD  密码（来自 Secret，勿打印到日志）
  其余 MAIL_* 由 send-mail.ps1 自己读。
  退出码：未配置邮箱 -> 0（跳过）；发送失败 -> 1（调用方 continue-on-error 兜住）。
#>

[CmdletBinding()]
param(
    [string]$Ip = $env:TS_IP,
    [string]$User = $env:RDP_USER,
    [string]$Pass = $env:RDP_PASSWORD,
    [string]$Elapsed = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

if (-not $Ip) { $Ip = '(未取到，见 Tailscale 后台 github-rdp-server*)' }
if (-not $User) { $User = 'NvdAdmin' }
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

Write-Host "[connmail] 准备发送连接信息到邮箱（IP=$Ip）"
& $mailScript -Subject "CloudRDP 连接信息（$Ip）" -BodyText $body -DryRun:$DryRun
exit $LASTEXITCODE
