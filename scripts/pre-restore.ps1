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
    [string]$RdpUser    = $(if ($env:RDP_USERNAME) { $env:RDP_USERNAME } else { "a" }),
    [string]$DataDir    = $(if ($env:CLOUDRDP_DATA_DIR) { $env:CLOUDRDP_DATA_DIR } else { "D:\a\cloud-rdp" }),
    [string]$PortableDir= $(if ($env:CLOUDRDP_PORTABLE_DIR) { $env:CLOUDRDP_PORTABLE_DIR } else { "D:\a\cloud-rdp\_portable" }),
    [string]$RemoteRoot = "",
    [int]$ProbeAttempts  = 3,
    [int]$ProbeDelaySec  = 6,
    [int]$ProbeTimeoutSec= 25,
    [switch]$Pull,
    [switch]$SkipRestore,
    [switch]$DryRun,
    [switch]$Background
)

$ErrorActionPreference = "Continue"
$SysDir    = if ($env:CLOUDRDP_SYS_DIR) { $env:CLOUDRDP_SYS_DIR } elseif (Test-Path 'D:\') { "D:\cloudrdp-sys" } else { "C:\cloudrdp-sys" }
$RcloneExe = Join-Path $SysDir "rclone\rclone.exe"

# 远端判定 / 状态落盘共享库（与 sync-down.ps1 / sync-up.ps1 同源，保证口径一致）
$remoteLib    = Join-Path $PSScriptRoot "remote-lib.ps1"
$hasRemoteLib = Test-Path -LiteralPath $remoteLib
if ($hasRemoteLib) { . $remoteLib }
else { Write-Warning "[pre-restore] 未找到 remote-lib.ps1 —— 远端判定退化为「凭 rclone 退出码」，无法区分「空」与「网络抖动」" }

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

# ---------------------------------------------------------------- 后台模式：拉起自身后立刻返回
# 为什么：快照拉取 + 全量还原可能耗时数分钟，会拖慢「连接就绪」。
#         后台化后连接先可用，还原在后台继续；结论写 _state\restore-status.json。
if ($Background) {
    $exe = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $exe) { $exe = (Get-Command powershell.exe -ErrorAction Stop).Source }
    $argStr = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Stage "{1}" -Remote "{2}" -ConfigPath "{3}" -RdpUser "{4}" -DataDir "{5}" -PortableDir "{6}"' -f `
        $PSCommandPath, $Stage, $Remote, $ConfigPath, $RdpUser, $DataDir, $PortableDir
    if ($Pull)        { $argStr += ' -Pull' }
    if ($SkipRestore) { $argStr += ' -SkipRestore' }
    if ($DryRun)      { $argStr += ' -DryRun' }
    if (-not [string]::IsNullOrWhiteSpace($RemoteRoot)) { $argStr += (' -RemoteRoot "{0}"' -f $RemoteRoot) }

    $bgDir = Join-Path $SysDir "_state"
    try { New-Item -ItemType Directory -Force -Path $bgDir | Out-Null } catch { }
    $bgLog = Join-Path $bgDir "pre-restore-bg.log"
    Say "后台模式：已在后台启动预还原，本次立即返回（不阻塞连接）"
    Say "后台日志: $bgLog"
    $bgOk = $false
    try {
        Start-Process -FilePath $exe -ArgumentList $argStr -WindowStyle Hidden `
            -RedirectStandardOutput $bgLog -RedirectStandardError ($bgLog + ".err") -ErrorAction Stop | Out-Null
        $bgOk = $true
    } catch {
        Warn "后台拉起自身失败：$_ —— 改为前台继续执行"
    }
    if ($bgOk) {
        # 让上层（workflow）知道「已转后台、尚无结论」，避免被误判为 EMPTY
        if ($hasRemoteLib) {
            Set-RestoreStatus -Status 'PENDING' -Reason '已转后台执行（快照拉取+还原中）' -Scope snapshot -SysDir $SysDir -Remote $Remote -Local $Stage
        } else {
            Set-GhEnv "SNAPSHOT_STATUS=PENDING"
        }
        Say "===== 预还原（后台已接管）====="
        exit 0
    }
}

# ---------------------------------------------------------------- 0. 记录「镜像自带程序」基线
# 必须在任何还原动作之前执行：基线里的程序一律不备份，
# 否则镜像自带的约 120GB 工具链（VS / Android SDK / 缓存）会被传上云盘。
$stateDir = Join-Path $SysDir "_state"
try { New-Item -ItemType Directory -Force -Path $stateDir | Out-Null } catch { }
try {
    if (Get-Command Get-InstalledPrograms -ErrorAction SilentlyContinue) {
        # ⚠️ 必须用「含用户 hive」的版本：本脚本跑在 runneradmin 身份下，
        #    裸 Get-InstalledPrograms 的 HKCU: 是 runneradmin 的，看不到 RDP 用户的
        #    用户级安装（程序体在 %LOCALAPPDATA%\<厂商>）。基线里少了它们，
        #    备份侧就会把「历史备份过的用户级程序」当新装反复抓（或反过来永远漏抓）。
        #    两侧同源是增量门成立的前提。
        $allApps = @()
        if (Get-Command Get-InstalledProgramsIncludingUser -ErrorAction SilentlyContinue) {
            $allApps = @(Get-InstalledProgramsIncludingUser -RdpUser $RdpUser -Log { param($m) Say ("  " + $m) })
        } else {
            $allApps = @(Get-InstalledPrograms)
        }
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
$pullStatus = ''   # OK | EMPTY | TRANSIENT | FAILED（用于最后统一落盘）
if ($Pull) {
    if (-not (Test-Path -LiteralPath $RcloneExe)) {
        Warn "未找到 rclone，无法拉取快照"
        Set-GhEnv "SNAPSHOT_PREVALIDATE=FAILED"
        $pullStatus = 'FAILED'
        if ($hasRemoteLib) {
            Set-RestoreStatus -Status 'FAILED' -Reason ("未找到 rclone：{0}" -f $RcloneExe) -Scope snapshot -SysDir $SysDir -Remote $Remote -Local $Stage
        } else {
            Set-GhEnv "SNAPSHOT_STATUS=FAILED"
        }
        exit 0
    }
    New-Item -ItemType Directory -Force -Path $Stage | Out-Null
    Say "拉取快照: $Remote  ->  $Stage"

    # ---- ① 先判定远端到底有没有（关键：区分「真的没有」和「网络抽风」）----
    # 旧逻辑直接 copy，把 rclone 退出码 3/4 一律当 EMPTY —— 但 DNS 抖动时 AList 会对
    # PROPFIND 回 404，rclone 同样报 3。于是「网络抽风」被误判成「远端没有快照」，
    # 本机既不还原、还反过来把自己当空覆盖上云（acc-1 事故根因）。
    $verdict = $null
    if ($hasRemoteLib) {
        $verdict = Resolve-RemoteVerdict -RcloneExe $RcloneExe -Remote $Remote -Root $RemoteRoot `
                     -Attempts $ProbeAttempts -DelaySec $ProbeDelaySec -TimeoutSec $ProbeTimeoutSec
        Say ("远端判定：{0} —— {1}" -f $verdict.Verdict, $verdict.Message)
    }
    $vKind = if ($verdict) { [string]$verdict.Verdict } else { '' }
    $vMsg  = if ($verdict) { [string]$verdict.Message } else { '' }

    # 写「待重试」标记：保活循环见到它会用 -Background 重跑本脚本
    $writePending = {
        param([string]$why)
        try {
            $pend = Join-Path $stateDir 'snapshot-restore-pending.txt'
            ("{0}  TRANSIENT: {1}" -f (Get-Date).ToUniversalTime().ToString('o'), $why) | Out-File -LiteralPath $pend -Encoding UTF8
        } catch { }
    }
    $clearPending = {
        try {
            $pend = Join-Path $stateDir 'snapshot-restore-pending.txt'
            if (Test-Path -LiteralPath $pend) { [System.IO.File]::Delete($pend) }
        } catch { }
    }

    if ($vKind -eq 'EMPTY') {
        Say "远端尚无快照（首次运行正常）"
        Set-GhEnv "SNAPSHOT_PREVALIDATE=EMPTY"
        $pullStatus = 'EMPTY'
        if ($hasRemoteLib) { Set-RestoreStatus -Status 'EMPTY' -Reason $vMsg -Scope snapshot -SysDir $SysDir -Remote $Remote -Local $Stage }
        else { Set-GhEnv "SNAPSHOT_STATUS=EMPTY" }
        exit 0
    }
    if ($vKind -eq 'AUTH') {
        Warn "139 云盘鉴权失败，无法拉取快照"
        Set-GhEnv "SNAPSHOT_PREVALIDATE=FAILED"
        $pullStatus = 'FAILED'
        if ($hasRemoteLib) { Set-RestoreStatus -Status 'FAILED' -Reason $vMsg -Scope snapshot -SysDir $SysDir -Remote $Remote -Local $Stage }
        else { Set-GhEnv "SNAPSHOT_STATUS=FAILED" }
        exit 0
    }
    if ($vKind -eq 'TRANSIENT') {
        # ⚠️ 网络/服务抖动 —— 远端可能有数据，绝不能当 EMPTY，更不能写远端。
        Warn "139 云盘暂时不可达，本次不拉取（保活循环稍后重试）"
        Set-GhEnv "SNAPSHOT_PREVALIDATE=TRANSIENT"
        $pullStatus = 'TRANSIENT'
        if ($hasRemoteLib) { Set-RestoreStatus -Status 'TRANSIENT' -Reason $vMsg -Scope snapshot -SysDir $SysDir -Remote $Remote -Local $Stage }
        else { Set-GhEnv "SNAPSHOT_STATUS=TRANSIENT" }
        & $writePending $vMsg
        exit 0
    }

    # ---- ② 判定通过（OK 或库缺失退化为空串），正式拷贝（带重试）----
    $code = 0
    for ($i = 1; $i -le 3; $i++) {
        & $RcloneExe copy $Remote $Stage `
            --update --transfers 4 --checkers 8 `
            --timeout 0 --contimeout 0 `
            --retries 3 --low-level-retries 5 `
            --stats-one-line -v
        $code = $LASTEXITCODE
        if ($code -eq 0) { break }
        if ($i -lt 3) { Warn "第 $i/3 次拉取失败（码 $code），8 秒后重试"; Start-Sleep -Seconds 8 }
    }
    if ($code -ne 0) {
        # 拷贝失败：再判定一次，把「网络问题」和「真的没有」分开
        $reVerdict = $null
        if ($hasRemoteLib) {
            $reVerdict = Resolve-RemoteVerdict -RcloneExe $RcloneExe -Remote $Remote -Root $RemoteRoot `
                           -Attempts $ProbeAttempts -DelaySec $ProbeDelaySec -TimeoutSec $ProbeTimeoutSec
        }
        $reKind = if ($reVerdict) { [string]$reVerdict.Verdict } else { '' }
        $reason = if ($reVerdict) { [string]$reVerdict.Message } else { "rclone 退出码 $code" }
        Warn "快照拉取失败（rclone 码 $code；复判 $reKind）：$reason"
        if ($reKind -eq 'EMPTY') {
            Set-GhEnv "SNAPSHOT_PREVALIDATE=EMPTY"
            $pullStatus = 'EMPTY'
            if ($hasRemoteLib) { Set-RestoreStatus -Status 'EMPTY' -Reason $reason -Scope snapshot -SysDir $SysDir -Remote $Remote -Local $Stage }
            else { Set-GhEnv "SNAPSHOT_STATUS=EMPTY" }
        } elseif ($reKind -eq 'TRANSIENT' -or $reKind -eq '') {
            Set-GhEnv "SNAPSHOT_PREVALIDATE=TRANSIENT"
            $pullStatus = 'TRANSIENT'
            if ($hasRemoteLib) { Set-RestoreStatus -Status 'TRANSIENT' -Reason $reason -Scope snapshot -SysDir $SysDir -Remote $Remote -Local $Stage }
            else { Set-GhEnv "SNAPSHOT_STATUS=TRANSIENT" }
            & $writePending $reason
        } else {
            Set-GhEnv "SNAPSHOT_PREVALIDATE=FAILED"
            $pullStatus = 'FAILED'
            if ($hasRemoteLib) { Set-RestoreStatus -Status 'FAILED' -Reason $reason -Scope snapshot -SysDir $SysDir -Remote $Remote -Local $Stage }
            else { Set-GhEnv "SNAPSHOT_STATUS=FAILED" }
        }
        exit 0
    }
    $pullStatus = 'OK'
    & $clearPending
    Say "快照拉取完成"
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

# ---- 用户名变更迁移（幂等）----
# 快照按绝对路径镜像（files/C/Users/<name>/...），而上一行会用快照里的用户名覆盖当前用户名。
# 所以一旦账号改过名，不迁移就会把文件还原到旧 profile —— 以新账号登录后看不到桌面/文档
# = 静默数据丢失。必须在这里做（早于 2a 校验与 4 准备目录），否则会先建出旧名脏目录。
$curUser = if ($env:RDP_USERNAME) { $env:RDP_USERNAME } else { $RdpUser }
if ($RdpUser -ne $curUser) {
    $mig = Join-Path $PSScriptRoot 'rdpuser-migrate.ps1'
    if (Test-Path -LiteralPath $mig) {
        try {
            & $mig -Stage $Stage -OldName $RdpUser -NewName $curUser
            # 迁移已落盘 —— 重新加载 manifest 并把用户名切到当前账号
            $mf = Get-Content -LiteralPath (Join-Path $Stage 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $RdpUser = $curUser
            Say "用户名已迁移为 $RdpUser（快照目录与 manifest 均已对齐）"
        } catch {
            Warn "用户名迁移失败：$_ —— 按旧名 $RdpUser 继续，个人数据可能不还原"
        }
    } else {
        Warn "未找到 rdpuser-migrate.ps1，跳过用户名迁移（快照用户名 $RdpUser ≠ 当前 $curUser）"
    }
}

# 记录「上次备份过的程序」-> 关机时继续带上（跨运行持久：镜像里没有它们，但必须留住）
try {
    $prevRegs = @()
    $prevLocs = @()
    if ($mf.apps -and $mf.apps.programs) {
        foreach ($pg in @($mf.apps.programs)) {
            if ($pg.regPath)      { $prevRegs += [string]$pg.regPath }
            if ($pg.originalPath) { $prevLocs += [string]$pg.originalPath }
        }
    }
    $prevArr = [object[]]$prevRegs
    $locArr  = [object[]]$prevLocs
    ([pscustomobject]@{
        recordedUtc = (Get-Date).ToUniversalTime().ToString('o')
        count       = $prevArr.Count
        regPaths    = $prevArr
        locations   = $locArr
    } | ConvertTo-Json -Depth 4) | Out-File -LiteralPath (Join-Path $stateDir "prev-programs.json") -Encoding UTF8
    Say ("上次备份过的程序：{0} 项 / {1} 个目录（本次会继续带上）" -f $prevArr.Count, $locArr.Count)

    # 上次快照里的「快捷方式线索补抓」统计 —— 供连接信息显示。
    # 为什么在这里：收尾全量备份发生在第 15 步，而 0d 的抢先版连接信息更早（Tailscale 之后）就打印了。
    $prevShortcutN  = 0
    $prevShortcutMB = 0.0
    if ($mf.apps -and $mf.apps.programs) {
        foreach ($pg in @($mf.apps.programs)) {
            if ([string]$pg.source -eq 'shortcut') {
                $prevShortcutN++
                $prevShortcutMB += ([double]$pg.bytes / 1MB)
            }
        }
    }
    Set-GhEnv ("SNAPSHOT_PROGRAMS=" + @($mf.apps.programs).Count)
    Set-GhEnv ("SNAPSHOT_SHORTCUTS_CAPTURED=" + $prevShortcutN)
    Set-GhEnv ("SNAPSHOT_SHORTCUTS_MB=" + [math]::Round($prevShortcutMB, 1))
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
$restoreOutcome = ''   # restore-snapshot.ps1 的结论（OK|PARTIAL|...），供第 8 步落盘
if ($SkipRestore) {
    Say "已指定 -SkipRestore，跳过实际还原"
    $restoreOutcome = 'SKIPPED'
} else {
    $rs = Join-Path $PSScriptRoot "restore-snapshot.ps1"
    if (-not (Test-Path -LiteralPath $rs)) {
        Warn "找不到 restore-snapshot.ps1，无法驱动还原"
        $restoreOutcome = 'FAILED'
    } elseif ($DryRun) {
        Say "(dry-run) 跳过调用 restore-snapshot.ps1"
        $restoreOutcome = 'SKIPPED'
    } else {
        Say "驱动全量还原：restore-snapshot.ps1 -Scope machine"
        & $rs -Scope machine -Stage $Stage -ConfigPath $ConfigPath -RdpUser $RdpUser
        # restore-snapshot.ps1 只写 GITHUB_ENV（不写 _state json）；**立刻**回读，
        # 免得被后续（保活里的 backup 等）写入的 SNAPSHOT_STATUS 污染。
        if ($hasRemoteLib) { $restoreOutcome = [string](Get-GhEnvValue 'SNAPSHOT_STATUS') }
    }
}

# ---------------------------------------------------------------- 8. 统一状态落盘
# restore-snapshot.ps1 只写 GITHUB_ENV（SNAPSHOT_STATUS=OK|PARTIAL），不写
# _state\restore-status.json。这里把「最终结论」同时补进 json，供工作台展示。
# 判定优先级：还原脚本结论 > 拉取阶段结论（终态时才用）。
if ($hasRemoteLib) {
    $finalStatus = $restoreOutcome
    if ([string]::IsNullOrWhiteSpace($finalStatus)) {
        if ($pullStatus -in @('EMPTY', 'TRANSIENT', 'FAILED')) { $finalStatus = $pullStatus }
        elseif ($pullStatus -eq 'OK') { $finalStatus = 'OK' }
        else { $finalStatus = 'FAILED' }   # 没拉、没还原、也没结论 —— 不能报 OK
    }

    $finalReason = ''
    switch ($finalStatus) {
        'OK'        { $finalReason = '快照已拉取并完成还原' }
        'PARTIAL'   { $finalReason = ("还原完成，但有 {0} 个问题项（详见日志）" -f $problems.Count) }
        'EMPTY'     { $finalReason = '远端尚无快照（首次运行正常）' }
        'TRANSIENT' { $finalReason = '139 云盘暂时不可达，稍后由保活循环重试' }
        'FAILED'    { $finalReason = '快照拉取或还原失败（详见日志）' }
        'SKIPPED'   { $finalReason = '本次跳过还原（-SkipRestore / -DryRun）' }
        default     { $finalReason = '' }
    }
    try {
        Set-RestoreStatus -Status $finalStatus -Reason $finalReason -Scope snapshot -SysDir $SysDir -Remote $Remote -Local $Stage
    } catch { }

    # 还原成功（或部分成功）→ 清掉「待重试」标记，避免保活循环反复重跑
    if ($finalStatus -in @('OK', 'PARTIAL')) {
        try {
            $pend = Join-Path $stateDir 'snapshot-restore-pending.txt'
            if (Test-Path -LiteralPath $pend) { [System.IO.File]::Delete($pend) }
        } catch { }
    }
    Say ("快照最终状态：{0} —— {1}" -f $finalStatus, $finalReason)
}

Say "===== 预还原结束 ====="
exit 0
