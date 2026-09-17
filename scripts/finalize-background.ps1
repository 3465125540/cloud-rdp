<#
.SYNOPSIS
    CloudRDP 关机收尾（C 盘清理 → 全量同步 → 整机快照）。

.DESCRIPTION
    原本这三件事是 workflow 第 15 步**顺序执行**的：跑完才会让 job 结束。
    问题是「跑收尾」期间虽然机器还活着，但整个流程是阻塞式的，一旦收尾结束
    job 立刻终止 → runner 销毁 → RDP 断开。

    本脚本把它拆成**后台作业**：
      - 保活循环在还剩 TAIL_RESERVE 分钟时，用 -Background 拉起本脚本后立刻返回；
      - 收尾在后台跑，主循环继续 sleep 到 job 硬上限前几分钟；
      - 于是 RDP 全程可用，收尾也不再占用「可用窗口」。

    执行顺序（任一步失败不中断后续，也不返回非 0）：
      1. disk-guard.ps1  -Enforce   清 C 盘超限增量
      2. sync-up.ps1                 用户数据全量同步到 139
      3. backup-snapshot.ps1 -Push   抓整机快照并推送（全量模式）

.PARAMETER Background
    用 Start-Process 拉起自身后立刻返回（供保活循环调用）。

.OUTPUTS
    状态：<LogDir>\finalize-status.json  { state, phase, startedUtc, updatedUtc, exitCode, error }
    完成标记：<LogDir>\finalize-done.flag（存在即代表收尾跑完，无论成功失败）
    日志：<LogDir>\finalize.log

.NOTES
    本脚本永不返回非 0 —— 收尾失败不该让整个 job 标红（那样会掩盖保活本身的成功）。
