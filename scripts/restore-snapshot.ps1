<#
.SYNOPSIS
  从 139 云盘还原「整机状态快照」。

.DESCRIPTION
  为什么分两个作用域？—— 这是 Windows 跨机还原的核心难点：
    · runner 进程以 runneradmin 身份运行，而 RDP 用户是 a；
    · 用户 a 的 HKCU 注册表与用户配置文件（Desktop/Documents…）在
      该用户首次登录前并不存在，以 runneradmin 身份写入会被 Windows
      当成「异常 profile」而在登录时重建，导致还原失效。

  因此：
    -Scope machine  开机时以 runneradmin 执行：拉取快照、还原机器级文件、
                    导入机器注册表、恢复系统设置（时区/电源）、还原公共桌面，
                    并注册一个「首次登录时触发」的计划任务。
    -Scope user     用户首次登录时以用户 a 身份执行：还原个人目录文件、
                    导入 HKCU 注册表、还原个人快捷方式与壁纸，然后自注销任务。

.PARAMETER Scope   machine | user
.PARAMETER Pull    执行前先从远端拉取快照（仅 machine 作用域需要）

.NOTES
  本脚本永不返回非 0。结果透出 SNAPSHOT_STATUS / SNAPSHOT_RESTORED_*。
#>
[CmdletBinding()]
param(
    [ValidateSet("machine", "user")]
    [string]$Scope      = "machine",
    [string]$Stage      = $(if ($env:CLOUDRDP_SNAPSHOT_STAGE) { $env:CLOUDRDP_SNAPSHOT_STAGE } elseif (Test-Path 'D:\') { "D:\cloudrdp-sys\_snapshot" } else { "C:\_snapshot" }),
    [string]$Remote     = $(if ($env:CLOUDRDP_REMOTE_BASE) { $env:CLOUDRDP_REMOTE_BASE + "/_snapshot" } else { "alist:/cloudrdp/AI文件库/_snapshot" }),
    [string]$ConfigPath = (Join-Path $PSScriptRoot "snapshot-config.json"),
    [string]$RdpUser    = $(if ($env:RDP_USERNAME) { $env:RDP_USERNAME } else { "a" }),
    [switch]$Pull,
    [switch]$NoTask
)

$ErrorActionPreference = "Continue"
$SysDir        = if ($env:CLOUDRDP_SYS_DIR) { $env:CLOUDRDP_SYS_DIR } elseif (Test-Path 'D:\') { "D:\cloudrdp-sys" } else { "C:\cloudrdp-sys" }
$RcloneExe     = Join-Path $SysDir "rclone\rclone.exe"
$UserHiveToken = "__RDPUSER__"
$TaskName      = "CloudRDP-RestoreUser"
$PortableDir   = $(if ($env:CLOUDRDP_PORTABLE_DIR) { $env:CLOUDRDP_PORTABLE_DIR } else { "D:\a\cloud-rdp\_portable" })

# 可移动程序共享库（识别 / 搬运 / 还原）
$portableLib = Join-Path $PSScriptRoot "portable-lib.ps1"
if (Test-Path -LiteralPath $portableLib) { . $portableLib }
else { Write-Warning "[restore] 未找到 portable-lib.ps1，可移动程序还原不可用" }

# 安装型程序共享库（识别 / 备份 / 还原）
$programsLib = Join-Path $PSScriptRoot "programs-lib.ps1"
if (Test-Path -LiteralPath $programsLib) { . $programsLib }
else { Write-Warning "[restore] 未找到 programs-lib.ps1，安装型程序还原不可用" }

# 用户注册表 hive 共享库（定位 / 判断是否已加载）
# 用途：用户**已经登录**时（本次「连接信息提前打印」后很常见），hive 已被 Windows 加载，
#       此时不能再 reg load，否则必然失败；直接写 HKU\<SID> 才对。
$userHiveLib = Join-Path $PSScriptRoot "userhive-lib.ps1"
$script:HasUserHiveLib = $false
if (Test-Path -LiteralPath $userHiveLib) { . $userHiveLib; $script:HasUserHiveLib = $true }
else { Write-Warning "[restore] 未找到 userhive-lib.ps1，用户 hive 已加载时的兜底不可用" }

# 注册表导入容错库：reg.exe import 是 best-effort —— Windows 保护键（默认程序关联 UserChoice）
# 与被系统进程占用的键（Feeds/Search）永远写不进去，exit=1 但 99% 的键其实已写入。
# 旧代码把「部分成功」当「整文件失败」→ 误报「个人配置还原失败」。
$regImportLib = Join-Path $PSScriptRoot "regimport-lib.ps1"
$script:HasRegImportLib = $false
if (Test-Path -LiteralPath $regImportLib) { . $regImportLib; $script:HasRegImportLib = $true }
else { Write-Warning "[restore] 未找到 regimport-lib.ps1，注册表导入容错不可用" }

# 快照一致性共享库：还原文件前优雅关闭目标程序（Edge / WorkBuddy）。
# 为什么需要：程序运行时 SQLite(WAL)/LevelDB 被独占持有 → robocopy 覆盖失败（码 >= 8）
# → 整个目录被判「还原失败」→ 桌面出现 _CloudRDP_还原失败.txt。
$quiesceLib = Join-Path $PSScriptRoot "app-quiesce-lib.ps1"
$script:HasQuiesceLib = $false
if (Test-Path -LiteralPath $quiesceLib) { . $quiesceLib; $script:HasQuiesceLib = $true }
else { Write-Warning "[restore] 未找到 app-quiesce-lib.ps1，还原前不会关闭占用程序" }

# 被占用文件的容错复制库：robocopy 失败（码 >= 8）时用共享读写补写
$lockCopyLib = Join-Path $PSScriptRoot "lockcopy-lib.ps1"
$script:HasLockCopyLib = $false
if (Test-Path -LiteralPath $lockCopyLib) { . $lockCopyLib; $script:HasLockCopyLib = $true }
else { Write-Warning "[restore] 未找到 lockcopy-lib.ps1，robocopy 失败时不会尝试共享读写补写" }

# 用户数据（Edge / WorkBuddy）取证与补漏共享库。
# 为什么需要：清单里曾经写的是 .workbuddy-ai（本机不存在）→ WorkBuddy 数据静默零还原，
# 且 Edge 的 Login Data（已存密码）从没被校验过。取证口径统一放到 userdata-lib.ps1，
# 与第 10 步（reinstall-apps.ps1）共用同一份判断，避免两处标准漂移。
$userDataLib = Join-Path $PSScriptRoot "userdata-lib.ps1"
$script:HasUserDataLib = $false
if (Test-Path -LiteralPath $userDataLib) { . $userDataLib; $script:HasUserDataLib = $true }
else { Write-Warning "[restore] 未找到 userdata-lib.ps1，Edge/WorkBuddy 用户数据取证不可用" }

# 用户配置文件（C:\Users\<user> + NTUSER.DAT）预创建共享库。
# 为什么是「根因库」：用户级数据（Edge User Data / 桌面 / 文档 / .workbuddy）只有在
# profile 已存在时才能还原；而 profile 的创建一直依赖
# `Start-Process -Credential cmd /c exit` —— 该写法**缺 -LoadUserProfile**，
# 于是进程起得来、不报错，profile 却没被创建 → 用户数据整段静默丢失
# （真机 run 35780696116 里 C:\Users\a 全轮 run 从未出现）。详见 userprofile-lib.ps1 头注。
$userProfileLib = Join-Path $PSScriptRoot "userprofile-lib.ps1"
$script:HasUserProfileLib = $false
if (Test-Path -LiteralPath $userProfileLib) { . $userProfileLib; $script:HasUserProfileLib = $true }
else { Write-Warning "[restore] 未找到 userprofile-lib.ps1，用户配置文件预创建不可用（用户数据可能无法还原）" }

# 长任务保命库（可缺省）：本脚本自己也会拉快照（Invoke-PullSnapshot），
# 拉取方向的 rclone 参数口径统一放在 watchdog-lib.ps1（有限超时 + 更多低层重试）。
$wdLib = Join-Path $PSScriptRoot "watchdog-lib.ps1"
if (Test-Path -LiteralPath $wdLib) { . $wdLib }
else { Write-Warning "[restore] 未找到 watchdog-lib.ps1 —— 拉取沿用旧 rclone 参数（--timeout 0）" }

function Set-GhEnv([string]$kv) {
    if ($env:GITHUB_ENV) { $kv | Out-File $env:GITHUB_ENV -Append -Encoding ascii }
}
function Say([string]$m)  { Write-Host "[restore] $m" }
function Warn([string]$m) { Write-Warning "[restore] $m" }

# ---------------------------------------------------------------- 一致性 / 校验辅助

# 还原文件前关闭占用程序（配置 files.quiesce）。返回一句话描述，供日志与 GITHUB_ENV 用。
function Invoke-RestoreQuiesce {
    param([string]$ConfigPath = '')
    if (-not $script:HasQuiesceLib) { return 'no-lib' }
    $specs = @(Get-QuiesceSpecs -ConfigPath $ConfigPath)
    if ($specs.Count -eq 0) { return 'none' }
    Say ("还原一致性：先关闭占用程序（{0}）" -f (($specs | ForEach-Object { $_.name }) -join ', '))
    $q = Stop-AppForSnapshot -Specs $specs -Log { param($m) Say ("  " + $m) }
    return $q.detail
}

# 还原后取证：用户最在意的两块数据（Edge / WorkBuddy）是否真的回来了。
# 为什么要有：这两块历史上都被「静默漏掉」过（Edge robocopy 码 9、程序本体从没被还原），
# 光看「还原了几个目录」是发现不了的。现在取证口径由 userdata-lib.ps1 统一提供，
# 与第 10 步（reinstall-apps.ps1）同源，不会两处标准不一致。
function Get-RestoreEvidence {
    param([string]$RdpUser, [string]$Stage = '', [string]$ConfigPath = '', [switch]$ProbeCrypt)

    $out = [ordered]@{ edge = 'MISSING'; edgeDetail = ''; wbai = 'MISSING'; wbaiDetail = ''; state = 'MISSING'; detail = ''; crypt = 'UNKNOWN'; cryptNote = '' }
    if (-not $script:HasUserDataLib) { return $out }
    try {
        $r = Invoke-UserDataVerifyAndRepair -Stage $Stage -RdpUser $RdpUser -ConfigPath $ConfigPath `
                 -Log { param($m) Say ("  " + $m) } -NoRepair -ProbeCrypt:$ProbeCrypt
        $out.edge   = [string]$r.edge
        $out.wbai   = [string]$r.wb
        $out.state  = [string]$r.state
        $out.detail = [string]$r.detail
        $out.crypt  = [string]$r.crypt
        $out.cryptNote = [string]$r.cryptNote
        foreach ($e in @($r.after)) {
            if ($e.name -like 'Edge*') { $out.edgeDetail = [string]$e.detail }
            if ($e.name -like 'WorkBuddy*' -and $e.name -notlike '*旧路径*') { $out.wbaiDetail = [string]$e.detail }
        }
    } catch { }
    return $out
}

# 把取证结果同时写日志与 GITHUB_ENV
# （EDGE_RESTORE / WBAI_RESTORE 保留原名供老工作流兼容，新增 USERDATA_RESTORE）
function Write-RestoreEvidence {
    param([string]$RdpUser, [string]$LogPath = '', [string]$Stage = '', [string]$ConfigPath = '', [switch]$ProbeCrypt)
    $ev = Get-RestoreEvidence -RdpUser $RdpUser -Stage $Stage -ConfigPath $ConfigPath -ProbeCrypt:$ProbeCrypt
    Say ("用户数据取证：Edge {0}（{1}）| WorkBuddy {2}（{3}）| 合计 {4}（{5}）" -f `
         $ev.edge, $ev.edgeDetail, $ev.wbai, $ev.wbaiDetail, $ev.state, $ev.detail)
    if ($ProbeCrypt) { Say ("  Edge 加密密钥：{0}（{1}）" -f $ev.crypt, $ev.cryptNote) }
    Set-GhEnv ("EDGE_RESTORE=" + $ev.edge)
    Set-GhEnv ("WBAI_RESTORE=" + $ev.wbai)
    Set-GhEnv ("USERDATA_RESTORE=" + $ev.state)
    Set-GhEnv ("USERDATA_RESTORE_DETAIL=" + $ev.detail)
    if ($ProbeCrypt) {
        Set-GhEnv ("EDGE_CRYPT=" + $ev.crypt)
        Set-GhEnv ("EDGE_CRYPT_NOTE=" + $ev.cryptNote)
    }
    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        try {
            ("[{0}] evidence userdata={1}({2}) edge={3}({4}) wb={5}({6}) crypt={7}" -f (Get-Date).ToString('o'), `
             $ev.state, $ev.detail, $ev.edge, $ev.edgeDetail, $ev.wbai, $ev.wbaiDetail, $ev.crypt) |
                Out-File -LiteralPath $LogPath -Append -Encoding utf8
        } catch { }
    }
    return $ev
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

# ---------- 首次真正加载 snapshot-config.json，按开关决定还原哪些类别 ----------
$cfg = $null
if (Test-Path -LiteralPath $ConfigPath) {
    try { $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Warn "配置解析失败（$ConfigPath）：$_，全部按默认开启处理" }
} else {
    Warn "未找到配置 $ConfigPath，全部按默认开启处理"
}
$restoreCfg  = Get-Cfg $cfg 'restore' $null
$doFiles     = [bool](Get-Cfg $restoreCfg 'files'     $true)
$doRegistry  = [bool](Get-Cfg $restoreCfg 'registry'  $true)
$doSystem    = [bool](Get-Cfg $restoreCfg 'system'    $true)
$doShortcuts = [bool](Get-Cfg $restoreCfg 'shortcuts' $true)

# 安装型程序：还原开关 + 还原根（C 盘紧张时程序实体落 D 盘，原路径建 junction）
$programsCfg    = Get-Cfg $cfg 'programs' $null
$doPrograms     = [bool](Get-Cfg $programsCfg 'enabled' $true)
$preferJunction = [bool](Get-Cfg $programsCfg 'preferJunction' $true)
# 永不还原的程序目录（前缀匹配）：即使旧快照里含它，也不放回来
$programsExclude = [object[]](Get-Cfg $programsCfg 'excludePaths' @())
$ProgramsRoot   = $(if ($env:CLOUDRDP_PROGRAMS_DIR) { $env:CLOUDRDP_PROGRAMS_DIR } else { (Join-Path $SysDir "programs") })

function Get-SnapshotPrograms {
    param([string]$Stage)
    $f = Join-Path $Stage "programs\programs.json"
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    try { return @((Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json).programs) } catch { return @() }
}

function Get-AbsFromMirror {
    param([string]$Rel)
    $parts = $Rel -split '[\\/]'
    if ($parts.Count -lt 2) { return ($parts[0] + ":\") }
    return ("{0}:\{1}" -f $parts[0], ($parts[1..($parts.Count - 1)] -join '\'))
}

# robocopy 失败后的「共享读写」补写（依赖 lockcopy-lib.ps1）
# 为什么需要：robocopy 以独占方式打开目标（GENERIC_WRITE，无共享位），目标被浏览器 /
# SQLite / 索引服务占用时必然失败（返回码 >= 8）；而 .NET 的 FileStream 两侧都带
# FileShare.ReadWrite，可以照写不误。
# LOCK / LOG / LOG.old 这类「无还原价值」的浏览器运行时文件不算失败（浏览器会自建）。
function Invoke-SharedCopyRetry {
    param([string]$Src, [string]$Dst)

    $out = @{ tried = 0; ok = 0; failed = 0; ignored = 0; failures = @() }
    if (-not (Get-Command Copy-FileShared -ErrorAction SilentlyContinue)) { return $out }
    if (-not (Test-Path -LiteralPath $Src)) { return $out }

    try {
        $srcRoot = $Src.TrimEnd('\')
        $files = @(Get-ChildItem -LiteralPath $srcRoot -Recurse -File -Force -ErrorAction SilentlyContinue)
        foreach ($f in $files) {
            $rel = $f.FullName.Substring($srcRoot.Length).TrimStart('\')
            $target = Join-Path $Dst $rel

            # 只在「目标缺失或大小不一致」时才补写，避免全量重写
            $need = $true
            if (Test-Path -LiteralPath $target) {
                try { if ((Get-Item -LiteralPath $target -Force).Length -eq $f.Length) { $need = $false } } catch { }
            }
            if (-not $need) { continue }

            if (Get-Command Test-IgnorableFileName -ErrorAction SilentlyContinue) {
                if (Test-IgnorableFileName -Path $f.Name) { $out.ignored++; continue }
            }

            $out.tried++
            $r = Copy-FileShared -Source $f.FullName -Destination $target
            if ($r.ok) { $out.ok++ } else {
                $out.failed++
                if (@($out.failures).Count -lt 10) { $out.failures += ("{0}（{1}）" -f $rel, $r.reason) }
            }
        }
    } catch { }
    return $out
}

function Invoke-RobocopyRestore {
    param([string]$Src, [string]$Dst)
    if (-not (Test-Path -LiteralPath $Src)) { return -1 }
    New-Item -ItemType Directory -Force -Path $Dst | Out-Null
    # 注意：不加 /PURGE —— 只补回快照里的文件，不删除机器上新增的文件
    & robocopy $Src $Dst /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP /XJ 2>&1 | Out-Null
    $code = $LASTEXITCODE

    # 码 >= 8 = 有文件/目录没复制成 → 用共享读写补一遍，能救回来就不算失败
    if ($code -ge 8) {
        $r = Invoke-SharedCopyRetry -Src $Src -Dst $Dst
        if ($r.tried -eq 0 -and $r.ignored -eq 0) {
            Warn ("  robocopy 码 {0}：共享读写补写没有可处理项（可能失败的是目录而非文件）" -f $code)
        } elseif ($r.failed -eq 0) {
            Say ("  robocopy 码 {0} → 共享读写补写成功（补 {1} 个 / 忽略运行时文件 {2} 个）" -f $code, $r.ok, $r.ignored)
            return 0
        } else {
            Warn ("  robocopy 码 {0}，共享读写补写后仍失败 {1} 个（补成功 {2} / 忽略 {3}）" -f $code, $r.failed, $r.ok, $r.ignored)
            foreach ($x in @($r.failures)) { Warn ("    仍失败：{0}" -f $x) }
        }
    }
    return $code
}

# ================================================================ 通用：拉取快照

function Invoke-PullSnapshot {
    param([string]$Remote, [string]$Stage, [int]$MaxAttempts = 3, [int]$RetryDelaySec = 8)

    if (-not (Test-Path -LiteralPath $RcloneExe)) { Warn "未找到 rclone，无法拉取快照"; return "NO_RCLONE" }

    New-Item -ItemType Directory -Force -Path $Stage | Out-Null
    Say "拉取快照: $Remote  ->  $Stage"

    # 拉取方向用有限超时：--timeout 0 会让一条僵死连接吊到天亮（rclone 不报错、step 不结束）。
    # 口径与 pre-restore / sync-down 保持一致，统一由 watchdog-lib.ps1 提供。
    $netArgs = if (Get-Command Get-RdpRcloneNetArgs -ErrorAction SilentlyContinue) { @(Get-RdpRcloneNetArgs -Mode pull) } else {
        @('--timeout','5m','--contimeout','60s','--transfers','4','--checkers','8',
          '--retries','5','--low-level-retries','10','--stats-one-line','-v')
    }

    # 重 IO 之前先加 Defender 排除项 + 起连接看门狗（长任务保命，见 watchdog-lib.ps1）。
    # 库可能不存在（老工作区）→ 全部 fail-soft，缺库就退化成「只用有限超时」。
    $wdHandle = $null
    if (Get-Command Enable-RdpAvExclusions -ErrorAction SilentlyContinue) {
        try { $null = Enable-RdpAvExclusions } catch { Warn "设置 Defender 排除项失败（可忽略）：$_" }
    }
    if (Get-Command Start-RdpConnWatchdog -ErrorAction SilentlyContinue) {
        try { $wdHandle = Start-RdpConnWatchdog -IntervalSec 60 -FailThreshold 3 } catch { Warn "拉起看门狗失败（可忽略）：$_" }
    }

    $code = 0
    try {
        for ($i = 1; $i -le $MaxAttempts; $i++) {
            & $RcloneExe copy $Remote $Stage --update @netArgs
            $code = $LASTEXITCODE
            if ($code -eq 0) { return "OK" }
            if ($code -eq 3 -or $code -eq 4) { return "EMPTY" }   # 远端尚无快照（首次运行）
            if ($i -lt $MaxAttempts) {
                Warn "第 $i/$MaxAttempts 次拉取失败（rclone 码 $code），$RetryDelaySec 秒后重试..."
                Start-Sleep -Seconds $RetryDelaySec
            }
        }
        return "FAILED"
    } finally {
        if ($wdHandle -and (Get-Command Stop-RdpConnWatchdog -ErrorAction SilentlyContinue)) {
            try { $null = Stop-RdpConnWatchdog -Handle $wdHandle } catch { }
        }
    }
}

# ================================================================ machine 作用域

function Invoke-MachineRestore {
    param([string]$Stage, [string]$RdpUser, [string]$ConfigPath, [switch]$NoTask)

    $manifestPath = Join-Path $Stage "manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        Say "未发现 manifest.json —— 视为首次运行，无历史快照可还原"
        Set-GhEnv "SNAPSHOT_STATUS=EMPTY"
        return
    }

    $mf = $null
    try { $mf = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Warn "manifest.json 解析失败：$_"; Set-GhEnv "SNAPSHOT_STATUS=FAILED"; return }

    if ($mf.rdpUser) { $RdpUser = $mf.rdpUser }     # 以快照记录的用户名为准
    Say ("快照时间: {0} | 主机: {1} | 用户: {2} | 文件 {3} 个" -f $mf.createdLocal, $mf.hostname, $RdpUser, $mf.files.totalFiles)

    $problems = New-Object System.Collections.Generic.List[string]
    $restored = 0

    # ---------- 1. 机器级文件（排除 C:\Users\<RdpUser>\... ，那部分交给登录任务） ----------
    # 注意：被跳过的用户级目录数要**报出来**。历史事故里这 12 个目录被静默跳过，
    # 日志只留一句「还原了 1 个目录」，用户数据丢失完全不可见（见 userprofile-lib.ps1）。
    $userPrefix = ("C\Users\" + $RdpUser).ToLower()
    # 覆盖文件前先关掉占用程序，否则 robocopy 覆盖失败（码 >= 8）→ 整目录被判还原失败
    Set-GhEnv ("SNAP_QUIESCE=" + (Invoke-RestoreQuiesce -ConfigPath $ConfigPath))
    $userScopeDirs = New-Object System.Collections.Generic.List[string]
    if ($doFiles) {
        foreach ($e in @($mf.files.entries)) {
            $rel = [string]$e.mirror
            if ([string]::IsNullOrWhiteSpace($rel)) { continue }
            if ($rel.ToLower().StartsWith($userPrefix)) { $userScopeDirs.Add($rel); continue }   # 个人目录 → 留给 4d / user 作用域

            $src = Join-Path (Join-Path $Stage "files") $rel
            $dst = Get-AbsFromMirror -Rel $rel
            $code = Invoke-RobocopyRestore -Src $src -Dst $dst
            if ($code -ge 8) { $problems.Add("file:$rel"); Warn "还原失败（robocopy $code）：$rel" }
            else { $restored++; Say "  还原 $rel  ->  $dst" }
        }
    } else { Say "  文件还原已关闭（restore.files=false）" }
    if ($userScopeDirs.Count -gt 0) {
        Say ("  用户级目录 {0} 个由 4d 预还原 / 首次登录任务处理（本段不碰）：{1}" -f `
              $userScopeDirs.Count, (($userScopeDirs | Select-Object -First 8) -join ', '))
    }

    # ---------- 2. 机器级注册表 ----------
    if ($doRegistry) {
        $regDir = Join-Path $Stage "registry\machine"
        if (Test-Path -LiteralPath $regDir) {
            foreach ($f in @(Get-ChildItem -LiteralPath $regDir -Filter *.reg -File -ErrorAction SilentlyContinue)) {
                if ($script:HasRegImportLib) {
                    $ri = Invoke-RegImportTolerant -RegFile $f.FullName
                    if ($ri.ok) {
                        Say "  导入注册表 $($f.Name)"
                    } elseif ($ri.partial) {
                        # 部分成功 = 数据基本已还原：Windows 保护键（UserChoice 等）
                        # 与被系统占用的键（Feeds/Search）写不进去属正常，不计失败
                        Warn ("  注册表部分导入 {0}：{1}/{2} 块失败（系统保护/占用键，属正常）—— {3}" -f `
                              $f.Name, $ri.failedN, $ri.blocks, (Format-RegFailedKeys $ri.failedKeys))
                    } else {
                        Warn "注册表导入失败：$($f.Name)"; $problems.Add("reg:$($f.Name)")
                    }
                } else {
                    & reg.exe import "$($f.FullName)" 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) { Say "  导入注册表 $($f.Name)" }
                    else { Warn "注册表导入失败：$($f.Name)"; $problems.Add("reg:$($f.Name)") }
                }
            }
        }
    } else { Say "  注册表还原已关闭（restore.registry=false）" }

    # ---------- 3. 系统设置（时区 / 电源 / 防火墙 / Defender 排除） ----------
    if ($doSystem) {
        $sysFile = Join-Path $Stage "system\system.json"
        if (Test-Path -LiteralPath $sysFile) {
            $sys = $null
            try { $sys = Get-Content -LiteralPath $sysFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }

            if ($sys -and $sys.timezoneId) {
                try { Set-TimeZone -Id $sys.timezoneId -ErrorAction Stop; Say "  时区 -> $($sys.timezoneId)" }
                catch { Warn "时区设置失败：$($sys.timezoneId)（$_）"; $problems.Add("timezone") }
            }
            if ($sys -and $sys.powerPlan) {
                $g = [regex]::Match([string]$sys.powerPlan, '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
                if ($g.Success) {
                    & powercfg.exe /setactive $g.Groups[1].Value 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) { Say "  电源方案 -> $($g.Groups[1].Value)" }
                    else { Warn "电源方案设置失败（该方案可能在全新镜像中不存在）" }
                }
            }
            # 防火墙规则（快照里导出的是 .wfw）
            if ($sys -and $sys.firewallExport) {
                $fwFile = Join-Path $Stage (([string]$sys.firewallExport) -replace '/', '\')
                if (Test-Path -LiteralPath $fwFile) {
                    & netsh.exe advfirewall import "$fwFile" 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) { Say "  防火墙规则已导入" }
                    else { Warn "防火墙规则导入失败（可忽略）"; $problems.Add("firewall") }
                }
            }
            # Defender 排除项
            if ($sys -and $sys.defenderExclusionPath) {
                try {
                    $exPaths = @($sys.defenderExclusionPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                    if ($exPaths.Count -gt 0) {
                        Add-MpPreference -ExclusionPath $exPaths -ErrorAction SilentlyContinue
                        Say ("  Defender 排除路径已恢复：{0} 个" -f $exPaths.Count)
                    }
                    $exProcs = @($sys.defenderExclusionProcess) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                    if ($exProcs.Count -gt 0) { Add-MpPreference -ExclusionProcess $exProcs -ErrorAction SilentlyContinue }
                } catch { Warn "Defender 排除项恢复失败（可忽略）：$_" }
            }
        }
    } else { Say "  系统设置还原已关闭（restore.system=false）" }

    # ---------- 3b. 关闭 Windows 防火墙（本项目要求）----------
    # 注意顺序：快照里的 system/firewall.wfw 若被导入，会**整策略覆盖**把防火墙改回开启，
    # 所以这里在系统设置还原之后**无条件**再关一次（即使有人把 system.firewall 改回 true 也安全）。
    try {
        Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled False -ErrorAction Stop
        Say "  防火墙已关闭（Domain / Private / Public）"
    } catch { Warn "关闭防火墙失败（可忽略）：$_" }

    # ---------- 4. 公共桌面快捷方式 ----------
    if ($doShortcuts) {
        $pubSc = Join-Path $Stage "shortcuts\public-desktop"
        if (Test-Path -LiteralPath $pubSc) {
            $code = Invoke-RobocopyRestore -Src $pubSc -Dst "$env:PUBLIC\Desktop"
            if ($code -lt 8) { Say "  公共桌面快捷方式已还原" }
        }
    } else { Say "  快捷方式还原已关闭（restore.shortcuts=false）" }

    # ---------- 4b. 可移动程序（机器级：只还原「不在用户目录下」的） ----------
    $pmPath = Join-Path $Stage "apps\portable.json"
    if (Test-Path -LiteralPath $pmPath) {
        if (Get-Command Restore-PortableApps -ErrorAction SilentlyContinue) {
            $pr = Restore-PortableApps -ManifestPath $pmPath -UserPrefix ("C:\Users\" + $RdpUser) -InvertScope
            if ($pr.skipped) {
                Say "  可移动程序清单不可用，跳过"
            } else {
                Say ("  可移动程序（机器级）已还原：{0} 个" -f $pr.restored)
                foreach ($pb in @($pr.problems)) { $problems.Add("portable:$pb") }
            }
        } else { Warn "未加载 portable-lib.ps1，跳可移动程序还原" }
    }

    # ---------- 4c. 安装型程序（机器级：只还原「不在用户目录下」的） ----------
    if ($doPrograms) {
        if (Get-Command Restore-Programs -ErrorAction SilentlyContinue) {
            $pgEntries = @(Get-SnapshotPrograms -Stage $Stage)
            if ($pgEntries.Count -gt 0) {
                $pgRes = Restore-Programs -Entries $pgEntries -Stage $Stage -ProgramsRoot $ProgramsRoot `
                            -PreferJunction:$preferJunction -UserPrefix ("C:\Users\" + $RdpUser) -InvertScope `
                            -ExcludePaths $programsExclude
                Say ("  安装型程序（机器级）已还原：{0} 个（{1} 个 junction 指向 D 盘）" -f $pgRes.restored, $pgRes.junctioned)
                foreach ($pb in @($pgRes.problems)) { $problems.Add("program:$pb") }
            }
        } else { Warn "未加载 programs-lib.ps1，跳过安装型程序还原" }
    } else { Say "  安装型程序还原已关闭（programs.enabled=false）" }

    # ---------- 4d. 个人配置预还原（开机即还原，不依赖首次登录任务）----------
    # 做法：先用备用凭据「预创建」该用户的配置文件（userprofile-lib.ps1，内部用
    # Start-Process -Credential **-LoadUserProfile** 真正创建 profile），再 reg load 它的
    # NTUSER.DAT 导入 HKCU，最后 robocopy 个人文件（无 /PURGE）。失败则交给登录任务兜底。
    #
    # ⚠️ 历史坑（真机事故根因）：旧代码写的是
    #     Start-Process ... -Credential $cred -Wait          ← 缺 -LoadUserProfile
    #   -LoadUserProfile 是独立参数、默认 $false，缺了它就等于 LOGON_NETCREDENTIALS_ONLY：
    #   进程起得来、不抛异常，但 profile 根本没被创建 → 用户级数据（Edge User Data /
    #   桌面 / 文档 / .workbuddy）整段静默丢失。详见 userprofile-lib.ps1 头注。
    $userHome    = ("C:\Users\" + $RdpUser)
    $userPreOk   = $false
    if ($doFiles -or $doRegistry) {
        try {
            if ($script:HasUserProfileLib -and (Get-Command Initialize-RdpUserProfile -ErrorAction SilentlyContinue)) {
                $prof = Initialize-RdpUserProfile -RdpUser $RdpUser -Log { param($m) Say ("  " + $m) }
                Say ("  用户配置文件：{0}（方式 {1}）" -f $(if ($prof.ok) { "就绪" } else { "未就绪" }), $prof.method)
                if (-not $prof.ok -and $prof.note) { Warn ("  预创建用户配置文件未成功：{0}" -f $prof.note) }
            } else {
                Warn "  未加载 userprofile-lib.ps1，无法预创建用户配置文件（用户数据可能无法还原）"
            }

            $ntuser = Join-Path $userHome "NTUSER.DAT"
            if (Test-Path -LiteralPath $ntuser) {
                Say "  用户配置文件已创建并注册：$userHome"

                # ① 导入 HKCU
                #    分两种情况（「连接信息提前打印」之后，用户常常已经登录了）：
                #      a) hive 已被 Windows 加载（用户已登录）→ 直接写它的 hive，**绝不 load / 绝不 unload**
                #         （unload 用户正在用的 hive 会让他的会话直接崩）
                #      b) hive 未加载 → 走原路径：reg load 成 HKU\_Restore，写完 unload
                #
                #    ⚠️ 两个形式别混用（实测教训）：
                #      · $hiveRoot    'HKU\...'         → 命令行 reg.exe add/query/delete
                #      · $hiveRegRoot 'HKEY_USERS\...'  → **.reg 文件正文**；
                #        reg import 不认 'HKU\' 前缀（exit=1 且键根本没写进去），必须用全名
                if ($doRegistry) {
                    $regDirU = Join-Path $Stage "registry\user"

                    $hiveRoot    = $null
                    $hiveRegRoot = $null
                    $hiveLoaded  = $false       # $true = 用户自己的 hive，用完不能 unload
                    if ($script:HasUserHiveLib -and (Get-Command Get-UserHiveRoot -ErrorAction SilentlyContinue)) {
                        $hr = Get-UserHiveRoot -RdpUser $RdpUser
                        if ($hr.loaded) {
                            $hiveRoot    = [string]$hr.root
                            $hiveRegRoot = [string]$hr.regRoot
                            $hiveLoaded  = $true
                            Say ("  用户已登录，直接写其 hive：{0}" -f $hiveRoot)
                        }
                    }

                    if (-not $hiveLoaded) {
                        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
                        & reg.exe load "HKU\_Restore" "$ntuser" 2>&1 | Out-Null
                        if ($LASTEXITCODE -eq 0) {
                            $hiveRoot    = "HKU\_Restore"
                            $hiveRegRoot = "HKEY_USERS\_Restore"
                        } else { Warn "  NTUSER.DAT 加载失败（将交给登录任务）" }
                    }

                    if ($hiveRoot -and $hiveRegRoot) {
                        $nU = 0; $nUFail = 0; $nUPartial = 0
                        $partialKeys = New-Object System.Collections.Generic.List[string]
                        foreach ($f in @(Get-ChildItem -LiteralPath $regDirU -Filter *.reg -File -ErrorAction SilentlyContinue)) {
                            try {
                                $txt = Get-Content -LiteralPath $f.FullName -Raw -Encoding Unicode
                                $txt = $txt.Replace(("HKEY_USERS\" + $UserHiveToken), $hiveRegRoot)
                                $tmpR = Join-Path $env:TEMP ("ureg_" + [guid]::NewGuid().ToString('N') + ".reg")
                                $txt | Out-File -LiteralPath $tmpR -Encoding Unicode -Force
                                if ($script:HasRegImportLib) {
                                    $riU = Invoke-RegImportTolerant -RegFile $tmpR
                                    if ($riU.ok) { $nU++ }
                                    elseif ($riU.partial) {
                                        # 部分成功 = 数据基本已还原（保护键/占用键写不进属正常）
                                        $nUPartial++
                                        foreach ($k in @($riU.failedKeys)) { $partialKeys.Add($k) }
                                    } else { $nUFail++ }
                                } else {
                                    & reg.exe import "$tmpR" 2>&1 | Out-Null
                                    if ($LASTEXITCODE -eq 0) { $nU++ } else { $nUFail++ }
                                }
                                Remove-Item -LiteralPath $tmpR -Force -ErrorAction SilentlyContinue
                            } catch { $nUFail++ }
                        }
                        if (-not $hiveLoaded) {
                            [gc]::Collect(); [gc]::WaitForPendingFinalizers()
                            & reg.exe unload "HKU\_Restore" 2>&1 | Out-Null
                        }
                        Say ("  个人 HKCU 已导入：{0} 个键文件（{1}）" -f $nU, $(if ($hiveLoaded) { "写入已加载 hive" } else { "临时 load/unload" }))
                        # 部分成功（系统保护键/占用键写不进）只告警，不算失败
                        if ($nUPartial -gt 0) {
                            Warn ("  个人 HKCU 有 {0} 个键文件部分导入（系统保护/占用键，属正常）：{1}" -f `
                                  $nUPartial, (Format-RegFailedKeys $partialKeys.ToArray()))
                        }
                        # 不再静默：导入失败必须可见（曾因前缀写错导致整批静默失败）
                        if ($nUFail -gt 0) {
                            Warn ("  个人 HKCU 有 {0} 个键文件导入失败（检查 .reg 前缀是否 HKEY_USERS\ 全名）" -f $nUFail)
                            $problems.Add("user-hkcu-import")
                        }
                    }
                }

                # ② 还原个人文件（无 /PURGE）+ 个人快捷方式
                if ($doFiles) {
                    $uPrefixMirror = ("C\Users\" + $RdpUser).ToLower()
                    $nF = 0
                    foreach ($e in @($mf.files.entries)) {
                        $relU = [string]$e.mirror
                        if ([string]::IsNullOrWhiteSpace($relU)) { continue }
                        if (-not $relU.ToLower().StartsWith($uPrefixMirror)) { continue }
                        $srcU = Join-Path (Join-Path $Stage "files") $relU
                        if (-not (Test-Path -LiteralPath $srcU)) { continue }
                        $dstU = Get-AbsFromMirror -Rel $relU
                        $codeU = Invoke-RobocopyRestore -Src $srcU -Dst $dstU
                        if ($codeU -ge 8) { $problems.Add("user-pre:$relU"); Warn "  预还原失败：$relU" }
                        else { $nF++; Say "  预还原 $relU" }
                    }
                    foreach ($pairU in @(
                        @{ src = "shortcuts\user-desktop";   dst = (Join-Path $userHome "Desktop") },
                        @{ src = "shortcuts\user-startmenu"; dst = (Join-Path $userHome "AppData\Roaming\Microsoft\Windows\Start Menu") }
                    )) {
                        $sU = Join-Path $Stage $pairU.src
                        if (Test-Path -LiteralPath $sU) {
                            $codeU2 = Invoke-RobocopyRestore -Src $sU -Dst $pairU.dst
                            if ($codeU2 -lt 8) { Say "  预还原快捷方式 -> $($pairU.dst)" }
                        }
                    }
                    Say ("  个人文件预还原：{0} 个目录" -f $nF)
                }

                # ③ 属主交回该用户
                try {
                    & icacls.exe "$userHome" /setowner "$RdpUser" /T /C /Q 2>&1 | Out-Null
                    & icacls.exe "$userHome" /grant "$($RdpUser):(OI)(CI)F" /T /C /Q 2>&1 | Out-Null
                } catch { }
                $userPreOk = $true
            } else {
                # 这一步失败 = 用户级数据（Edge User Data / 桌面 / 文档 / .workbuddy）本次全部落空，
                # 绝不能只留一行日志：计入 problems → SNAPSHOT_STATUS 变 PARTIAL，汇总里可见。
                $problems.Add("user-profile-missing")
                Warn "  用户配置文件未创建成功（将交给登录任务）—— 用户级数据本次未还原"
            }
        } catch { Warn "开机预还原个人配置失败（将交给登录任务）：$_"; $problems.Add("user-prerestore-failed") }
    }
    Set-GhEnv ("SNAPSHOT_USER_PRERESTORE=" + $(if ($userPreOk) { "OK" } else { "SKIPPED" }))

    # ---------- 4e. 快捷方式校验与修复（必须在程序还原之后）----------
    # 为什么必须在这里：4b/4c 还原程序时会建 junction 让「原安装路径」重新可用；
    # 若在此之前校验，会把好链误判为死链。修不好的移入「_失效快捷方式」文件夹（非破坏）。
    $scCfg        = Get-Cfg $cfg 'shortcuts' $null
    $doScValidate = [bool](Get-Cfg $scCfg 'validateOnRestore' $true)
    if ($doScValidate) {
        if (Get-Command Repair-Shortcuts -ErrorAction SilentlyContinue) {
            $scParkFolder = [string](Get-Cfg $scCfg 'parkFolder' '_失效快捷方式')
            if ([string]::IsNullOrWhiteSpace($scParkFolder)) { $scParkFolder = '_失效快捷方式' }
            $scParkBroken = [bool](Get-Cfg $scCfg 'parkBroken' $true)
            $scDirsToCheck = New-Object System.Collections.Generic.List[string]
            $scDirsToCheck.Add("$env:PUBLIC\Desktop")
            if ([bool](Get-Cfg $scCfg 'machineStartMenu' $false)) { $scDirsToCheck.Add("$env:ProgramData\Microsoft\Windows\Start Menu") }
            try {
                $scRes = Repair-Shortcuts -Dirs $scDirsToCheck.ToArray() `
                            -ProgramsManifestPath (Join-Path $Stage "programs\programs.json") `
                            -AdditionalDirs @($env:CLOUDRDP_DATA_DIR, $PortableDir, $ProgramsRoot) `
                            -Stage $Stage `
                            -ParkFolder $scParkFolder -ParkBroken:$scParkBroken
                Say ("  快捷方式校验（公共桌面）：检查 {0} / 正常 {1} / 修复 {2} / 移入失效 {3} / 暂缓 {4} / 跳过 {5}" -f `
                     $scRes.checked, $scRes.ok, $scRes.repaired, $scRes.parked, $scRes.parkDeferred, $scRes.skipped)
                Set-GhEnv ("SNAPSHOT_SC_CHECKED="  + $scRes.checked)
                Set-GhEnv ("SNAPSHOT_SC_REPAIRED=" + $scRes.repaired)
                Set-GhEnv ("SNAPSHOT_SC_PARKED="   + $scRes.parked)
                Set-GhEnv ("SNAPSHOT_SC_PARKDEFER=" + $scRes.parkDeferred)
                Set-GhEnv ("SHORTCUTS_CHECKED="    + $scRes.checked)
                Set-GhEnv ("SHORTCUTS_REPAIRED="   + $scRes.repaired)
                Set-GhEnv ("SHORTCUTS_PARKED="     + $scRes.parked)
                Set-GhEnv ("SHORTCUTS_PARKDEFER="  + $scRes.parkDeferred)
            } catch { Warn "  快捷方式校验失败（可忽略）：$_" }
        } else { Warn "  未加载 programs-lib.ps1，跳过快捷方式校验" }
    } else { Say "  快捷方式校验已关闭（shortcuts.validateOnRestore=false）" }

    # ---------- 5. 注册「首次登录还原个人配置」计划任务 ----------
    if (-not $NoTask) {
        try {
            $toolsDir  = Join-Path $Stage "_tools"
            $userScript = Join-Path $toolsDir "restore-snapshot.ps1"
            if (-not (Test-Path -LiteralPath $userScript)) {
                # 兜底：把当前脚本自身复制过去
                Copy-Item -LiteralPath $PSCommandPath -Destination $userScript -Force -ErrorAction SilentlyContinue
            }
            $cfgSrc = Join-Path $toolsDir "snapshot-config.json"
            if (-not (Test-Path -LiteralPath $cfgSrc) -and (Test-Path -LiteralPath $ConfigPath)) {
                Copy-Item -LiteralPath $ConfigPath -Destination $cfgSrc -Force -ErrorAction SilentlyContinue
            }
            # 共享库也要在 _tools 里，否则登录任务跑的 user 作用域会因缺库而静默降级。
            # 用 glob「所有 *-lib.ps1」而不是硬编码清单 —— 硬编码清单曾漏掉 userdata-lib.ps1。
            foreach ($lib in @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter "*-lib.ps1" -File -ErrorAction SilentlyContinue)) {
                $libDst = Join-Path $toolsDir $lib.Name
                if (-not (Test-Path -LiteralPath $libDst)) {
                    Copy-Item -LiteralPath $lib.FullName -Destination $libDst -Force -ErrorAction SilentlyContinue
                }
            }

            $psExe = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
            if (-not $psExe) { $psExe = (Get-Command powershell.exe -ErrorAction Stop).Source }

            $argStr = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Scope user -RdpUser "{1}" -Stage "{2}"' -f $userScript, $RdpUser, $Stage
            $action    = New-ScheduledTaskAction -Execute $psExe -Argument $argStr
            $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $RdpUser
            $principal = New-ScheduledTaskPrincipal -UserId $RdpUser -LogonType Interactive -RunLevel Highest
            $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                            -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -StartWhenAvailable
            Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
                -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
            Say "已注册登录还原任务：$TaskName（$RdpUser 首次登录时执行）"

            # 用户**已经登录**时，「登录时触发」不会再发生 —— 立刻手动触发一次。
            # 任务以该用户 Interactive 身份运行，用的是他自己的 HKCU（不需要 reg load），
            # 跑完会 Unregister-ScheduledTask 自注销，所以不会重复执行。
            $alreadyLoggedIn = $false
            if ($script:HasUserHiveLib -and (Get-Command Get-UserHiveRoot -ErrorAction SilentlyContinue)) {
                $hrTask = Get-UserHiveRoot -RdpUser $RdpUser
                $alreadyLoggedIn = [bool]$hrTask.loaded
            }
            if ($alreadyLoggedIn) {
                try {
                    Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
                    Say "  用户已登录 → 已立即触发用户级还原任务（不等下次登录）"
                    Set-GhEnv "SNAPSHOT_USER_TASK_RUN=TRIGGERED"
                } catch {
                    Warn "  用户已登录但触发还原任务失败：$_（个人配置可能不完整）"
                    $problems.Add("logon-task-run")
                    Set-GhEnv "SNAPSHOT_USER_TASK_RUN=FAILED"
                }
            } else {
                Set-GhEnv "SNAPSHOT_USER_TASK_RUN=WAIT_LOGON"
            }
        } catch {
            Warn "注册登录还原任务失败：$_（个人配置将无法自动还原）"
            $problems.Add("logon-task")
        }
    }

    $status = if ($problems.Count -eq 0) { "OK" } else { "PARTIAL" }
    Say ("机器级还原完成：{0} 个目录 | 状态 {1}" -f $restored, $status)
    Set-GhEnv ("SNAPSHOT_STATUS=" + $status)
    Set-GhEnv ("SNAPSHOT_RESTORED_DIRS=" + $restored)
    if ($problems.Count -gt 0) { Set-GhEnv ("SNAPSHOT_PROBLEMS=" + ($problems -join ',')) }

    # 取证：Edge 配置/历史/收藏夹 + .workbuddy-ai 是否真的回来了
    # （个人目录由 user 作用域还原，这里只当「早测」；登录任务的日志里有最终结论）
    # -ProbeCrypt 仅在 profile 就绪时做：这时 Edge 数据是刚从快照铺回来的、且 Edge 还没启动，
    # 探到的是「快照里那把密钥能不能在本机解开」——即密码/Cookie 到底能不能用。
    Write-RestoreEvidence -RdpUser $RdpUser -Stage $Stage -ConfigPath $ConfigPath -LogPath (Join-Path $SysDir "_state\user-restore.log") -ProbeCrypt:$userPreOk | Out-Null
}

# ================================================================ user 作用域

function Import-UserRegFile {
    param([string]$RegFile)
    $res = [ordered]@{ ok = $false; partial = $false; failed = $true; failedKeys = @(); blocks = 0; failedN = 0 }
    $txt = Get-Content -LiteralPath $RegFile -Raw -Encoding Unicode
    if (-not $txt) { return $res }
    # 用户已登录：HKCU 即其 hive，把占位符换成 HKEY_CURRENT_USER 直接导入
    $txt = $txt.Replace(("HKEY_USERS\" + $UserHiveToken), "HKEY_CURRENT_USER")
    $tmp = Join-Path $env:TEMP ("snapreg_" + [guid]::NewGuid().ToString("N") + ".reg")
    $txt | Out-File -LiteralPath $tmp -Encoding Unicode -Force
    if ($script:HasRegImportLib) {
        $ri = Invoke-RegImportTolerant -RegFile $tmp
        $res.ok = $ri.ok; $res.partial = $ri.partial; $res.failed = $ri.failed
        $res.failedKeys = $ri.failedKeys; $res.blocks = $ri.blocks; $res.failedN = $ri.failedN
    } else {
        & reg.exe import "$tmp" 2>&1 | Out-Null
        $res.ok = ($LASTEXITCODE -eq 0)
        $res.failed = (-not $res.ok)
    }
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    return $res
}

function Invoke-UserRestore {
    param([string]$Stage, [string]$RdpUser)

    $manifestPath = Join-Path $Stage "manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) { Say "无快照，跳过个人配置还原"; return }
    try { $mf = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Warn "manifest 解析失败"; return }
    if ($mf.rdpUser) { $RdpUser = $mf.rdpUser }

    Say "以 $env:USERNAME 身份还原个人配置（快照用户 $RdpUser）"
    $problems = New-Object System.Collections.Generic.List[string]
    $restored = 0

    # ---------- 1. 个人目录文件 ----------
    $userPrefix = ("C\Users\" + $RdpUser).ToLower()
    # 个人文件里就有 Edge User Data 与 .workbuddy-ai —— 这两个正是最容易被占用而覆盖失败的目标
    Invoke-RestoreQuiesce -ConfigPath $ConfigPath | Out-Null
    if ($doFiles) {
        foreach ($e in @($mf.files.entries)) {
            $rel = [string]$e.mirror
            if ([string]::IsNullOrWhiteSpace($rel)) { continue }
            if (-not $rel.ToLower().StartsWith($userPrefix)) { continue }

            $src = Join-Path (Join-Path $Stage "files") $rel
            $dst = Get-AbsFromMirror -Rel $rel
            $code = Invoke-RobocopyRestore -Src $src -Dst $dst
            if ($code -ge 8) { $problems.Add("file:$rel"); Warn "还原失败：$rel" }
            else { $restored++; Say "  还原 $rel" }
        }
    } else { Say "  文件还原已关闭（restore.files=false）" }

    # ---------- 2. HKCU 注册表 ----------
    if ($doRegistry) {
        $regDir = Join-Path $Stage "registry\user"
        if (Test-Path -LiteralPath $regDir) {
            foreach ($f in @(Get-ChildItem -LiteralPath $regDir -Filter *.reg -File -ErrorAction SilentlyContinue)) {
                $riu = Import-UserRegFile -RegFile $f.FullName
                if ($riu.ok) {
                    Say "  导入 HKCU 注册表 $($f.Name)"
                } elseif ($riu.partial) {
                    # 部分成功 = 数据基本已还原：Windows 保护键（默认程序关联 UserChoice）
                    # 与被系统进程占用的键（Feeds/Search）永远写不进，属正常，不计失败
                    Warn ("  HKCU 部分导入 {0}：{1}/{2} 块失败（系统保护/占用键，属正常）—— {3}" -f `
                          $f.Name, $riu.failedN, $riu.blocks, (Format-RegFailedKeys $riu.failedKeys))
                } else {
                    Warn "HKCU 导入失败：$($f.Name)"; $problems.Add("reg:$($f.Name)")
                }
            }
        }
    } else { Say "  HKCU 还原已关闭（restore.registry=false）" }

    # ---------- 3. 个人快捷方式 ----------
    if ($doShortcuts) {
        foreach ($pair in @(
            @{ src = "shortcuts\user-desktop";    dst = (Join-Path $env:USERPROFILE "Desktop") },
            @{ src = "shortcuts\user-startmenu";  dst = (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu") }
        )) {
            $s = Join-Path $Stage $pair.src
            if (Test-Path -LiteralPath $s) {
                $code = Invoke-RobocopyRestore -Src $s -Dst $pair.dst
                if ($code -lt 8) { Say "  快捷方式已还原 -> $($pair.dst)" }
            }
        }
    } else { Say "  快捷方式还原已关闭（restore.shortcuts=false）" }

    # ---------- 3b. 可移动程序（用户级：只还原「在用户目录下」的） ----------
    $pmPath = Join-Path $Stage "apps\portable.json"
    if (Test-Path -LiteralPath $pmPath) {
        if (Get-Command Restore-PortableApps -ErrorAction SilentlyContinue) {
            $pr = Restore-PortableApps -ManifestPath $pmPath -UserPrefix $env:USERPROFILE
            if (-not $pr.skipped) {
                Say ("  可移动程序（用户级）已还原：{0} 个" -f $pr.restored)
                foreach ($pb in @($pr.problems)) { $problems.Add("portable:$pb") }
            }
        }
    }

    # ---------- 3c. 安装型程序（用户级：只还原「在用户目录下」的） ----------
    if ($doPrograms) {
        if (Get-Command Restore-Programs -ErrorAction SilentlyContinue) {
            $pgEntries = @(Get-SnapshotPrograms -Stage $Stage)
            if ($pgEntries.Count -gt 0) {
                $pgRes = Restore-Programs -Entries $pgEntries -Stage $Stage -ProgramsRoot $ProgramsRoot `
                            -PreferJunction:$preferJunction -UserPrefix $env:USERPROFILE `
                            -ExcludePaths $programsExclude
                Say ("  安装型程序（用户级）已还原：{0} 个（{1} 个 junction）" -f $pgRes.restored, $pgRes.junctioned)
                foreach ($pb in @($pgRes.problems)) { $problems.Add("program:$pb") }
            }
        }
    }

    # ---------- 3d. 快捷方式校验与修复（用户级：桌面 + 开始菜单；必须在程序还原之后）----------
    $scCfgU        = Get-Cfg $cfg 'shortcuts' $null
    $doScValidateU = [bool](Get-Cfg $scCfgU 'validateOnRestore' $true)
    if ($doScValidateU) {
        if (Get-Command Repair-Shortcuts -ErrorAction SilentlyContinue) {
            $scParkFolderU = [string](Get-Cfg $scCfgU 'parkFolder' '_失效快捷方式')
            if ([string]::IsNullOrWhiteSpace($scParkFolderU)) { $scParkFolderU = '_失效快捷方式' }
            $scParkBrokenU = [bool](Get-Cfg $scCfgU 'parkBroken' $true)
            $scDirsU = New-Object System.Collections.Generic.List[string]
            $scDirsU.Add((Join-Path $env:USERPROFILE "Desktop"))
            $scDirsU.Add((Join-Path $env:APPDATA "Microsoft\Windows\Start Menu"))
            try {
                $scResU = Repair-Shortcuts -Dirs $scDirsU.ToArray() `
                            -ProgramsManifestPath (Join-Path $Stage "programs\programs.json") `
                            -AdditionalDirs @($env:CLOUDRDP_DATA_DIR, $PortableDir, $ProgramsRoot) `
                            -Stage $Stage `
                            -ParkFolder $scParkFolderU -ParkBroken:$scParkBrokenU `
                            -LogPath (Join-Path $SysDir "_state\user-restore.log")
                Say ("  快捷方式校验（个人）：检查 {0} / 正常 {1} / 修复 {2} / 移入失效 {3} / 暂缓 {4} / 跳过 {5}" -f `
                     $scResU.checked, $scResU.ok, $scResU.repaired, $scResU.parked, $scResU.parkDeferred, $scResU.skipped)
                Set-GhEnv ("SHORTCUTS_CHECKED="  + $scResU.checked)
                Set-GhEnv ("SHORTCUTS_REPAIRED=" + $scResU.repaired)
                Set-GhEnv ("SHORTCUTS_PARKED="   + $scResU.parked)
                Set-GhEnv ("SHORTCUTS_PARKDEFER=" + $scResU.parkDeferred)
            } catch { Warn "  快捷方式校验失败（可忽略）：$_" }
        }
    }

    # ---------- 4. .ssh 私钥权限收紧 ----------
    $sshDir = Join-Path $env:USERPROFILE ".ssh"
    if (Test-Path -LiteralPath $sshDir) {
        try {
            & icacls.exe "$sshDir" /inheritance:r /grant:r "$($env:USERNAME):(OI)(CI)F" 2>&1 | Out-Null
            Say "  .ssh 权限已收紧"
        } catch { Warn ".ssh 权限设置失败（$_）" }
    }

    # ---------- 5. 刷新壁纸/外观 ----------
    try { & rundll32.exe user32.dll,UpdatePerUserSystemParameters 2>&1 | Out-Null } catch { }

    $status = if ($problems.Count -eq 0) { "OK" } else { "PARTIAL" }
    Say ("个人配置还原完成：{0} 个目录 | 状态 {1}" -f $restored, $status)

    # ---------- 5b. 日志落盘（用户会话里看不到控制台，便于事后排查）----------
    try {
        $logDir = Join-Path $SysDir "_state"
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        ("[{0}] status={1} restored={2} problems={3}" -f (Get-Date).ToString('o'), $status, $restored, (($problems | Select-Object -First 20) -join ',')) |
            Out-File -LiteralPath (Join-Path $logDir "user-restore.log") -Append -Encoding utf8
    } catch { }

    # ---------- 5c. 取证：Edge 配置/历史/收藏夹 + .workbuddy-ai 是否真的回来了 ----------
    # 这里是权威结论（个人目录就是在 user 作用域还原的）。光看「还原了几个目录」
    # 发现不了「Edge 历史缺了」「程序本体没回来」这类静默漏项。
    try { Write-RestoreEvidence -RdpUser $RdpUser -Stage $Stage -ConfigPath $ConfigPath -LogPath (Join-Path $SysDir "_state\user-restore.log") -ProbeCrypt | Out-Null } catch { }

    # ---------- 6. 只在成功时自注销；失败则保留任务，下次登录自动重试 ----------
    if ($problems.Count -eq 0) {
        try {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
            Say "已注销登录还原任务（仅执行一次）"
        } catch { Warn "注销登录任务失败：$_" }
        try {
            $mkOk = Join-Path $env:PUBLIC "Desktop\_CloudRDP_还原失败.txt"
            if (Test-Path -LiteralPath $mkOk) { Remove-Item -LiteralPath $mkOk -Force -ErrorAction SilentlyContinue }
        } catch { }
    } else {
        Warn ("个人配置还原有 {0} 项问题 —— 保留登录任务，下次登录自动重试" -f $problems.Count)
        try {
            $mkBad = Join-Path $env:PUBLIC "Desktop\_CloudRDP_还原失败.txt"
            $body = "个人配置还原失败`r`n时间: {0}`r`n问题:`r`n{1}`r`n`r`n日志: {2}\_state\user-restore.log`r`n手动重试:`r`n  {2}\_snapshot\_tools\restore-snapshot.ps1 -Scope user" -f `
                (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'),
                (($problems | ForEach-Object { "  - $_" }) -join "`r`n"),
                $SysDir
            $body | Out-File -LiteralPath $mkBad -Encoding UTF8
        } catch { }
    }
}

# ================================================================ 入口

if ($Scope -eq "machine") {
    if ($Pull) {
        $r = Invoke-PullSnapshot -Remote $Remote -Stage $Stage
        if ($r -eq "EMPTY") {
            Say "远端尚无快照（首次运行正常）"
            Set-GhEnv "SNAPSHOT_STATUS=EMPTY"
            exit 0
        }
        if ($r -eq "FAILED" -or $r -eq "NO_RCLONE") {
            Warn "快照拉取失败：$r —— 本次不做整机还原（RDP 仍可用，但环境是全新的）"
            Set-GhEnv "SNAPSHOT_STATUS=FAILED"
            exit 0
        }
    }
    Invoke-MachineRestore -Stage $Stage -RdpUser $RdpUser -ConfigPath $ConfigPath -NoTask:$NoTask
}
else {
    Invoke-UserRestore -Stage $Stage -RdpUser $RdpUser
}

exit 0
