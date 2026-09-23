<#
.SYNOPSIS
  重装软件 + 保证 Edge / WorkBuddy 用户数据完整。支持后台异步执行，不阻塞 RDP 连接。

.DESCRIPTION
  这一步做两件事（同一个后台任务里顺序执行）：

    A. 重装软件 —— 按 <Stage>\apps\winget-export.json 逐包 winget install。
       为什么逐包而不是 `winget import`：402 个包用 import 一旦中途失败会整体中断；
       逐包可以失败隔离，进度也更细。每个包独立 try/catch，失败只记录、不中断。

    B. 用户数据完整性 —— 对 Edge（浏览记录 / 本地保存的密码 / 全部设置）与 WorkBuddy
       （用户数据 / 缓存 / 安装目录）逐目标校验；缺失或不完整就从快照「只补不删」补写。
       为什么放在这里：第 8 步的全量还原对「到底漏没漏」是弱感知（日志只有一句
       「个人文件预还原：N 个目录」）；而重装软件本身也可能覆盖程序目录。收尾再
       校验一次并补漏，才算对「完整恢复」负责。真机踩过的坑：清单里写的是
       .workbuddy-ai，而这台机器上根本不存在该目录 → WorkBuddy 数据一直静默零还原。

  为什么后台：全部装完可能几十分钟。若同步执行，会卡住后面的「打印连接信息」步骤，
  你会连不上机器。`-Background` 用 Start-Process 拉起自身后立刻返回。

  输入清单：<Stage>\apps\winget-export.json（由 backup-snapshot.ps1 抓取）
  日志：<LogDir>\apps-reinstall.log
  状态：<LogDir>\apps-status.json
        { state, total, done, failed, failedIds, startedUtc, updatedUtc,
          apps: {...}, userData: { state, detail, edge, wb, repaired, failed, targets } }

.NOTES
  本脚本永不返回非 0。开关：snapshot-config.json 的 restore.installApps /
  restore.maxPackages / restore.userData，以及 workflow_dispatch 输入 install_apps。
