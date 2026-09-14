<#
.SYNOPSIS
  预还原：把关机前的完整状态**校验清楚、准备就绪**，然后驱动全量还原。

.DESCRIPTION
  在正式还原之前跑的一步，职责（顺序执行）：
    1. 拉取   —— 从 139 把快照拉到 <Stage>（原 restore-snapshot.ps1 的 -Pull 前移到这里）
    2. 校验   —— manifest 存在/可解析/版本兼容、各 files/<mirror> 齐全、winget 清单可解析
                 → 输出 SNAPSHOT_PREVALIDATE=OK|PARTIAL|EMPTY|FAILED
    3. 规划   —— 生成 <Stage>\restore-plan.json（每条：类型 / 原路径 / 存储路径 / 作用域）并打印摘要
    4. 准备   —— 建好数据目录、可移动程序暂存目录、各还原目标的父目录
    5. 回滚   —— 把即将被覆盖的注册表键导出到 <Stage>\_rollback\<ts>\，并写 rollback.json
    6. 钩子   —— 执行 snapshot-config.json 里 restore.preCommands[] 的自定义命令（fail-soft）
    7. 驱动   —— 调用 restore-snapshot.ps1 -Scope machine 完成真正的机器级还原

.PARAMETER SkipRestore  只做 1~6，不驱动还原（便于本地测试 / 只想校验）
.PARAMETER DryRun       不落任何实际改动（第 4/5/6/7 步跳过）

.NOTES
  本脚本永不返回非 0。结果透出：SNAPSHOT_PREVALIDATE / SNAPSHOT_PLAN_COUNT / SNAPSHOT_ROLLBACK_DIR
