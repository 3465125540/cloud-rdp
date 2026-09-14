<#
.SYNOPSIS
  按快照里的软件清单，用 winget **逐包**重装。支持后台异步执行，不阻塞 RDP 连接。

.DESCRIPTION
  为什么逐包而不是 `winget import`：
    · 402 个包用 import 一旦中途失败会整体中断；逐包可以失败隔离，进度也更细。
    · 每个包独立 try/catch，失败只记录、不中断。

  为什么后台：
    · 全部装完可能几十分钟。若同步执行，会卡住后面的「打印连接信息」步骤，
      你会连不上机器。`-Background` 用 Start-Process 拉起自身后立刻返回。

  输入清单：<Stage>\apps\winget-export.json（由 backup-snapshot.ps1 抓取）
  日志：<LogDir>\apps-reinstall.log
  状态：<LogDir>\apps-status.json（{ state, total, done, failed, startedUtc, updatedUtc }）

.NOTES
  本脚本永不返回非 0。开关：snapshot-config.json 的 restore.installApps、
  restore.maxPackages，以及 workflow_dispatch 输入 install_apps。
#>
[CmdletBinding()]
param(
    [string]$Stage      = $(if ($env:CLOUDRDP_SNAPSHOT_STAGE) { $env:CLOUDRDP_SNAPSHOT_STAGE } elseif (Test-Path 'D:\') { "D:\cloudrdp-sys\_snapshot" } else { "C:\_snapshot" }),
    [string]$ConfigPath = (Join-Path $PSScriptRoot "snapshot-config.json"),
    [string]$LogDir     = "",
    [int]   $MaxPackages = 0,          # 0 = 不限
    [switch]$Background
)

$ErrorActionPreference = "Continue"
if ([string]::IsNullOrWhiteSpace($LogDir)) { $LogDir = Join-Path $Stage "_logs" }
$LogFile    = Join-Path $LogDir "apps-reinstall.log"
$StatusFile = Join-Path $LogDir "apps-status.json"

function Set-GhEnv([string]$kv) {
    if ($env:GITHUB_ENV) { $kv | Out-File $env:GITHUB_ENV -Append -Encoding ascii }
}
function Say([string]$m)  { Write-Host "[apps] $m" }
function Warn([string]$m) { Write-Warning "[apps] $m" }
function Log([string]$m) {
    $line = "[{0}] {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $m
    $line | Out-File -LiteralPath $LogFile -Append -Encoding utf8
}
function Write-Status($obj) {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $obj | ConvertTo-Json -Depth 4 | Out-File -LiteralPath $StatusFile -Encoding UTF8
}
function Get-Cfg($obj, $name, $fallback) {
    if ($null -eq $obj) { return $fallback }
    if ($obj -is [System.Collections.IDictionary]) {
        if ($obj.Contains($name) -and $null -ne $obj[$name]) { return $obj[$name] }
        return $fallback
    }
    $p = $obj.PSObject.Properties[$name]
    if ($null -eq $p -or $null -eq $p.Value) { return $fallback }
    return $p.Value
}

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# ---------------------------------------------------------------- 开关判定
$cfg = $null
if (Test-Path -LiteralPath $ConfigPath) {
    try { $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
}
$cfgInstall = [bool](Get-Cfg (Get-Cfg $cfg 'restore' $null) 'installApps' $true)
$cfgMax     = [int](Get-Cfg (Get-Cfg $cfg 'restore' $null) 'maxPackages' 0)

$envFlag = $env:INPUT_INSTALL_APPS
$enabled = $cfgInstall
if (-not [string]::IsNullOrWhiteSpace($envFlag)) { $enabled = ($envFlag -eq 'true') }

if (-not $enabled) {
    Say "软件重装已关闭（restore.installApps=$cfgInstall / install_apps=$envFlag），跳过"
    Set-GhEnv "APPS_REINSTALL_STATE=已关闭"
    Write-Status ([ordered]@{ state = 'disabled'; total = 0; done = 0; failed = 0; updatedUtc = (Get-Date).ToUniversalTime().ToString('o') })
    exit 0
}

if ($MaxPackages -le 0) { $MaxPackages = $cfgMax }

# ---------------------------------------------------------------- 读清单
$exportPath = Join-Path $Stage "apps\winget-export.json"
if (-not (Test-Path -LiteralPath $exportPath)) {
    Say "未找到软件清单 $exportPath —— 首次运行正常，跳过"
    Set-GhEnv "APPS_REINSTALL_STATE=无清单（首次运行）"
    Write-Status ([ordered]@{ state = 'no-manifest'; total = 0; done = 0; failed = 0; updatedUtc = (Get-Date).ToUniversalTime().ToString('o') })
    exit 0
}

$ids = New-Object System.Collections.Generic.List[string]
try {
    $export = Get-Content -LiteralPath $exportPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($src in @($export.Sources)) {
        foreach ($p in @($src.Packages)) {
            $id = [string]$p.PackageIdentifier
            if (-not [string]::IsNullOrWhiteSpace($id) -and -not $ids.Contains($id)) { $ids.Add($id) }
        }
    }
} catch {
    Warn "清单解析失败：$_"
    Set-GhEnv "APPS_REINSTALL_STATE=清单解析失败"
    exit 0
}

if ($MaxPackages -gt 0 -and $ids.Count -gt $MaxPackages) {
    Say "清单 $($ids.Count) 个包，按上限截取前 $MaxPackages 个"
    $ids = $ids.GetRange(0, $MaxPackages)
}

if ($ids.Count -eq 0) {
    Say "清单为空，跳过"
    Set-GhEnv "APPS_REINSTALL_STATE=清单为空"
    exit 0
}

$winget = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source
if (-not $winget) {
    Warn "本机没有 winget，无法自动重装（清单见 $exportPath）"
    Set-GhEnv "APPS_REINSTALL_STATE=无 winget"
    exit 0
}

# ---------------------------------------------------------------- 后台模式：拉起自身后立刻返回
if ($Background) {
    $exe = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $exe) { $exe = (Get-Command powershell.exe -ErrorAction Stop).Source }
    $argStr = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Stage "{1}" -LogDir "{2}" -MaxPackages {3}' -f $PSCommandPath, $Stage, $LogDir, $MaxPackages

    Write-Status ([ordered]@{
        state = 'starting'; total = $ids.Count; done = 0; failed = 0
        startedUtc = (Get-Date).ToUniversalTime().ToString('o')
        updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    })
    Log "后台重装启动，共 $($ids.Count) 个包"

    Start-Process -FilePath $exe -ArgumentList $argStr -WindowStyle Hidden | Out-Null
    Say "已在后台启动重装（$($ids.Count) 个包，不阻塞连接）"
    Say "日志: $LogFile"
    Set-GhEnv "APPS_REINSTALL_STATE=后台重装中（$($ids.Count) 个包）"
    exit 0
}

# ---------------------------------------------------------------- 前台执行（真正的安装循环）
$started = (Get-Date).ToUniversalTime().ToString('o')
$done = 0; $failed = 0
$failedIds = New-Object System.Collections.Generic.List[string]

Log "===== 开始重装 $($ids.Count) 个包 ====="

$i = 0
foreach ($id in $ids) {
    $i++
    Log "[$i/$($ids.Count)] winget install --id $id"
    try {
        & $winget install --id $id -e --silent --disable-interactivity `
            --accept-package-agreements --accept-source-agreements 2>&1 |
            Out-File -LiteralPath $LogFile -Append -Encoding utf8
        if ($LASTEXITCODE -eq 0) {
            $done++
        } else {
            $failed++
            $failedIds.Add($id)
            Log "  -> 失败（退出码 $LASTEXITCODE）"
        }
    } catch {
        $failed++
        $failedIds.Add($id)
        Log "  -> 异常：$_"
    }

    $failedArr = [object[]]$failedIds
    Write-Status ([ordered]@{
        state      = 'running'
        total      = $ids.Count
        done       = $done
        failed     = $failed
        failedIds  = $failedArr
        startedUtc = $started
        updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    })
}

$state = if ($failed -eq 0) { 'completed' } else { 'completed-with-failures' }
$failedArr = [object[]]$failedIds
Write-Status ([ordered]@{
    state      = $state
    total      = $ids.Count
    done       = $done
    failed     = $failed
    failedIds  = $failedArr
    startedUtc = $started
    updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
})
Log "===== 结束：成功 $done / 失败 $failed / 共 $($ids.Count) ====="

exit 0
