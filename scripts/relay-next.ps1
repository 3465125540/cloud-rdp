<#
.SYNOPSIS
    保活接力：本轮快到 job 上限时，自动触发下一个 run 接着跑。

.DESCRIPTION
    为什么需要它：
      GitHub-hosted runner 的**单个 job 硬性上限是 6 小时（360 分钟）**，这是平台限制，
      无论怎么改 workflow 都突破不了。所以「保活 48 小时」不可能在一个 run 内完成，
      唯一路径是**接力**：本轮跑满后自动 dispatch 下一个 run，新机器起来后
      从 139 云盘快照恢复（桌面 / 文档 / 程序列表 / 注册表都会回来）。

    代价（必须知道）：
      * 每轮会换一台新机器 → **Tailscale IP 会变**，需要重新看日志取新 IP；
      * 每轮 setup 约 85 分钟（中文语言包是大头）+ 收尾 15 分钟，
        所以单轮「真正可用」约 250 分钟；48 小时 ≈ 需要 11 轮；
      * 两轮之间有排队间隔（GitHub 调度，通常几分钟）。

    触发条件（缺一不接力）：
      * relay_minutes > 0（用户显式要求接力）
      * 剩余分钟 >= MinRemain（默认 60 —— 低于这个不值得再开一台机器）
      * 能拿到 token（GH_RELAY_TOKEN 优先，回退 GITHUB_TOKEN；后者需要 workflow 里
        声明 permissions: actions: write）
      * 本轮尚未接力过（状态文件防重复）

.PARAMETER TotalMinutes
    用户要求的总保活分钟数（来自 workflow_dispatch input relay_minutes）。0 = 不接力。

.PARAMETER ElapsedMinutes
    本轮**实际保活**的分钟数（不含 setup）。

.PARAMETER MinRemain
    剩余低于此值就不再接力。默认 60。

.NOTES
    本脚本永不返回非 0 —— 接力失败不该让整个 job 标红。
#>
[CmdletBinding()]
param(
    [int]   $TotalMinutes   = 0,
    [int]   $ElapsedMinutes = 0,
    [int]   $MinRemain      = 60,
    [int]   $MaxPerRound    = 300,
    [string]$Repository     = $(if ($env:GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY } else { '' }),
    [string]$Workflow       = 'windows-rdp.yml',
    [string]$Ref            = $(if ($env:GITHUB_REF_NAME) { $env:GITHUB_REF_NAME } else { 'main' }),
    [string]$Token          = $(if ($env:GH_RELAY_TOKEN) { $env:GH_RELAY_TOKEN } elseif ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { '' }),
    [string]$Chinese        = 'on',
    [string]$InstallApps    = 'true',
    [string]$LogDir         = '',
    # 仅供单元测试注入本地 mock 服务；生产保持默认
    [string]$ApiBaseUri     = 'https://api.github.com',
    [switch]$Force
)

$ErrorActionPreference = "Continue"

