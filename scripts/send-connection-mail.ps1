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
  退出码：始终 0 —— 连接信息已在日志明文打印（可直接取用），邮件失败不算错误；
          真正的配置问题（认证失败等）仍会写 MAIL_RESULT=FAIL:*，由第 13 步汇总展示。
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

# ── 备用通道（UU远程）：并进**同一封**邮件 ────────────────────────────────────
# 为什么合并：0c1 与 0e 会在几秒内各发一封「同发件人 / 同收件人 / 同前缀主题」的邮件 ——
# 真机 2026-10-07 实测：0c1 那封 250 通过却没到，0e 那封（被 550 拒后重试）到了 ⇒
# 139 对**近乎同时的近似重复邮件只投一封**。合并成一封最稳。
$uuLines = @()
try {
    $uuStateDir = if ($env:CLOUDRDP_SYS_DIR) { [string]$env:CLOUDRDP_SYS_DIR }
                  elseif (Test-Path 'D:\') { 'D:\cloudrdp-sys' } else { 'C:\cloudrdp-sys' }
    $uuJson = Join-Path (Join-Path $uuStateDir '_state') 'uu-remote.json'
    if (Test-Path -LiteralPath $uuJson) {
        $u = Get-Content -LiteralPath $uuJson -Raw -Encoding UTF8 | ConvertFrom-Json
        $uuCode = if ($u.customCode) { [string]$u.customCode } elseif ($u.assistCode) { [string]$u.assistCode } else { '' }
        if ($u.deviceId -or $uuCode) {
            $uuLines = @(
                ''
                '备用通道（UU远程，主通道连不上时用）：'
                "  机器     : $($u.machine)"
                "  设备 ID  : $($u.deviceId)"
                "  连接码   : $uuCode"
                ''
                '怎么用：手机/电脑装「网易UU远程」→ 远程协助 → 填「设备 ID + 连接码」。'
            )
        }
    }
} catch { }

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
) + $uuLines + @(
    ''
    '-- 由 GitHub Actions 自动发送'
)
$body = ($lines -join "`r`n")

$mailScript = Join-Path $PSScriptRoot 'send-mail.ps1'
if (-not (Test-Path -LiteralPath $mailScript)) { throw "找不到 $mailScript" }

# 发送前先把连接信息明文打印到日志 —— 无论邮件成败，这里都能直接取用。
# 这是用户明确要求：账号密码写死在 workflow、明文打印、方便直接取用，邮件只是补充。
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  CloudRDP 连接信息（日志可直接取用）" -ForegroundColor Cyan
Write-Host "  Tailscale IP : $Ip" -ForegroundColor Yellow
Write-Host "  用户名       : $User" -ForegroundColor Yellow
Write-Host "  密码         : $Pass" -ForegroundColor Yellow
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""

Write-Host "[connmail] 准备发送连接信息到邮箱（IP=$Ip），日志：$LogPath"
& $mailScript -Subject "CloudRDP 连接信息（$Ip）" -BodyText $body -LogPath $LogPath -DryRun:$DryRun
$rc = $LASTEXITCODE
if ($rc -eq 0) {
    Write-Host "[connmail] 邮件已发送"
} else {
    # 连接信息已在上面明文打印，邮件失败不算错误（139 灰名单 450 很常见，重试仍可能被拒）。
    # 不再 exit 1 让 step 标红 —— 详细诊断见 mail.log；MAIL_RESULT 仍由 send-mail.ps1 写好。
    Write-Host "[connmail] 邮件发送失败（返回码 $rc）—— 连接信息已明文打印在上方，可直接取用；诊断见 $LogPath" -ForegroundColor Yellow
}

# ── 会话交接（让 UU远程 落到 a，而不是 runneradmin）────────────────────────────
# 为什么挂在这里：老 fork（如 acc-5 / d67e81d）只同步 scripts/，内联 workflow 步骤改不动，
# 所以「装 SYSTEM 交接任务 CloudRDP-UUHandover + 公共桌面『切到 UU远程』快捷方式 +
# 无感自动交接任务 CloudRDP-UUAuto」这件事必须放在 scripts/ 里、并挂到一个老 fork 本来就会
# 调用的脚本上 —— 0e 步（本脚本）是够早的钩子。
# 幂等、fail-soft：任何失败都只打印一行，绝不影响连接信息（本脚本本来就 exit 0）。
try {
    $sessLib = Join-Path $PSScriptRoot 'session-lib.ps1'
    if (Test-Path -LiteralPath $sessLib) {
        . $sessLib
        if (Get-Command Install-RdpSessionHandoverTask -ErrorAction SilentlyContinue) {
            $tk = Install-RdpSessionHandoverTask -RdpUser $User -ScriptPath (Join-Path $PSScriptRoot 'session-handover.ps1')
            if ($tk.ok) {
                Write-Host "[connmail] UU远程 交接任务已就绪：$($tk.task) / 快捷方式：$($tk.shortcut) / 无感自动：$($tk.auto)"
                # 「无感自动：CloudRDP-UUAuto」只是任务名，失败也照打 → 真实成败单独打出来
                Write-Host "[connmail] ② 桌面快捷方式 ok=$($tk.shortcutOk) :: $($tk.shortcutNote)"
                Write-Host "[connmail] ③ 无感自动交接 ok=$($tk.autoOk) :: $($tk.autoNote)"
            }
            else        { Write-Host "[connmail] UU远程 交接任务未安装（可忽略）：$($tk.note)" -ForegroundColor Yellow }
        }
    }
} catch { Write-Host "[connmail] UU远程 交接安装失败（可忽略）：$($_.Exception.Message)" -ForegroundColor Yellow }

exit 0