#>
[CmdletBinding()]
param(
    [string]$Stage      = $(if ($env:CLOUDRDP_SNAPSHOT_STAGE) { $env:CLOUDRDP_SNAPSHOT_STAGE } elseif (Test-Path 'D:\') { "D:\cloudrdp-sys\_snapshot" } else { "C:\_snapshot" }),
    [string]$ConfigPath = (Join-Path $PSScriptRoot "snapshot-config.json"),
    [string]$LogDir     = "",
    [int]   $MaxPackages = 0,          # 0 = 不限
    [switch]$Background,
    [switch]$SkipUserData              # 只重装软件，不做 Edge/WorkBuddy 校验补漏
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
    $obj | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $StatusFile -Encoding UTF8
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

# ---------------------------------------------------------------- 共享库
# 先加载库，再定义本地同名函数，保证本脚本的 Say/Warn/Log/Get-Cfg 最终生效。
$uninstallLib = Join-Path $PSScriptRoot "uninstall-apps-lib.ps1"
$script:HasBlockedLib = $false
if (Test-Path -LiteralPath $uninstallLib) { . $uninstallLib; $script:HasBlockedLib = $true }
else { Warn "未找到 uninstall-apps-lib.ps1，无法按 blockedApps 过滤重装清单" }

# 用户数据完整性（Edge / WorkBuddy 校验 + 补漏）—— 与 restore-snapshot.ps1 共用同一套口径
$userDataLib = Join-Path $PSScriptRoot "userdata-lib.ps1"
$script:HasUserDataLib = $false
if (Test-Path -LiteralPath $userDataLib) { . $userDataLib; $script:HasUserDataLib = $true }
else { Warn "未找到 userdata-lib.ps1，跳过 Edge/WorkBuddy 用户数据校验" }

# 补漏要覆盖 Edge 的 Login Data / WorkBuddy 的 SQLite —— 先优雅关掉占用程序；
# 万一还有锁死的文件，用共享读写补写兜底。
$quiesceLib = Join-Path $PSScriptRoot "app-quiesce-lib.ps1"
if (Test-Path -LiteralPath $quiesceLib) { . $quiesceLib }
$lockCopyLib = Join-Path $PSScriptRoot "lockcopy-lib.ps1"
if (Test-Path -LiteralPath $lockCopyLib) { . $lockCopyLib }

# ---------------------------------------------------------------- 开关判定
$cfg = $null
if (Test-Path -LiteralPath $ConfigPath) {
    try { $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
}
$cfgRestore = Get-Cfg $cfg 'restore' $null
$cfgInstall = [bool](Get-Cfg $cfgRestore 'installApps' $true)
$cfgMax     = [int](Get-Cfg $cfgRestore 'maxPackages' 0)
$cfgUserData= [bool](Get-Cfg $cfgRestore 'userData' $true)

$envFlag = $env:INPUT_INSTALL_APPS
$enabled = $cfgInstall
if (-not [string]::IsNullOrWhiteSpace($envFlag)) { $enabled = ($envFlag -eq 'true') }

if ($MaxPackages -le 0) { $MaxPackages = $cfgMax }

$needUserData = ($cfgUserData -and -not $SkipUserData)

# 还原目标用户（补漏要写到 C:\Users\<user>\...；以快照记录的用户名为准，其次环境变量）
$rdpUser = if ($env:RDP_USERNAME) { [string]$env:RDP_USERNAME } else { 'a' }
try {
    $mfPath = Join-Path $Stage "manifest.json"
    if (Test-Path -LiteralPath $mfPath) {
        $mf = Get-Content -LiteralPath $mfPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($mf.rdpUser) { $rdpUser = [string]$mf.rdpUser }
    }
} catch { }

# ---------------------------------------------------------------- A. 收集重装清单
$ids = New-Object System.Collections.Generic.List[string]
$appsState = 'disabled'
$appsReady = $false
$winget    = $null

if (-not $enabled) {
    Say "软件重装已关闭（restore.installApps=$cfgInstall / install_apps=$envFlag），跳过重装"
    Log "软件重装：跳过（已关闭）"
    Set-GhEnv "APPS_REINSTALL_STATE=已关闭"
} else {
    $exportPath = Join-Path $Stage "apps\winget-export.json"
    if (-not (Test-Path -LiteralPath $exportPath)) {
        $appsState = 'no-manifest'
        Say "未找到软件清单 $exportPath —— 首次运行正常，跳过"
        Log "软件重装：跳过（无清单，首次运行）"
        Set-GhEnv "APPS_REINSTALL_STATE=无清单（首次运行）"
    } else {
        $appsState = 'empty'
        try {
            $export = Get-Content -LiteralPath $exportPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $blocked = @()
            if ($script:HasBlockedLib) { $blocked = @(Get-BlockedAppEntries -ConfigPath $ConfigPath) }
            $skippedBlocked = New-Object System.Collections.Generic.List[string]
            foreach ($src in @($export.Sources)) {
                foreach ($p in @($src.Packages)) {
                    $id = [string]$p.PackageIdentifier
                    if ([string]::IsNullOrWhiteSpace($id)) { continue }
                    # blockedApps 里的包永不重装（瘦身时已卸载，装回来等于白干）
                    if ($blocked.Count -gt 0 -and
                        (Test-BlockedAppPackage -PackageIdentifier $id -PackageName ([string]$p.PackageName) -Entries $blocked)) {
                        if (-not $skippedBlocked.Contains($id)) { $skippedBlocked.Add($id) }
                        continue
                    }
                    if (-not $ids.Contains($id)) { $ids.Add($id) }
                }
            }
            if ($skippedBlocked.Count -gt 0) {
                $skipTxt = ($skippedBlocked -join ', ')
                Say ("按 blockedApps 跳过 {0} 个包：{1}" -f $skippedBlocked.Count, $skipTxt)
                Log ("blockedApps 跳过：" + $skipTxt)
            }
            if ($MaxPackages -gt 0 -and $ids.Count -gt $MaxPackages) {
                Say "清单 $($ids.Count) 个包，按上限截取前 $MaxPackages 个"
                $ids = $ids.GetRange(0, $MaxPackages)
            }
            if ($ids.Count -gt 0) {
                $winget = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source
                if (-not $winget) {
                    $appsState = 'no-winget'
                    Warn "本机没有 winget，无法自动重装（清单见 $exportPath）"
                    Log "软件重装：跳过（本机无 winget）"
                    Set-GhEnv "APPS_REINSTALL_STATE=无 winget"
                } else {
                    $appsState = 'pending'
                    $appsReady = $true
                }
            } else {
                Say "清单为空，跳过重装"
                Log "软件重装：跳过（清单为空）"
                Set-GhEnv "APPS_REINSTALL_STATE=清单为空"
            }
        } catch {
            $appsState = 'parse-failed'
            Warn "清单解析失败：$_"
            Log "软件重装：清单解析失败（$_）"
            Set-GhEnv "APPS_REINSTALL_STATE=清单解析失败"
        }
    }
}

$hasWork = ($appsReady -and $ids.Count -gt 0) -or $needUserData

# ---------------------------------------------------------------- 后台模式：拉起自身后立刻返回
if ($Background) {
    if (-not $hasWork) {
        Write-Status ([ordered]@{
            state = $appsState; total = 0; done = 0; failed = 0
            startedUtc = (Get-Date).ToUniversalTime().ToString('o')
            updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
            apps = [ordered]@{ state = $appsState; total = 0; done = 0; failed = 0 }
            userData = $null
        })
        Say "无后台任务（apps=$appsState / userData=$needUserData）"
        exit 0
    }

    $exe = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $exe) { $exe = (Get-Command powershell.exe -ErrorAction Stop).Source }
    $argStr = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Stage "{1}" -LogDir "{2}" -MaxPackages {3}' -f $PSCommandPath, $Stage, $LogDir, $MaxPackages
    if ($SkipUserData) { $argStr += ' -SkipUserData' }

    Write-Status ([ordered]@{
        state = 'starting'; total = $ids.Count; done = 0; failed = 0
        startedUtc = (Get-Date).ToUniversalTime().ToString('o')
        updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        apps = [ordered]@{ state = $appsState; total = $ids.Count; done = 0; failed = 0 }
        userData = $(if ($needUserData) { [ordered]@{ state = 'pending' } } else { $null })
    })
    Log ("后台任务启动：重装 {0} 个包 / 用户数据校验={1}" -f $ids.Count, $needUserData)

    Start-Process -FilePath $exe -ArgumentList $argStr -WindowStyle Hidden | Out-Null
    if ($ids.Count -gt 0) {
        Say "已在后台启动重装（$($ids.Count) 个包，不阻塞连接）"
        Set-GhEnv "APPS_REINSTALL_STATE=后台重装中（$($ids.Count) 个包）"
    } else {
        Say "已在后台启动（无待装包，仅做用户数据校验）"
        Set-GhEnv "APPS_REINSTALL_STATE=无待装包"
    }
    if ($needUserData) { Say "后台同时会校验/补漏 Edge 与 WorkBuddy 用户数据" }
    Say "日志: $LogFile"
    exit 0
}

# ---------------------------------------------------------------- 前台执行 A：真正的安装循环
$started = (Get-Date).ToUniversalTime().ToString('o')
$done = 0; $failed = 0
$failedIds = New-Object System.Collections.Generic.List[string]

if ($appsReady -and $ids.Count -gt 0) {
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
            apps       = [ordered]@{ state = 'running'; total = $ids.Count; done = $done; failed = $failed }
            userData   = $(if ($needUserData) { [ordered]@{ state = 'pending' } } else { $null })
        })
    }
    $appsState = if ($failed -eq 0) { 'completed' } else { 'completed-with-failures' }
    Log "===== 重装结束：成功 $done / 失败 $failed / 共 $($ids.Count) ====="
}