$sysDir = if ($env:CLOUDRDP_SYS_DIR) { $env:CLOUDRDP_SYS_DIR } elseif (Test-Path 'D:\') { 'D:\cloudrdp-sys' } else { 'C:\cloudrdp-sys' }
if ([string]::IsNullOrWhiteSpace($LogDir)) { $LogDir = Join-Path $sysDir '_logs' }

$LogFile    = Join-Path $LogDir 'relay.log'
$StatusFile = Join-Path $LogDir 'relay-status.json'

function Say([string]$m)  { Write-Host "[relay] $m" }
function Log([string]$m) {
    try {
        New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
        "[{0}] {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $m |
            Out-File -LiteralPath $LogFile -Append -Encoding utf8
    } catch { }
}
function Write-Status($obj) {
    try {
        New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
        $obj | ConvertTo-Json -Depth 4 | Out-File -LiteralPath $StatusFile -Encoding UTF8
    } catch { }
}
function Set-GhEnv([string]$kv) {
    if ($env:GITHUB_ENV) {
        try { $kv | Out-File $env:GITHUB_ENV -Append -Encoding ascii } catch { }
    }
}

# ---------------------------------------------------------------- 防重复
if (-not $Force -and (Test-Path -LiteralPath $StatusFile)) {
    try {
        $prev = (Get-Content -LiteralPath $StatusFile -Raw -Encoding UTF8) | ConvertFrom-Json
        if ($prev -and $prev.dispatched -eq $true) {
            Say "本轮已接力过（$(if ($prev.nextDurationMin) { $prev.nextDurationMin } else { '?' }) 分钟），跳过"
            exit 0
        }
    } catch { }
}

# ---------------------------------------------------------------- 前置判断
$remain = $TotalMinutes - $ElapsedMinutes
Say "目标 $TotalMinutes 分钟，本轮已保活 $ElapsedMinutes 分钟，剩余 $remain 分钟"

if ($TotalMinutes -le 0) {
    Say '未要求接力（relay_minutes=0），结束'
    Write-Status ([ordered]@{ dispatched = $false; reason = 'relay_minutes=0'; totalMin = $TotalMinutes; elapsedMin = $ElapsedMinutes; remainMin = $remain; updatedUtc = (Get-Date).ToUniversalTime().ToString('o') })
    exit 0
}
if ($remain -lt $MinRemain) {
    Say "剩余 $remain 分钟 < 阈值 $MinRemain 分钟 —— 再开一台机器不划算，停止接力"
    Write-Status ([ordered]@{ dispatched = $false; reason = "remain($remain) < MinRemain($MinRemain)"; totalMin = $TotalMinutes; elapsedMin = $ElapsedMinutes; remainMin = $remain; updatedUtc = (Get-Date).ToUniversalTime().ToString('o') })
    Set-GhEnv "RELAY_STATE=接力结束（剩余 $remain 分钟不足阈值）"
    exit 0
}
if ([string]::IsNullOrWhiteSpace($Repository)) {
    Say '无法接力：取不到 GITHUB_REPOSITORY'
    Write-Status ([ordered]@{ dispatched = $false; reason = 'no repository'; updatedUtc = (Get-Date).ToUniversalTime().ToString('o') })
    exit 0
}
if ([string]::IsNullOrWhiteSpace($Token)) {
    Say '无法接力：取不到 token（需要 GH_RELAY_TOKEN，或 workflow 里声明 permissions: actions: write）'
    Write-Status ([ordered]@{ dispatched = $false; reason = 'no token'; repository = $Repository; updatedUtc = (Get-Date).ToUniversalTime().ToString('o') })
    exit 0
}

# ---------------------------------------------------------------- 触发下一个 run
$nextDuration = [math]::Min($remain, $MaxPerRound)
$ok   = $false
$note = ''

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $uri  = "$ApiBaseUri/repos/$Repository/actions/workflows/$Workflow/dispatches"
    $body = @{
        ref    = $Ref
        inputs = @{
            duration_minutes = [string]$nextDuration
            relay_minutes    = [string]$remain
            chinese          = $Chinese
            install_apps     = $InstallApps
            migrate_139      = 'false'
            slim_image       = 'auto'
        }
    } | ConvertTo-Json -Depth 5

    Log "POST $uri"
    Log "body: $body"

    $resp = Invoke-RestMethod -Uri $uri -Method Post `
        -Headers @{ Authorization = "Bearer $Token"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'cloud-rdp-relay' } `
        -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) `
        -TimeoutSec 60

    $ok   = $true
    $note = "已触发下一个 run（duration=$nextDuration 分钟，ref=$Ref）"
    Say $note
} catch {
    $detail = ''
    if ($_.Exception.Response) {
        try {
            $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $detail = $sr.ReadToEnd()
            $sr.Close()
        } catch { }
    }
    $note = "触发失败: $($_.Exception.Message) $detail"
    Say $note
    Log $note

    # 401/403 通常是权限不足 —— 给出明确修复指引
    if ($detail -match '401|403|Resource not accessible') {
        Say '提示：默认 GITHUB_TOKEN 无权触发 workflow。两种修法：'
        Say '  1) workflow 顶层加 permissions: { contents: read, actions: write }'
        Say '  2) 或建一个 PAT（勾选 repo + workflow）存成 Secret GH_RELAY_TOKEN'
    }
}

Write-Status ([ordered]@{
    dispatched      = $ok
    reason          = $(if ($ok) { 'dispatched' } else { 'dispatch failed' })
    note            = $note
    repository      = $Repository
    workflow        = $Workflow
    ref             = $Ref
    totalMin        = $TotalMinutes
    elapsedMin      = $ElapsedMinutes
    remainMin       = $remain
    nextDurationMin = $nextDuration
    updatedUtc      = (Get-Date).ToUniversalTime().ToString('o')
})

if ($ok) {
    Set-GhEnv "RELAY_STATE=已接力：下一个 run 保活 $nextDuration 分钟（总剩余 $remain）"
} else {
    Set-GhEnv "RELAY_STATE=接力失败"
}

# 把接力信息告诉用户：公共桌面标记文件（RDP 里一眼能看到）
try {
    $desk = 'C:\Users\Public\Desktop'
    if (Test-Path -LiteralPath $desk) {
        $txt = @(
            'CloudRDP 保活接力',
            '',
            "  目标总时长 : $TotalMinutes 分钟（约 $([math]::Round($TotalMinutes / 60, 1)) 小时）",
            "  本轮已保活 : $ElapsedMinutes 分钟",
            "  剩余       : $remain 分钟",
            ''
        )
        if ($ok) {
            $txt += "  已自动触发下一个 run（$nextDuration 分钟）。"
            $txt += '  新机器会换 IP —— 到 Actions 日志的第 0d 步看新 IP。'
            $txt += '  桌面 / 文档 / 程序会由快照自动恢复。'
        } else {
            $txt += '  接力失败，本轮结束后机器会销毁。'
            $txt += "  原因: $note"
        }
        $txt += ''
        $txt += ('  更新时间 : ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
        ($txt -join "`r`n") | Out-File -LiteralPath (Join-Path $desk '_CloudRDP_RELAY.txt') -Encoding UTF8
    }
} catch { }

exit 0