#>
[CmdletBinding()]
param(
    [string]$Stage      = $(if ($env:CLOUDRDP_SNAPSHOT_STAGE) { $env:CLOUDRDP_SNAPSHOT_STAGE } elseif (Test-Path 'D:\') { "D:\cloudrdp-sys\_snapshot" } else { "C:\_snapshot" }),
    [string]$ScriptsDir = "",
    [string]$LogDir     = "",
    [switch]$Background
)

$ErrorActionPreference = "Continue"

if ([string]::IsNullOrWhiteSpace($ScriptsDir)) { $ScriptsDir = $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($LogDir))     { $LogDir     = Join-Path $Stage "_logs" }

$LogFile    = Join-Path $LogDir "finalize.log"
$StatusFile = Join-Path $LogDir "finalize-status.json"
$DoneFlag   = Join-Path $LogDir "finalize-done.flag"

# ---------------------------------------------------------------- 工具函数
function Say([string]$m)  { Write-Host "[finalize] $m" }
function Warn([string]$m) { Write-Warning "[finalize] $m" }
function Log([string]$m) {
    try {
        New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
        $line = "[{0}] {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $m
        $line | Out-File -LiteralPath $LogFile -Append -Encoding utf8
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

# ---------------------------------------------------------------- 后台拉起
if ($Background) {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    if (Test-Path -LiteralPath $DoneFlag) { Remove-Item -LiteralPath $DoneFlag -Force -ErrorAction SilentlyContinue }

    Write-Status ([ordered]@{
        state      = 'starting'
        phase      = ''
        startedUtc = (Get-Date).ToUniversalTime().ToString('o')
        updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        exitCode   = 0
        error      = ''
    })
    Log "===== 后台收尾启动 ====="

    $exe = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $exe) { $exe = (Get-Command powershell.exe -ErrorAction Stop).Source }
    $argStr = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Stage "{1}" -ScriptsDir "{2}" -LogDir "{3}"' -f `
        $PSCommandPath, $Stage, $ScriptsDir, $LogDir

    Start-Process -FilePath $exe -ArgumentList $argStr -WindowStyle Hidden | Out-Null

    Say "已在后台启动收尾（C 盘清理 → 全量同步 → 整机快照），远程连接保持可用"
    Say "日志: $LogFile"
    Set-GhEnv "FINALIZE_STATE=后台收尾中"
    exit 0
}

# ---------------------------------------------------------------- 前台执行（真正的收尾）
$exitCode = 0
$errMsg   = ''
$started  = (Get-Date).ToUniversalTime()

Write-Status ([ordered]@{
    state      = 'running'
    phase      = 'disk-guard'
    startedUtc = $started.ToString('o')
    updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    exitCode   = 0
    error      = ''
})
Log "===== 开始收尾 ====="

# --- 阶段 1：C 盘守卫 -------------------------------------------------------
try {
    $p1 = Join-Path $ScriptsDir 'disk-guard.ps1'
    if (Test-Path -LiteralPath $p1) {
        Log "[1/3] disk-guard -Enforce"
        & $p1 -Enforce 2>&1 | Out-File -LiteralPath $LogFile -Append -Encoding utf8
        Log "[1/3] done (exit=$LASTEXITCODE)"
    } else {
        Log "[1/3] 跳过：未找到 $p1"
    }
} catch {
    $errMsg = "disk-guard: " + $_.Exception.Message
    Log "[1/3] 异常: $errMsg"
}

# --- 阶段 2：用户数据全量同步 -----------------------------------------------
Write-Status ([ordered]@{
    state = 'running'; phase = 'sync-up'; startedUtc = $started.ToString('o')
    updatedUtc = (Get-Date).ToUniversalTime().ToString('o'); exitCode = 0; error = $errMsg
})
try {
    $p2 = Join-Path $ScriptsDir 'sync-up.ps1'
    if (Test-Path -LiteralPath $p2) {
        Log "[2/3] sync-up"
        & $p2 2>&1 | Out-File -LiteralPath $LogFile -Append -Encoding utf8
        Log "[2/3] done (exit=$LASTEXITCODE)"
    } else {
        Log "[2/3] 跳过：未找到 $p2"
    }
} catch {
    if ($errMsg) { $errMsg += " | " }
    $errMsg += "sync-up: " + $_.Exception.Message
    Log "[2/3] 异常: $($_.Exception.Message)"
}

# --- 阶段 3：整机快照（全量 + 推送）------------------------------------------
Write-Status ([ordered]@{
    state = 'running'; phase = 'snapshot'; startedUtc = $started.ToString('o')
    updatedUtc = (Get-Date).ToUniversalTime().ToString('o'); exitCode = 0; error = $errMsg
})
try {
    $p3 = Join-Path $ScriptsDir 'backup-snapshot.ps1'
    if (Test-Path -LiteralPath $p3) {
        Log "[3/3] backup-snapshot -Push（全量）"
        & $p3 -Push 2>&1 | Out-File -LiteralPath $LogFile -Append -Encoding utf8
        Log "[3/3] done (exit=$LASTEXITCODE)"
    } else {
        Log "[3/3] 跳过：未找到 $p3"
    }
} catch {
    if ($errMsg) { $errMsg += " | " }
    $errMsg += "snapshot: " + $_.Exception.Message
    Log "[3/3] 异常: $($_.Exception.Message)"
}

# --- 收尾标记 ---------------------------------------------------------------
$state = if ($errMsg) { 'done-with-errors' } else { 'done' }
Write-Status ([ordered]@{
    state      = $state
    phase      = 'finished'
    startedUtc = $started.ToString('o')
    updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    exitCode   = $exitCode
    error      = $errMsg
})
try { "finished $((Get-Date).ToUniversalTime().ToString('o'))" | Out-File -LiteralPath $DoneFlag -Encoding ascii } catch { }

$spent = [int][math]::Round(((Get-Date).ToUniversalTime() - $started).TotalMinutes, 1)
Log "===== 收尾结束（state=$state，耗时 $spent 分钟）====="
Say "收尾结束（state=$state，耗时 $spent 分钟）"
Set-GhEnv "FINALIZE_STATE=$state"
exit 0