#>
[CmdletBinding()]
param(
    [string]$Stage      = $(if ($env:CLOUDRDP_SNAPSHOT_STAGE) { $env:CLOUDRDP_SNAPSHOT_STAGE } elseif (Test-Path 'D:\') { "D:\cloudrdp-sys\_snapshot" } else { "C:\_snapshot" }),
    [string]$Remote     = $(if ($env:CLOUDRDP_REMOTE_BASE) { $env:CLOUDRDP_REMOTE_BASE + "/_snapshot" } else { "alist:/cloudrdp/AI文件库/_snapshot" }),
    [string]$ConfigPath = (Join-Path $PSScriptRoot "snapshot-config.json"),
    [string]$RdpUser    = $(if ($env:RDP_USERNAME) { $env:RDP_USERNAME } else { "NvdAdmin" }),
    [string]$DataDir    = $(if ($env:CLOUDRDP_DATA_DIR) { $env:CLOUDRDP_DATA_DIR } else { "D:\a\cloud-rdp" }),
    [string]$PortableDir= $(if ($env:CLOUDRDP_PORTABLE_DIR) { $env:CLOUDRDP_PORTABLE_DIR } else { "D:\a\cloud-rdp\_portable" }),
    [switch]$Pull,
    [switch]$SkipRestore,
    [switch]$DryRun
)

$ErrorActionPreference = "Continue"
$SysDir    = if ($env:CLOUDRDP_SYS_DIR) { $env:CLOUDRDP_SYS_DIR } elseif (Test-Path 'D:\') { "D:\cloudrdp-sys" } else { "C:\cloudrdp-sys" }
$RcloneExe = Join-Path $SysDir "rclone\rclone.exe"

# 安装型程序共享库（用于记录「镜像自带程序」基线，供关机时做增量判定）
$programsLib = Join-Path $PSScriptRoot "programs-lib.ps1"
if (Test-Path -LiteralPath $programsLib) { . $programsLib }
else { Write-Warning "[pre-restore] 未找到 programs-lib.ps1，将无法记录程序基线" }

function Set-GhEnv([string]$kv) {
    if ($env:GITHUB_ENV) { $kv | Out-File $env:GITHUB_ENV -Append -Encoding ascii }
}
function Say([string]$m)  { Write-Host "[pre-restore] $m" }
function Warn([string]$m) { Write-Warning "[pre-restore] $m" }
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

# ---------------------------------------------------------------- 配置
$cfg = $null
if (Test-Path -LiteralPath $ConfigPath) {
    try { $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Warn "配置解析失败：$_" }
}
$restoreCfg  = Get-Cfg $cfg 'restore' $null
$preCommands = @(Get-Cfg $restoreCfg 'preCommands' @())
$preCfg      = Get-Cfg $restoreCfg 'preRestore' $null
$doPrepare   = [bool](Get-Cfg $preCfg 'prepareDirs' $true)
$doRollback  = [bool](Get-Cfg $preCfg 'recordRollback' $true)

Say "===== 预还原开始（Stage=$Stage）====="

# ---------------------------------------------------------------- 0. 记录「镜像自带程序」基线
# 必须在任何还原动作之前执行：基线里的程序一律不备份，
# 否则镜像自带的约 120GB 工具链（VS / Android SDK / 缓存）会被传上云盘。
$stateDir = Join-Path $SysDir "_state"
try { New-Item -ItemType Directory -Force -Path $stateDir | Out-Null } catch { }
try {
    if (Get-Command Get-InstalledPrograms -ErrorAction SilentlyContinue) {
        $allApps = @(Get-InstalledPrograms)
        $regs = [object[]]($allApps | ForEach-Object { $_.regPath } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        ([pscustomobject]@{
            recordedUtc = (Get-Date).ToUniversalTime().ToString('o')
            count       = $regs.Count
            regPaths    = $regs
        } | ConvertTo-Json -Depth 4) | Out-File -LiteralPath (Join-Path $stateDir "program-baseline.json") -Encoding UTF8
        Say ("镜像程序基线已记录：{0} 项 -> program-baseline.json" -f $regs.Count)
    } else {
        Warn "未加载 programs-lib.ps1，跳过程序基线记录（本次将不做安装型程序备份）"
    }
} catch { Warn "记录程序基线失败：$_" }

# ---------------------------------------------------------------- 1. 拉取
if ($Pull) {
    if (-not (Test-Path -LiteralPath $RcloneExe)) {
        Warn "未找到 rclone，无法拉取快照"
        Set-GhEnv "SNAPSHOT_PREVALIDATE=FAILED"
        exit 0
    }
    New-Item -ItemType Directory -Force -Path $Stage | Out-Null
    Say "拉取快照: $Remote  ->  $Stage"
    $code = 0
    for ($i = 1; $i -le 3; $i++) {
        & $RcloneExe copy $Remote $Stage `
            --update --transfers 4 --checkers 8 `
            --timeout 0 --contimeout 0 `
            --retries 3 --low-level-retries 5 `
            --stats-one-line -v
        $code = $LASTEXITCODE
        if ($code -eq 0) { break }
        if ($code -eq 3 -or $code -eq 4) { break }
        if ($i -lt 3) { Warn "第 $i/3 次拉取失败（码 $code），8 秒后重试"; Start-Sleep -Seconds 8 }
    }
    if ($code -eq 3 -or $code -eq 4) {
        Say "远端尚无快照（首次运行正常）"
        Set-GhEnv "SNAPSHOT_PREVALIDATE=EMPTY"
        Set-GhEnv "SNAPSHOT_STATUS=EMPTY"
        exit 0
    }
    if ($code -ne 0) {
        Warn "快照拉取失败（rclone 码 $code）"
        Set-GhEnv "SNAPSHOT_PREVALIDATE=FAILED"
        Set-GhEnv "SNAPSHOT_STATUS=FAILED"
        exit 0
    }
}

# ---------------------------------------------------------------- 2. 校验
$manifestPath = Join-Path $Stage "manifest.json"
if (-not (Test-Path -LiteralPath $manifestPath)) {
    Say "未发现 manifest.json —— 视为首次运行，无历史快照可还原"
    Set-GhEnv "SNAPSHOT_PREVALIDATE=EMPTY"
    Set-GhEnv "SNAPSHOT_STATUS=EMPTY"
    exit 0
}

$mf = $null
try { $mf = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json }
catch {
    Warn "manifest.json 解析失败：$_"
    Set-GhEnv "SNAPSHOT_PREVALIDATE=FAILED"
    Set-GhEnv "SNAPSHOT_STATUS=FAILED"
    exit 0
}

if ($mf.rdpUser) { $RdpUser = $mf.rdpUser }

# 记录「上次备份过的程序」-> 关机时继续带上（跨运行持久：镜像里没有它们，但必须留住）
try {
    $prevRegs = @()
    if ($mf.apps -and $mf.apps.programs) {
        foreach ($pg in @($mf.apps.programs)) {
            if ($pg.regPath) { $prevRegs += [string]$pg.regPath }
        }
    }
    $prevArr = [object[]]$prevRegs
    ([pscustomobject]@{
        recordedUtc = (Get-Date).ToUniversalTime().ToString('o')
        count       = $prevArr.Count
        regPaths    = $prevArr
    } | ConvertTo-Json -Depth 4) | Out-File -LiteralPath (Join-Path $stateDir "prev-programs.json") -Encoding UTF8
    Say ("上次备份过的程序：{0} 项（本次会继续带上）" -f $prevArr.Count)
} catch { Warn "记录历史程序清单失败：$_" }

$mfVersion = 1
if ($mf.version) { $mfVersion = [int]$mf.version }

$problems = New-Object System.Collections.Generic.List[string]

# 2a. 目录镜像是否齐全
foreach ($e in @($mf.files.entries)) {
    $rel = [string]$e.mirror
    if ([string]::IsNullOrWhiteSpace($rel)) { continue }
    $p = Join-Path (Join-Path $Stage "files") $rel
    if (-not (Test-Path -LiteralPath $p)) { $problems.Add("missing:$rel") }
}
# 2b. winget 清单可解析
$we = Join-Path $Stage "apps\winget-export.json"
if (Test-Path -LiteralPath $we) {
    try { Get-Content -LiteralPath $we -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null }
    catch { $problems.Add("bad-winget-export") }
}
# 2c. 便携程序清单可解析
$pm = Join-Path $Stage "apps\portable.json"
if (Test-Path -LiteralPath $pm) {
    try { Get-Content -LiteralPath $pm -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null }
    catch { $problems.Add("bad-portable-manifest") }
}
# 2d. 安装型程序清单可解析
$pgm = Join-Path $Stage "programs\programs.json"
if (Test-Path -LiteralPath $pgm) {
    try { Get-Content -LiteralPath $pgm -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null }
    catch { $problems.Add("bad-programs-manifest") }
}

$prevalidate = if ($problems.Count -eq 0) { "OK" } else { "PARTIAL" }
Say ("快照校验：{0}（{1} 个问题）| 快照时间 {2} | 主机 {3} | 文件 {4} 个" -f `
      $prevalidate, $problems.Count, $mf.createdLocal, $mf.hostname, $mf.files.totalFiles)
foreach ($p in $problems) { Warn "  校验问题: $p" }
Set-GhEnv ("SNAPSHOT_PREVALIDATE=" + $prevalidate)

# ---------------------------------------------------------------- 3. 规划
$userPrefix = ("C:\Users\" + $RdpUser)
$plan = New-Object System.Collections.Generic.List[object]

function Get-ScopeOf([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return 'machine' }
    if ($Path.ToLower().StartsWith($userPrefix.ToLower())) { return 'user' }
    return 'machine'
}

# 优先消费 manifest.plan（v2）；否则从 v1 字段推导（向后兼容）
if ($mf.plan) {
    foreach ($p in @($mf.plan)) { $plan.Add($p) }
} else {
    foreach ($e in @($mf.files.entries)) {
        $plan.Add([pscustomobject]@{
            type = 'dir'; originalPath = [string]$e.source
            store = ("files/" + [string]$e.mirror); scope = (Get-ScopeOf ([string]$e.source))
        })
    }
    foreach ($r in @($mf.registry)) {
        $rs = [string]$r
        $plan.Add([pscustomobject]@{
            type = 'registry'; originalPath = $rs; store = $rs
            scope = $(if ($rs -like 'registry/user/*') { 'user' } else { 'machine' })
        })
    }
    if ($mf.shortcuts -gt 0) {
        $plan.Add([pscustomobject]@{ type = 'shortcut'; originalPath = "$env:PUBLIC\Desktop"; store = 'shortcuts/public-desktop'; scope = 'machine' })
        $plan.Add([pscustomobject]@{ type = 'shortcut'; originalPath = "$userPrefix\Desktop"; store = 'shortcuts/user-desktop'; scope = 'user' })
    }
    if (Test-Path -LiteralPath (Join-Path $Stage 'system\system.json')) {
        $plan.Add([pscustomobject]@{ type = 'setting'; originalPath = ''; store = 'system/system.json'; scope = 'machine' })
    }
    if (Test-Path -LiteralPath $we) {
        $plan.Add([pscustomobject]@{ type = 'app'; originalPath = ''; store = 'apps/winget-export.json'; scope = 'background' })
    }
    if (Test-Path -LiteralPath $pm) {
        try {
            $pmObj = Get-Content -LiteralPath $pm -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($a in @($pmObj.apps)) {
                $plan.Add([pscustomobject]@{
                    type = 'portable'; originalPath = [string]$a.originalPath
                    store = [string]$a.storedPath; scope = (Get-ScopeOf ([string]$a.originalPath))
                })
            }
        } catch { }
    }
}

# 补充：plan 里没有 program 项但清单存在时补上（兼容旧 manifest）
$hasProgramPlan = $false
foreach ($pp in $plan) { if ([string]$pp.type -eq 'program') { $hasProgramPlan = $true; break } }
if (-not $hasProgramPlan -and (Test-Path -LiteralPath $pgm)) {
    try {
        $pgObj = Get-Content -LiteralPath $pgm -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($a in @($pgObj.programs)) {
            $plan.Add([pscustomobject]@{
                type = 'program'; originalPath = [string]$a.originalPath
                store = [string]$a.store; scope = (Get-ScopeOf ([string]$a.originalPath))
            })
        }
    } catch { }
}

$planPath = Join-Path $Stage "restore-plan.json"
if (-not $DryRun) {
    # 注意：本机 PS 5.1 下 @(<泛型List>) 会抛「参数类型不匹配」，必须用 [object[]] 转换
    $planItems = [object[]]$plan
    ([ordered]@{
        version     = 1
        generatedUtc= (Get-Date).ToUniversalTime().ToString('o')
        snapshot    = @{ createdLocal = $mf.createdLocal; hostname = $mf.hostname; manifestVersion = $mfVersion }
        count       = $planItems.Count
        items       = $planItems
    } | ConvertTo-Json -Depth 6) | Out-File -LiteralPath $planPath -Encoding UTF8
}
Say ("还原计划：{0} 项  ->  {1}" -f $plan.Count, $planPath)
$byType = $plan | Group-Object { $_.type } | ForEach-Object { "$($_.Name)=$($_.Count)" }
Say ("  构成: " + ($byType -join '  '))
Set-GhEnv ("SNAPSHOT_PLAN_COUNT=" + $plan.Count)

# ---------------------------------------------------------------- 4. 准备目录
if ($doPrepare -and -not $DryRun) {
    foreach ($d in @($DataDir, $PortableDir)) {
        try { New-Item -ItemType Directory -Force -Path $d | Out-Null; Say "  已准备目录: $d" }
        catch { Warn "  建目录失败 $d : $_" }
    }
    # 还原目标的父目录（尽力而为）
    foreach ($item in $plan) {
        $op = [string]$item.originalPath
        if ([string]::IsNullOrWhiteSpace($op)) { continue }
        if ($item.type -eq 'dir' -or $item.type -eq 'portable') {
            try { New-Item -ItemType Directory -Force -Path $op -ErrorAction SilentlyContinue | Out-Null } catch { }
        }
    }
}

# ---------------------------------------------------------------- 5. 回滚记录
if ($doRollback -and -not $DryRun) {
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $rbDir = Join-Path $Stage ("_rollback\" + $ts)
    New-Item -ItemType Directory -Force -Path (Join-Path $rbDir "registry") | Out-Null

    $targets = New-Object System.Collections.Generic.List[object]
    # 机器级注册表键（这些一定能导出）
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $Stage 'registry\machine') -Filter *.reg -File -ErrorAction SilentlyContinue)) {
        $name = $f.BaseName
        $key = switch -Wildcard ($name) {
            'HKLM-TimeZone' { 'HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' }
            'HKLM-Env'      { 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' }
            'HKLM-Language' { 'HKLM\SYSTEM\CurrentControlSet\Control\Nls\Language' }
            'HKLM-Locale'   { 'HKLM\SYSTEM\CurrentControlSet\Control\Nls\Locale' }
            default         { $null }
        }
        if (-not $key) { continue }
        $out = Join-Path $rbDir ("registry\" + $name + ".reg")
        & reg.exe export $key "$out" /y 2>&1 | Out-Null
        $targets.Add([pscustomobject]@{ type = 'registry'; path = $key; existed = (Test-Path -LiteralPath $out) })
    }
    # 文件目录：只记录现状（不整目录拷贝，避免爆盘）
    foreach ($item in $plan) {
        if ($item.type -ne 'dir' -and $item.type -ne 'portable') { continue }
        $op = [string]$item.originalPath
        if ([string]::IsNullOrWhiteSpace($op)) { continue }
        $exists = Test-Path -LiteralPath $op
        $files = 0; $bytes = [long]0
        if ($exists) {
            $items = @(Get-ChildItem -LiteralPath $op -Recurse -File -Force -ErrorAction SilentlyContinue)
            $files = $items.Count
            $s = ($items | Measure-Object -Property Length -Sum).Sum
            if ($s) { $bytes = [long]$s }
        }
        $targets.Add([pscustomobject]@{ type = $item.type; path = $op; existed = $exists; files = $files; bytes = $bytes })
    }

    $rbTargets = [object[]]$targets
    ([ordered]@{
        ts = $ts
        utc = (Get-Date).ToUniversalTime().ToString('o')
        note = '还原前记录的现状快照，供人工回滚参考（注册表键已导出到 registry/）'
        targets = $rbTargets
    } | ConvertTo-Json -Depth 6) | Out-File -LiteralPath (Join-Path $rbDir 'rollback.json') -Encoding UTF8

    Say "回滚记录已写入: $rbDir"
    Set-GhEnv ("SNAPSHOT_ROLLBACK_DIR=" + $rbDir)
}

# ---------------------------------------------------------------- 6. preCommands 钩子
if ($preCommands.Count -gt 0) {
    Say ("执行 preCommands：{0} 条" -f $preCommands.Count)
    $i = 0
    foreach ($c in $preCommands) {
        $i++
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        if ($DryRun) { Say ("  [$i] (dry-run) $c"); continue }
        try {
            Write-Host "[pre-restore]   [$i] > $c"
            $out = Invoke-Expression $c 2>&1 | Out-String
            if ($out.Trim()) { Write-Host ($out.Trim()) }
            Say "  [$i] 完成"
        } catch {
            Warn "  [$i] 失败（已忽略，不阻断）: $c  ->  $_"
        }
    }
} else {
    Say "preCommands 为空（可在 snapshot-config.json 的 restore.preCommands 里添加）"
}

# ---------------------------------------------------------------- 7. 驱动全量还原
if ($SkipRestore) {
    Say "已指定 -SkipRestore，跳过实际还原"
} else {
    $rs = Join-Path $PSScriptRoot "restore-snapshot.ps1"
    if (-not (Test-Path -LiteralPath $rs)) {
        Warn "找不到 restore-snapshot.ps1，无法驱动还原"
    } elseif ($DryRun) {
        Say "(dry-run) 跳过调用 restore-snapshot.ps1"
    } else {
        Say "驱动全量还原：restore-snapshot.ps1 -Scope machine"
        & $rs -Scope machine -Stage $Stage -ConfigPath $ConfigPath -RdpUser $RdpUser
    }
}

Say "===== 预还原结束 ====="
exit 0