# ---------------------------------------------------------------- 前台执行 B：用户数据完整性
$udState = 'skipped'
$udObj   = $null
if ($SkipUserData) {
    Say "用户数据校验：跳过（-SkipUserData）"
    Log  "===== 用户数据校验：跳过（-SkipUserData） ====="
} elseif (-not $cfgUserData) {
    Say "用户数据校验：跳过（restore.userData=false）"
    Log  "===== 用户数据校验：跳过（restore.userData=false） ====="
} elseif (-not $script:HasUserDataLib) {
    $udState = 'no-lib'
    Warn "用户数据校验：跳过（未找到 userdata-lib.ps1）"
} else {
    Log "===== 用户数据完整性（Edge 浏览记录/已存密码/设置 + WorkBuddy 数据/缓存/安装目录） ====="
    try {
        $ud = Invoke-UserDataVerifyAndRepair -Stage $Stage -RdpUser $rdpUser -ConfigPath $ConfigPath `
                -Log { param($m) Log ("  " + $m); Say $m } -Quiesce -EvidenceLogPath $LogFile
        $udState = [string]$ud.state
        $udObj = [ordered]@{
            state    = $ud.state
            detail   = $ud.detail
            edge     = $ud.edge
            wb       = $ud.wb
            repaired = $ud.repaired
            failed   = $ud.failed
            skipped  = $ud.skipped
            quiesce  = $ud.quiesce
            targets  = @($ud.after)
        }
        Say ("用户数据：{0} —— {1}" -f $ud.state, $ud.detail)
        Log ("用户数据：{0} —— {1}" -f $ud.state, $ud.detail)
        if ($ud.state -ne 'OK') {
            Warn ("用户数据未完全到位（{0}）：详见日志 {1}" -f $ud.state, $LogFile)
        }
    } catch {
        $udState = 'error'
        Warn "用户数据校验异常：$_"
        Log  "用户数据校验异常：$_"
    }
}

# ---------------------------------------------------------------- 最终状态
$state = $appsState
if (-not $appsReady -and $udState -notin @('skipped', 'no-lib')) { $state = 'userdata-only' }

$failedArr = [object[]]$failedIds
Write-Status ([ordered]@{
    state      = $state
    total      = $ids.Count
    done       = $done
    failed     = $failed
    failedIds  = $failedArr
    startedUtc = $started
    updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    apps       = [ordered]@{ state = $appsState; total = $ids.Count; done = $done; failed = $failed }
    userData   = $udObj
})

exit 0
