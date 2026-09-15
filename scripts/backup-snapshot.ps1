<#
.SYNOPSIS
  抓取「整机状态快照」：文件树 + 注册表 + 已装软件清单 + 系统设置 + 快捷方式，
  落到 C:\_snapshot，并可选推送到 139 云盘 alist:/cloudrdp/_snapshot。

.DESCRIPTION
  GitHub Actions runner 是一次性全新 VM，没有镜像级快照能力，所以「复刻关机前的机器」
  必须靠自己抓取 + 自己还原。本脚本负责「抓取」这一半。

  与 sync-up.ps1 的分工：
    sync-up.ps1         → 只推 C:\data（用户数据，每 10 分钟，高频）
    backup-snapshot.ps1 → 抓整机状态（文件/注册表/软件/设置/快捷方式），开机基线 + 每 60 分钟 + 收尾

  快照目录结构（C:\_snapshot）：
    manifest.json            元信息：时间/主机/条目/大小/状态
    files\C\...              文件镜像（按绝对路径，C:\data → files\C\data）
    registry\user\*.reg      用户 HKCU 子键（已把 SID 归一化为 __RDPUSER__ 占位符）
    registry\machine\*.reg   机器级注册表键
    apps\winget-export.json  已装软件清单（winget 可重装）
    apps\installed-apps.json 注册表 Uninstall 扫描结果
    system\system.json       时区/区域/电源方案/壁纸路径
    shortcuts\*.lnk          桌面与开始菜单快捷方式
    _tools\                  供开机还原用的脚本副本（restore-snapshot.ps1 / snapshot-config.json）

.PARAMETER Stage    本地暂存目录，默认 C:\_snapshot
.PARAMETER Remote   139 侧目标路径，默认 alist:/cloudrdp/_snapshot
.PARAMETER ConfigPath 清单配置文件路径
.PARAMETER RdpUser  目标 RDP 用户名（用于解析 %RDPUSERPROFILE% 与导出其 HKCU）
.PARAMETER Push     抓取完成后推送到远端
.PARAMETER Quick    快速模式：跳过软件清单扫描（winget/uninstall），用于高频周期备份

.NOTES
  本脚本永不返回非 0（不阻断 RDP）。结果通过 GITHUB_ENV 透出：
    SNAPSHOT_STATUS = OK | PARTIAL | FAILED | SKIPPED
    SNAPSHOT_FILES / SNAPSHOT_MB / SNAPSHOT_ENTRIES
#>
[CmdletBinding()]
param(
    [string]$Stage      = $(if ($env:CLOUDRDP_SNAPSHOT_STAGE) { $env:CLOUDRDP_SNAPSHOT_STAGE } elseif (Test-Path 'D:\') { "D:\cloudrdp-sys\_snapshot" } else { "C:\_snapshot" }),
    [string]$Remote     = $(if ($env:CLOUDRDP_REMOTE_BASE) { $env:CLOUDRDP_REMOTE_BASE + "/_snapshot" } else { "alist:/cloudrdp/AI文件库/_snapshot" }),
    [string]$ConfigPath = (Join-Path $PSScriptRoot "snapshot-config.json"),
    [string]$RdpUser    = $(if ($env:RDP_USERNAME) { $env:RDP_USERNAME } else { "NvdAdmin" }),
    [switch]$Push,
    [switch]$Quick
)

$ErrorActionPreference = "Continue"
$SysDir          = if ($env:CLOUDRDP_SYS_DIR) { $env:CLOUDRDP_SYS_DIR } elseif (Test-Path 'D:\') { "D:\cloudrdp-sys" } else { "C:\cloudrdp-sys" }
$RcloneExe       = Join-Path $SysDir "rclone\rclone.exe"
$SnapshotVersion = 3
$UserHiveToken   = "__RDPUSER__"     # 归一化后的 HKCU 占位符，还原时按当前 SID 替换
$PortableDir     = $(if ($env:CLOUDRDP_PORTABLE_DIR) { $env:CLOUDRDP_PORTABLE_DIR } else { "D:\a\cloud-rdp\_portable" })

# 可移动程序共享库（识别 / 搬运 / 还原）
$portableLib = Join-Path $PSScriptRoot "portable-lib.ps1"
if (Test-Path -LiteralPath $portableLib) { . $portableLib }
else { Write-Warning "[snapshot] 未找到 portable-lib.ps1，可移动程序功能不可用" }

# 安装型程序共享库（识别 / 备份 / 还原）
$programsLib = Join-Path $PSScriptRoot "programs-lib.ps1"
if (Test-Path -LiteralPath $programsLib) { . $programsLib }
else { Write-Warning "[snapshot] 未找到 programs-lib.ps1，安装型程序复刻不可用" }

function Set-GhEnv([string]$kv) {
    if ($env:GITHUB_ENV) { $kv | Out-File $env:GITHUB_ENV -Append -Encoding ascii }
}
function Say([string]$m)  { Write-Host "[snapshot] $m" }
function Warn([string]$m) { Write-Warning "[snapshot] $m" }

# ---------------------------------------------------------------- 路径工具

function Expand-SnapPath {
    param([string]$Path, [string]$RdpUser)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    $r = $Path
    $r = $r -replace '%RDPUSERPROFILE%', ("C:\Users\" + $RdpUser)
    $r = $r -replace '%RDPUSER%', $RdpUser
    $r = [System.Environment]::ExpandEnvironmentVariables($r)
    return $r
}

# C:\Users\NvdAdmin\Desktop -> C\Users\NvdAdmin\Desktop
function Get-MirrorRel {
    param([string]$Abs)
    $a = $Abs.TrimEnd('\')
    $a = $a -replace '^([A-Za-z]):', '$1'
    $a = $a -replace '^[\\/]+', ''
    return $a
}

# C\Users\NvdAdmin\Desktop -> C:\Users\NvdAdmin\Desktop
function Get-AbsFromMirror {
    param([string]$Rel)
    $parts = $Rel -split '[\\/]'
    if ($parts.Count -lt 2) { return ($parts[0] + ":\") }
    $drive = $parts[0]
    $rest  = ($parts[1..($parts.Count - 1)] -join '\')
    return ("{0}:\{1}" -f $drive, $rest)
}

# robocopy 返回 0..7 都算成功，>=8 才是真失败
function Invoke-Robocopy {
    param([string]$Src, [string]$Dst, [string[]]$ExcludeDirs, [string[]]$ExcludeFiles)
    if (-not (Test-Path -LiteralPath $Src)) { return -1 }   # -1 = 源不存在
    New-Item -ItemType Directory -Force -Path $Dst | Out-Null
    $rc = @($Src, $Dst, '/E', '/COPY:DAT', '/R:1', '/W:1',
            '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/XJ', '/XO')
    if ($ExcludeDirs  -and $ExcludeDirs.Count  -gt 0) { $rc += '/XD'; $rc += $ExcludeDirs }
    if ($ExcludeFiles -and $ExcludeFiles.Count -gt 0) { $rc += '/XF'; $rc += $ExcludeFiles }
    & robocopy @rc 2>&1 | Out-Null
    return $LASTEXITCODE
}

function Get-TreeSize {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @{ Files = 0; Bytes = 0 } }
    $items = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)
    $sum = ($items | Measure-Object -Property Length -Sum).Sum
    if (-not $sum) { $sum = 0 }
    return @{ Files = $items.Count; Bytes = [long]$sum }
}

# ---------------------------------------------------------------- 用户 HKCU 导出
# 关键难点：runner 以 runneradmin 身份运行，而 RDP 用户是 NvdAdmin，
# 二者 HKCU 不同。需要直接读 NvdAdmin 的 NTUSER.DAT。
# 导出后把 HKEY_USERS\<SID或临时名> 归一化成 HKEY_USERS\__RDPUSER__，
# 避免换机后 SID 变化导致还原时写错位置。

function Get-RdpUserSid {
    param([string]$RdpUser)
    try { return (Get-LocalUser -Name $RdpUser -ErrorAction Stop).SID.Value } catch { return $null }
}

function Export-UserHiveSubKey {
    param([string]$SubKey, [string]$OutFile, [string]$RdpUser, [string]$Token)

    $sid       = Get-RdpUserSid -RdpUser $RdpUser
    $profileD  = "C:\Users\$RdpUser"
    $ntuser    = Join-Path $profileD "NTUSER.DAT"

    $root     = $null
    $weLoaded = $false
    $loadName = "_SnapTmpHive"

    if ($sid -and (Test-Path -LiteralPath ("Registry::HKEY_USERS\" + $sid))) {
        # 用户当前已登录 —— hive 已挂载，直接导出
        $root = "HKU\$sid"
    }
    elseif (Test-Path -LiteralPath $ntuser) {
        & reg.exe load ("HKU\" + $loadName) "$ntuser" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $root = "HKU\$loadName"; $weLoaded = $true }
    }

    if (-not $root) { Warn "无法访问 $RdpUser 的注册表 hive（未登录且无 NTUSER.DAT），跳过 $SubKey"; return $false }

    $hiveName = $root -replace '^HKU\\', ''
    & reg.exe export ($root + "\" + $SubKey) "$OutFile" /y 2>&1 | Out-Null
    $ok = Test-Path -LiteralPath $OutFile

    if ($weLoaded) {
        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
        & reg.exe unload ("HKU\" + $loadName) 2>&1 | Out-Null
    }

    if ($ok) {
        $txt = Get-Content -LiteralPath $OutFile -Raw -Encoding Unicode
        if ($txt) {
            $txt = $txt.Replace(("HKEY_USERS\" + $hiveName), ("HKEY_USERS\" + $Token))
            $txt | Out-File -LiteralPath $OutFile -Encoding Unicode -Force
        }
    }
    return $ok
}

# ---------------------------------------------------------------- 配置加载

$defaults = @{
    files = @{
        dirs               = @("C:\tools", "%RDPUSERPROFILE%\Desktop", "%RDPUSERPROFILE%\Documents")
        excludeDirNames    = @("node_modules", ".git", "Temp", "tmp", "Cache", "GPUCache")
        excludeFilePatterns= @("*.tmp", "*.temp", "Thumbs.db", "desktop.ini")
        maxTotalMB         = 8192
    }
    registry = @{
        userHiveKeys = @(@{ path = "Software"; name = "HKCU-Software" })
        machineKeys  = @(@{ path = "HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation"; name = "HKLM-TimeZone" })
    }
    apps    = @{ wingetExport = $true; uninstallScan = $true }
    system  = @{ timezone = $true; culture = $true; powerPlan = $true; wallpaper = $true }
    shortcuts = @{ publicDesktop = $true; userDesktop = $true; userStartMenu = $true; machineStartMenu = $false }
}

$cfg = $null
if (Test-Path -LiteralPath $ConfigPath) {
    try { $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Warn "清单配置解析失败（$ConfigPath）：$_，改用内置默认值" }
}
if (-not $cfg) {
    Warn "未找到清单配置，改用内置默认值"
    $cfg = [pscustomobject]@{
        files     = [pscustomobject]$defaults.files
        registry  = [pscustomobject]$defaults.registry
        apps      = [pscustomobject]$defaults.apps
        system    = [pscustomobject]$defaults.system
        shortcuts = [pscustomobject]$defaults.shortcuts
    }
}

function Get-Cfg($obj, $name, $fallback) {
    if ($null -eq $obj) { return $fallback }
    # 兼容两种形态：JSON 反序列化得到的 PSCustomObject，以及内置默认值的 Hashtable
    if ($obj -is [System.Collections.IDictionary]) {
        if ($obj.Contains($name) -and $null -ne $obj[$name]) { return $obj[$name] }
        return $fallback
    }
    $p = $obj.PSObject.Properties[$name]
    if ($null -eq $p -or $null -eq $p.Value) { return $fallback }
    return $p.Value
}

$maxTotalMB = [int](Get-Cfg $cfg.files 'maxTotalMB' 8192)

# ---------------------------------------------------------------- 0. 准备暂存目录

if ($Stage -notmatch '_snapshot') {     # 安全护栏：只允许清理名字里带 _snapshot 的目录
    Warn "拒绝清理非快照目录：$Stage"
    Set-GhEnv "SNAPSHOT_STATUS=FAILED"
    exit 0
}

# ---------- 0a. 用户数据保命（关键）----------
# 问题：本次开机的用户配置文件若不存在（用户从没登录过），本次抓取抓不到任何用户数据；
#       而下面会**整个清空暂存目录**，再配合推送（远端镜像本地）——
#       结果就是「把云端那份桌面/文档/HKCU 删掉」，永久丢失。
# 做法：profile 不存在时，先把上一份快照里的用户子树搬到 holding（放在系统目录，不会被清），
#       清空重建后搬回，并在后面把它们的 manifest 条目合并回去。
# 语义：profile 存在（用户登录过）→ 全量重抓，删除照常生效；不存在 → 保留上一份。
$userProfileExists = Test-Path -LiteralPath ("C:\Users\" + $RdpUser + "\NTUSER.DAT")
$holdDir = Join-Path $SysDir "_hold"
$userSubtrees = @(
    ("files\C\Users\" + $RdpUser),
    "registry\user",
    "shortcuts\user-desktop",
    "shortcuts\user-startmenu"
)
$heldSubtrees = New-Object System.Collections.Generic.List[string]
$prevManifest = $null

if (-not $userProfileExists) {
    $prevManifestPath = Join-Path $Stage "manifest.json"
    if (Test-Path -LiteralPath $prevManifestPath) {
        try { $prevManifest = Get-Content -LiteralPath $prevManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    if (Test-Path -LiteralPath $holdDir) { Remove-Item -LiteralPath $holdDir -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $Stage) {
        New-Item -ItemType Directory -Force -Path $holdDir | Out-Null
        foreach ($rel in $userSubtrees) {
            $srcH = Join-Path $Stage $rel
            if (-not (Test-Path -LiteralPath $srcH)) { continue }
            $dstH = Join-Path $holdDir $rel
            $parentH = Split-Path $dstH -Parent
            if ($parentH) { New-Item -ItemType Directory -Force -Path $parentH | Out-Null }
            try {
                Move-Item -LiteralPath $srcH -Destination $dstH -Force -ErrorAction Stop
                $heldSubtrees.Add($rel)
            } catch { Warn "保留用户数据失败：$rel（$_）" }
        }
    }
    Say ("用户配置文件不存在（C:\Users\{0}）—— 本次保留上一份用户数据：{1} 个子树" -f $RdpUser, $heldSubtrees.Count)
    Set-GhEnv "SNAPSHOT_USER_PRESERVED=YES"
} else {
    Say ("用户配置文件存在（C:\Users\{0}）—— 用户数据全量重抓，删除照常生效" -f $RdpUser)
    Set-GhEnv "SNAPSHOT_USER_PRESERVED=NO"
}

if (Test-Path -LiteralPath $Stage) { Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue }
foreach ($sub in @("files", "registry\user", "registry\machine", "apps", "system", "shortcuts", "_tools")) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Stage $sub) | Out-Null
}

# 把保留的用户子树搬回暂存（合并式：本次新抓到的内容会覆盖同名文件）
foreach ($rel in $heldSubtrees) {
    $srcH = Join-Path $holdDir $rel
    $dstH = Join-Path $Stage $rel
    if (-not (Test-Path -LiteralPath $srcH)) { continue }
    $parentH = Split-Path $dstH -Parent
    if ($parentH) { New-Item -ItemType Directory -Force -Path $parentH | Out-Null }
    & robocopy $srcH $dstH /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP /XJ 2>&1 | Out-Null
}
if ($heldSubtrees.Count -gt 0) { Remove-Item -LiteralPath $holdDir -Recurse -Force -ErrorAction SilentlyContinue }

$mode = if ($Quick) { "quick" } else { "full" }
Say "开始抓取整机快照（模式=$mode）→ $Stage"

$problems  = New-Object System.Collections.Generic.List[string]
$fileEntries = New-Object System.Collections.Generic.List[object]
$regFiles    = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------- 1. 文件树

$exDirs  = @(Get-Cfg $cfg.files 'excludeDirNames' @())
$exFiles = @(Get-Cfg $cfg.files 'excludeFilePatterns' @())
$dirs    = @(Get-Cfg $cfg.files 'dirs' @())

$totalBytes = [long]0
$totalFiles = 0
$skippedDirs = New-Object System.Collections.Generic.List[string]

foreach ($raw in $dirs) {
    $src = Expand-SnapPath -Path $raw -RdpUser $RdpUser
    if (-not (Test-Path -LiteralPath $src)) { continue }     # 不存在就跳过，属正常

    $rel = Get-MirrorRel -Abs $src
    $dst = Join-Path (Join-Path $Stage "files") $rel

    $size = Get-TreeSize -Path $src
    if ($maxTotalMB -gt 0 -and (($totalBytes + $size.Bytes) / 1MB) -gt $maxTotalMB) {
        Warn ("体积上限 {0} MB 已达，跳过后续目录：{1}" -f $maxTotalMB, $src)
        $skippedDirs.Add($src)
        continue
    }

    $code = Invoke-Robocopy -Src $src -Dst $dst -ExcludeDirs $exDirs -ExcludeFiles $exFiles
    if ($code -ge 8) { Warn "robocopy 失败（码 $code）：$src"; $problems.Add("file:$src") }

    $got = Get-TreeSize -Path $dst
    $totalBytes += $got.Bytes
    $totalFiles += $got.Files
    $fileEntries.Add([pscustomobject]@{
        source = $src; originalPath = $src; mirror = $rel; files = $got.Files; bytes = $got.Bytes; robocopy = $code
    })
    Say ("  文件 {0}  ->  {1} 个文件 / {2:N2} MB" -f $src, $got.Files, ($got.Bytes / 1MB))
}

# ---------------------------------------------------------------- 2. 注册表

foreach ($k in @(Get-Cfg $cfg.registry 'userHiveKeys' @())) {
    $name = Get-Cfg $k 'name' ("HKCU-" + (Get-Cfg $k 'path' 'unknown'))
    $out  = Join-Path $Stage ("registry\user\" + $name + ".reg")
    if (Export-UserHiveSubKey -SubKey (Get-Cfg $k 'path' '') -OutFile $out -RdpUser $RdpUser -Token $UserHiveToken) {
        $regFiles.Add("registry\user\$name.reg")
        Say "  注册表 HKCU\$($k.path)  ->  $name.reg"
    }
}

foreach ($k in @(Get-Cfg $cfg.registry 'machineKeys' @())) {
    $name = Get-Cfg $k 'name' ("HKLM-" + (Get-Cfg $k 'path' 'unknown'))
    $out  = Join-Path $Stage ("registry\machine\" + $name + ".reg")
    & reg.exe export (Get-Cfg $k 'path' '') "$out" /y 2>&1 | Out-Null
    if ((Test-Path -LiteralPath $out) -and $LASTEXITCODE -eq 0) {
        $regFiles.Add("registry\machine\$name.reg")
        Say "  注册表 $($k.path)  ->  $name.reg"
    } else {
        Warn "注册表导出失败：$($k.path)"
    }
}

# ---------------------------------------------------------------- 3. 已装软件清单

$installedApps    = @()
$portableCaptured = @()
$wingetCount      = 0

if (-not $Quick) {
    if ([bool](Get-Cfg $cfg.apps 'wingetExport' $true)) {
        $wg = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($wg) {
            $out = Join-Path $Stage "apps\winget-export.json"
            & winget.exe export -o "$out" --include-versions --accept-source-agreements 2>&1 | Out-Null
            if (Test-Path -LiteralPath $out) {
                Say "  winget 清单已导出"
                try {
                    $we = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json
                    $ids = @()
                    foreach ($src in @($we.Sources)) { foreach ($p in @($src.Packages)) { if ($p.PackageIdentifier) { $ids += [string]$p.PackageIdentifier } } }
                    $wingetCount = @($ids | Select-Object -Unique).Count
                    Say ("  winget 包数：{0}" -f $wingetCount)
                } catch { Warn "winget 清单解析失败（可忽略）" }
            }
            else { Warn "winget export 失败（可忽略）" }
        } else { Warn "未找到 winget，跳过软件清单导出" }
    }

    if ([bool](Get-Cfg $cfg.apps 'uninstallScan' $true)) {
        $paths = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        $installedApps = @(
            foreach ($p in $paths) {
                Get-ItemProperty -Path $p -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName } |
                    Select-Object DisplayName, DisplayVersion, Publisher, InstallLocation, UninstallString,
                                  WindowsInstaller, SystemComponent, ParentKeyName, ReleaseType
            }
        )
        $installedApps = @($installedApps | Sort-Object DisplayName -Unique)
        $installedApps | ConvertTo-Json -Depth 4 | Out-File -LiteralPath (Join-Path $Stage "apps\installed-apps.json") -Encoding UTF8
        Say ("  已装软件扫描：{0} 项" -f $installedApps.Count)
    }
}

# ---------------------------------------------------------------- 3b. 可移动程序（识别 + 搬运）

$portableCfg     = Get-Cfg $cfg 'portable' $null
$portableEnabled = [bool](Get-Cfg $portableCfg 'enabled' $true)
$portableInQuick = [bool](Get-Cfg $portableCfg 'captureInQuick' $false)
$doPortable      = $portableEnabled -and ((-not $Quick) -or $portableInQuick)

if (-not $portableEnabled) {
    Say "  可移动程序：已关闭（portable.enabled=false）"
}
elseif (-not $doPortable) {
    Say "  可移动程序：quick 模式跳过（portable.captureInQuick=false）"
}
elseif (-not (Get-Command Get-PortableApps -ErrorAction SilentlyContinue)) {
    Warn "未加载 portable-lib.ps1，跳过可移动程序采集"
}
else {
    $scanRoots = @(Get-Cfg $portableCfg 'scanRoots' @())
    $blocklist = @(Get-Cfg $portableCfg 'blocklist' @())
    $maxApp    = [int](Get-Cfg $portableCfg 'maxMBPerApp' 2048)
    $maxTotalP = [int](Get-Cfg $portableCfg 'maxTotalMB' 8192)
    $pMode     = [string](Get-Cfg $portableCfg 'mode' 'copy')

    $cand = @(Get-PortableApps -ScanRoots $scanRoots -Blocklist $blocklist -MaxMBPerApp $maxApp -MaxTotalMB $maxTotalP)
    Say ("  可移动程序候选：{0} 个" -f $cand.Count)

    if ($cand.Count -gt 0) {
        $res = Copy-PortableApps -Apps $cand -DestRoot $PortableDir -Mode $pMode
        $portableCaptured = @($res.captured)
        foreach ($pb in @($res.problems)) { $problems.Add($pb) }
        Say ("  可移动程序已搬运：{0} 个（模式 {1}）-> {2}" -f $portableCaptured.Count, $pMode, $PortableDir)

        # 三处元数据保持一致：数据目录内 / 快照内 / manifest
        try { Write-PortableManifest -Apps $portableCaptured -Path (Join-Path $PortableDir "_manifest.json") } catch { Warn "写便携清单(数据目录)失败：$_" }
        try { Write-PortableManifest -Apps $portableCaptured -Path (Join-Path $Stage "apps\portable.json") } catch { Warn "写便携清单(快照)失败：$_" }
    }
}

# ---------------------------------------------------------------- 3c. 安装型程序（识别 + 备份）

$programsCfg      = Get-Cfg $cfg 'programs' $null
$programsEnabled  = [bool](Get-Cfg $programsCfg 'enabled' $true)
$programsInQuick  = [bool](Get-Cfg $programsCfg 'captureInQuick' $false)
$doPrograms       = $programsEnabled -and ((-not $Quick) -or $programsInQuick)
$programsCaptured = @()
$programsRoot     = $(if ($env:CLOUDRDP_PROGRAMS_DIR) { $env:CLOUDRDP_PROGRAMS_DIR } else { (Join-Path $SysDir "programs") })

if (-not $programsEnabled) {
    Say "  安装型程序：已关闭（programs.enabled=false）"
}
elseif (-not $doPrograms) {
    Say "  安装型程序：quick 模式跳过（programs.captureInQuick=false）"
}
elseif (-not (Get-Command Get-InstalledPrograms -ErrorAction SilentlyContinue)) {
    Warn "未加载 programs-lib.ps1，跳过安装型程序备份"
}
else {
    $stateDir = Join-Path $SysDir "_state"
    $baseFile = Join-Path $stateDir "program-baseline.json"
    $prevFile = Join-Path $stateDir "prev-programs.json"

    $baseRegs = @()
    if (Test-Path -LiteralPath $baseFile) {
        try { $baseRegs = @((Get-Content -LiteralPath $baseFile -Raw -Encoding UTF8 | ConvertFrom-Json).regPaths) } catch { $baseRegs = @() }
    }
    $prevRegs = @()
    if (Test-Path -LiteralPath $prevFile) {
        try { $prevRegs = @((Get-Content -LiteralPath $prevFile -Raw -Encoding UTF8 | ConvertFrom-Json).regPaths) } catch { $prevRegs = @() }
    }

    if (@($baseRegs).Count -eq 0) {
        Warn "  缺少开机基线（program-baseline.json）—— 为安全起见本次跳过安装型程序备份"
    }
    else {
        $allApps = @(Get-InstalledPrograms)
        Say ("  已装程序总数：{0}（镜像基线 {1} / 历史备份 {2}）" -f $allApps.Count, @($baseRegs).Count, @($prevRegs).Count)

        # 已被 portable 处理过的目录不重复备份
        $portablePaths = @()
        foreach ($pp in $portableCaptured) { $portablePaths += [string]$pp.originalPath }

        $imgBlock = @(Get-Cfg $programsCfg 'imageBlockPaths' @())
        if (@($imgBlock).Count -eq 0) { $imgBlock = @(Get-ProgramImageBlockPaths) }

        $sel = Get-ProgramsToBackup -All $allApps `
            -BaselineRegPaths $baseRegs -AlwaysIncludeRegPaths $prevRegs -ExcludePaths $portablePaths `
            -SystemRoots (Get-ProgramSystemRoots) -ImageBlockPaths $imgBlock `
            -Blocklist @(Get-Cfg $programsCfg 'blocklist' @()) `
            -MaxMBPerApp ([int](Get-Cfg $programsCfg 'maxMBPerApp' 1024)) `
            -MaxTotalMB  ([int](Get-Cfg $programsCfg 'maxTotalMB' 2048))

        foreach ($sk in @($sel.skipped)) { Warn ("  跳过：{0}" -f $sk) }
        $selArr = [object[]]$sel.selected
        Say ("  安装型程序待备份：{0} 个 / {1:N1} MB" -f $selArr.Count, ($sel.totalBytes / 1MB))

        if ($selArr.Count -gt 0) {
            $b = Backup-Programs -Apps $selArr -Stage $Stage -ProgramsRoot $programsRoot
            $programsCaptured = @($b.captured)
            foreach ($pb in @($b.problems)) { $problems.Add($pb) }
            try { Write-ProgramsManifest -Apps $programsCaptured -Path (Join-Path $Stage "programs\programs.json") } catch { Warn "写程序清单失败：$_" }
            Say ("  安装型程序已备份：{0} 个" -f $programsCaptured.Count)
        }
    }
}

# ---------------------------------------------------------------- 3d. 程序关联数据（AppData / ProgramData）

if ($programsEnabled -and @($programsCaptured).Count -gt 0) {
    if (Get-Command Get-ProgramDataDirs -ErrorAction SilentlyContinue) {
        $dataGlobs = @(Get-Cfg $programsCfg 'dataGlobs' @())
        $dataDirs  = @(Get-ProgramDataDirs -Programs @($programsCaptured) -DataGlobs $dataGlobs)
        Say ("  程序关联数据目录：命中 {0} 个" -f $dataDirs.Count)
        foreach ($d in $dataDirs) {
            if (-not (Test-Path -LiteralPath $d)) { continue }
            $relD = Get-MirrorRel -Abs $d
            $dstD = Join-Path (Join-Path $Stage "files") $relD
            if (Test-Path -LiteralPath $dstD) { continue }        # 已被 files.dirs 抓过，别重复
            $codeD = Invoke-Robocopy -Src $d -Dst $dstD -ExcludeDirs $exDirs -ExcludeFiles $exFiles
            if ($codeD -ge 8) { Warn "关联数据 robocopy 失败（码 $codeD）：$d"; $problems.Add("data:$d"); continue }
            $gotD = Get-TreeSize -Path $dstD
            $totalBytes += $gotD.Bytes
            $totalFiles += $gotD.Files
            $fileEntries.Add([pscustomobject]@{
                source = $d; originalPath = $d; mirror = $relD; files = $gotD.Files; bytes = $gotD.Bytes; robocopy = $codeD
            })
            Say ("  关联数据 {0}  ->  {1} 个文件 / {2:N2} MB" -f $d, $gotD.Files, ($gotD.Bytes / 1MB))
        }
    } else { Warn "未加载 programs-lib.ps1，跳过程序关联数据采集" }
}

# ---- 3e. 文件关联 / COM（只导命中被备份程序的 ProgID/CLSID，绝不导整棵 HKCR）----
if (-not $Quick) {
    if ([bool](Get-Cfg $cfg.registry 'hkcr' $true)) {
        if (Get-Command Get-HkcrMatches -ErrorAction SilentlyContinue) {
            $progLocs = @()
            foreach ($g in $programsCaptured) { if ($g.originalPath) { $progLocs += [string]$g.originalPath } }
            foreach ($pp in $portableCaptured) { if ($pp.originalPath) { $progLocs += [string]$pp.originalPath } }
            $manualIds = @(Get-Cfg $cfg.registry 'hkcrProgIds' @())
            if ((@($progLocs).Count -gt 0) -or (@($manualIds).Count -gt 0)) {
                $hkKeys = @(Get-HkcrMatches -ProgramPaths $progLocs -ExtraProgIds $manualIds)
                if ($hkKeys.Count -gt 0) {
                    $hkOut = Join-Path $Stage "registry\machine\HKCR-apps.reg"
                    $parts = New-Object System.Collections.Generic.List[string]
                    foreach ($key in $hkKeys) {
                        $tmpReg = Join-Path $env:TEMP ("hkcr_" + [guid]::NewGuid().ToString('N') + ".reg")
                        & reg.exe export "$key" "$tmpReg" /y 2>&1 | Out-Null
                        if ((Test-Path -LiteralPath $tmpReg) -and $LASTEXITCODE -eq 0) {
                            $parts.Add((Get-Content -LiteralPath $tmpReg -Raw -Encoding Unicode))
                        }
                        Remove-Item -LiteralPath $tmpReg -Force -ErrorAction SilentlyContinue
                    }
                    if ($parts.Count -gt 0) {
                        ($parts -join "`r`n") | Out-File -LiteralPath $hkOut -Encoding Unicode
                        $regFiles.Add("registry\machine\HKCR-apps.reg")
                        Say ("  文件关联/COM：导出 {0} 个键" -f $parts.Count)
                    } else { Warn "文件关联/COM：命中 {0} 个键但导出全部失败" -f $hkKeys.Count }
                } else { Say "  文件关联/COM：无命中键" }
            } else { Say "  文件关联/COM：本次没有要备份的程序，跳过" }
        } else { Warn "未加载 programs-lib.ps1，跳过文件关联导出" }
    } else { Say "  文件关联/COM：已关闭（registry.hkcr=false）" }
}

# ---------------------------------------------------------------- 4. 系统设置

$sys = [ordered]@{ capturedUtc = (Get-Date).ToUniversalTime().ToString("o"); capturedLocal = (Get-Date).ToString("o") }

if ([bool](Get-Cfg $cfg.system 'timezone' $true)) {
    try { $sys.timezoneId = (Get-TimeZone).Id } catch { $sys.timezoneId = $null }
}
if ([bool](Get-Cfg $cfg.system 'culture' $true)) {
    try {
        $sys.culture   = (Get-Culture).Name
        $sys.uiCulture = (Get-UICulture).Name
    } catch { }
}
if ([bool](Get-Cfg $cfg.system 'powerPlan' $true)) {
    try {
        $scheme = (& powercfg.exe /getactivescheme 2>&1) -join ' '
        $sys.powerPlan = $scheme
    } catch { }
}
if ([bool](Get-Cfg $cfg.system 'wallpaper' $true)) {
    # 从刚导出的 HKCU-Desktop.reg 里取壁纸路径（避免直接读 runneradmin 的 HKCU）
    $deskReg = Join-Path $Stage "registry\user\HKCU-Desktop.reg"
    if (Test-Path -LiteralPath $deskReg) {
        $txt = Get-Content -LiteralPath $deskReg -Raw -Encoding Unicode
        $m = [regex]::Match($txt, '"WallPaper"\s*=\s*"([^"]*)"')
        if ($m.Success) {
            $wp = $m.Groups[1].Value -replace '\\\\', '\'
            $sys.wallpaperPath = $wp
            if (Test-Path -LiteralPath $wp) {
                $rel = Get-MirrorRel -Abs $wp
                $dst = Join-Path (Join-Path $Stage "files") $rel
                New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
                Copy-Item -LiteralPath $wp -Destination $dst -Force -ErrorAction SilentlyContinue
                Say "  壁纸已附带：$wp"
            }
        }
    }
}
if ([bool](Get-Cfg $cfg.system 'firewall' $true)) {
    try {
        $fwOut = Join-Path $Stage "system\firewall.wfw"
        & netsh.exe advfirewall export "$fwOut" 2>&1 | Out-Null
        if (Test-Path -LiteralPath $fwOut) {
            $sys.firewallExport = "system/firewall.wfw"
            Say "  防火墙规则已导出"
        } else { Warn "防火墙导出未生成文件（可忽略）" }
    } catch { Warn "防火墙导出失败：$_" }
}
if ([bool](Get-Cfg $cfg.system 'defenderExclusions' $true)) {
    try {
        $pref = Get-MpPreference -ErrorAction Stop
        $sys.defenderExclusionPath    = @($pref.ExclusionPath)
        $sys.defenderExclusionProcess = @($pref.ExclusionProcess)
        Say ("  Defender 排除项：路径 {0} 个 / 进程 {1} 个" -f @($pref.ExclusionPath).Count, @($pref.ExclusionProcess).Count)
    } catch { Warn "Defender 排除项读取失败（可忽略）：$_" }
}
$sys.rdpUser     = $RdpUser
$sys.hostname    = $env:COMPUTERNAME
$sys.machineName = $env:COMPUTERNAME
$sys | ConvertTo-Json -Depth 4 | Out-File -LiteralPath (Join-Path $Stage "system\system.json") -Encoding UTF8
Say "  系统设置已记录"

# ---------------------------------------------------------------- 5. 快捷方式

$scMap = @()
if ([bool](Get-Cfg $cfg.shortcuts 'publicDesktop' $true)) { $scMap += @{ src = "$env:PUBLIC\Desktop"; dst = "shortcuts\public-desktop" } }
if ([bool](Get-Cfg $cfg.shortcuts 'userDesktop'   $true)) { $scMap += @{ src = ("C:\Users\$RdpUser\Desktop"); dst = "shortcuts\user-desktop" } }
if ([bool](Get-Cfg $cfg.shortcuts 'userStartMenu' $true)) { $scMap += @{ src = ("C:\Users\$RdpUser\AppData\Roaming\Microsoft\Windows\Start Menu"); dst = "shortcuts\user-startmenu" } }
if ([bool](Get-Cfg $cfg.shortcuts 'machineStartMenu' $true)) { $scMap += @{ src = "$env:ProgramData\Microsoft\Windows\Start Menu"; dst = "shortcuts\machine-startmenu" } }

$scCount = 0
foreach ($m in $scMap) {
    if (-not (Test-Path -LiteralPath $m.src)) { continue }
    $dst = Join-Path $Stage $m.dst
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    $lnks = @(Get-ChildItem -LiteralPath $m.src -Recurse -File -ErrorAction SilentlyContinue |
              Where-Object { $_.Extension -eq '.lnk' -or $_.Extension -eq '.url' })
    foreach ($l in $lnks) {
        $relL = $l.FullName.Substring($m.src.Length).TrimStart('\')
        $target = Join-Path $dst $relL
        New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
        Copy-Item -LiteralPath $l.FullName -Destination $target -Force -ErrorAction SilentlyContinue
        $scCount++
    }
}
Say ("  快捷方式：{0} 个" -f $scCount)

# ---------------------------------------------------------------- 6. 供还原用的脚本副本

foreach ($f in @("restore-snapshot.ps1", "snapshot-config.json")) {
    $src = Join-Path $PSScriptRoot $f
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $Stage "_tools\$f") -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------- 7. 清单

$status = if ($problems.Count -eq 0) { "OK" } else { "PARTIAL" }

# ---- 合并被保留的用户条目（profile 不存在时，见 0a）----
if ($prevManifest -and $heldSubtrees.Count -gt 0) {
    $userMirrorPrefix = ("C\Users\" + $RdpUser).ToLower()
    $curMirrors = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($e in $fileEntries) { if ($e.mirror) { [void]$curMirrors.Add(([string]$e.mirror).ToLower()) } }
    $keptFiles = 0
    foreach ($e in @($prevManifest.files.entries)) {
        $m = [string]$e.mirror
        if ([string]::IsNullOrWhiteSpace($m)) { continue }
        if (-not $m.ToLower().StartsWith($userMirrorPrefix)) { continue }
        if ($curMirrors.Contains($m.ToLower())) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $Stage "files") $m))) { continue }
        $fileEntries.Add($e)
        $totalFiles += [int]$e.files
        $totalBytes += [long]$e.bytes
        [void]$curMirrors.Add($m.ToLower())
        $keptFiles++
    }
    $curReg = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($r in $regFiles) { [void]$curReg.Add(([string]$r).ToLower()) }
    $keptReg = 0
    foreach ($r in @($prevManifest.registry)) {
        $rs = [string]$r
        if (-not $rs.ToLower().StartsWith("registry\user\")) { continue }
        if ($curReg.Contains($rs.ToLower())) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $Stage $rs))) { continue }
        $regFiles.Add($rs)
        [void]$curReg.Add($rs.ToLower())
        $keptReg++
    }
    # 个人快捷方式被保留时，确保 plan 里仍有 shortcut 条目
    $scFiles = @(Get-ChildItem -LiteralPath (Join-Path $Stage "shortcuts") -Recurse -File -ErrorAction SilentlyContinue).Count
    if ($scFiles -gt $scCount) { $scCount = $scFiles }
    Say ("  合并保留的用户条目：文件 {0} 个 / 注册表 {1} 个" -f $keptFiles, $keptReg)
}

# ---- 还原计划（v2）：每条 = 类型 / 原路径 / 存储路径 / 作用域 ----
# 这是「还原机器设置包含原文件路径 + 程序列表」的权威载体，还原侧优先消费它。
$userPrefix = ("C:\Users\" + $RdpUser)
$plan = New-Object System.Collections.Generic.List[object]

foreach ($e in $fileEntries) {
    $scope = if ([string]$e.source -and ([string]$e.source).ToLower().StartsWith($userPrefix.ToLower())) { "user" } else { "machine" }
    $plan.Add([pscustomobject]@{
        type = "dir"; originalPath = $e.source; store = ("files/" + $e.mirror); scope = $scope
        meta = @{ files = $e.files; bytes = $e.bytes }
    })
}
foreach ($r in $regFiles) {
    $scope = if ($r -like "registry/user/*") { "user" } else { "machine" }
    $plan.Add([pscustomobject]@{ type = "registry"; originalPath = $r; store = $r; scope = $scope; meta = @{} })
}
foreach ($p in $portableCaptured) {
    $scope = if (([string]$p.originalPath).ToLower().StartsWith($userPrefix.ToLower())) { "user" } else { "machine" }
    $plan.Add([pscustomobject]@{
        type = "portable"; originalPath = $p.originalPath; store = $p.storedPath; scope = $scope
        meta = @{ displayName = $p.displayName; version = $p.version; mode = $p.mode }
    })
}
foreach ($g in $programsCaptured) {
    $scope = if (([string]$g.originalPath).ToLower().StartsWith($userPrefix.ToLower())) { "user" } else { "machine" }
    $plan.Add([pscustomobject]@{
        type = "program"; originalPath = $g.originalPath; store = $g.storedPath; scope = $scope
        meta = @{ displayName = $g.displayName; version = $g.version; regFile = $g.regFile; bytes = $g.bytes }
    })
}
if ($scCount -gt 0) {
    $plan.Add([pscustomobject]@{ type = "shortcut"; originalPath = "$env:PUBLIC\Desktop"; store = "shortcuts/public-desktop"; scope = "machine"; meta = @{} })
    $plan.Add([pscustomobject]@{ type = "shortcut"; originalPath = ("$userPrefix\Desktop"); store = "shortcuts/user-desktop"; scope = "user"; meta = @{} })
}
$plan.Add([pscustomobject]@{ type = "setting"; originalPath = ""; store = "system/system.json"; scope = "machine"; meta = @{} })
if (Test-Path -LiteralPath (Join-Path $Stage "apps\winget-export.json")) {
    $plan.Add([pscustomobject]@{ type = "app"; originalPath = ""; store = "apps/winget-export.json"; scope = "background"; meta = @{ count = $wingetCount } })
}

$dataDirForManifest = $(if ($env:CLOUDRDP_DATA_DIR) { $env:CLOUDRDP_DATA_DIR } else { "D:\a\cloud-rdp" })

# 注意：本机 PS 5.1 下 @(<泛型List>) 会抛「参数类型不匹配」，必须用 [object[]] 转换
$planArr      = [object[]]$plan
$installedArr = [object[]]$installedApps
$portableArr  = [object[]]$portableCaptured
$programsArr  = [object[]]$programsCaptured
$manifest = [ordered]@{
    version     = $SnapshotVersion
    mode        = $mode
    status      = $status
    createdUtc  = (Get-Date).ToUniversalTime().ToString("o")
    createdLocal= (Get-Date).ToString("o")
    hostname    = $env:COMPUTERNAME
    rdpUser     = $RdpUser
    dataDir     = $dataDirForManifest
    files       = @{ entries = $fileEntries; totalFiles = $totalFiles; totalBytes = $totalBytes; skipped = $skippedDirs }
    registry    = $regFiles
    shortcuts   = $scCount
    system      = $sys
    apps        = @{
        wingetExport = $(if (Test-Path -LiteralPath (Join-Path $Stage "apps\winget-export.json")) { "apps/winget-export.json" } else { $null })
        wingetCount  = $wingetCount
        installed    = $installedArr
        portable     = $portableArr
        programs     = $programsArr
    }
    plan        = $planArr
    problems    = $problems
}
$manifest | ConvertTo-Json -Depth 8 | Out-File -LiteralPath (Join-Path $Stage "manifest.json") -Encoding UTF8
Say ("  还原计划：{0} 项（dir/registry/portable/program/shortcut/setting/app）" -f $planArr.Count)

$mb = [math]::Round($totalBytes / 1MB, 2)
Say ("抓取完成：{0} 个文件 / {1} MB / 状态 {2}" -f $totalFiles, $mb, $status)

Set-GhEnv ("SNAPSHOT_STATUS=" + $status)
Set-GhEnv ("SNAPSHOT_FILES=" + $totalFiles)
Set-GhEnv ("SNAPSHOT_MB=" + $mb)
Set-GhEnv ("SNAPSHOT_ENTRIES=" + $fileEntries.Count)
Set-GhEnv ("SNAPSHOT_PROGRAMS=" + @($programsCaptured).Count)

# ---------------------------------------------------------------- 8. 推送

if ($Push) {
    if (-not (Test-Path -LiteralPath $RcloneExe)) {
        Warn "未找到 rclone，跳过推送（本地快照仍在 $Stage）"
        Set-GhEnv "SNAPSHOT_PUSH=SKIPPED"
        exit 0
    }
    Say "推送到 $Remote ..."
    & $RcloneExe mkdir $Remote --timeout 0 --contimeout 0 2>&1 | Out-Null

    # ---------- 传输策略（体积不设上限时的保护）----------
    # 139 实测约 0.45 MB/s：先估算耗时；再按「job 预算 − 已耗时 − 15 分钟」给 rclone 一个
    # --max-duration，到点会优雅退出而不是被 GitHub 硬杀（大目录用 copy 可续传，不会毁远端）。
    $progBytesTotal = [long]0
    foreach ($g in $programsCaptured) { $progBytesTotal += [long]$g.bytes }
    $mbps = 0.45
    $pushMB  = [math]::Round(($totalBytes + $progBytesTotal) / 1MB, 1)
    $etaMin  = [int][math]::Ceiling($pushMB / $mbps / 60)
    Say ("  待推送约 {0} MB，按 {1} MB/s 估算需 ~{2} 分钟" -f $pushMB, $mbps, $etaMin)
    Set-GhEnv ("SNAPSHOT_ETA_MIN=" + $etaMin)
    Set-GhEnv ("SNAPSHOT_PUSH_MB=" + $pushMB)

    $maxDurArg = @()
    $jobBudgetMin = 360
    $jobStartFile = Join-Path $SysDir "_state\job-start.txt"
    if (Test-Path -LiteralPath $jobStartFile) {
        try {
            $t0 = [datetime]::Parse((Get-Content -LiteralPath $jobStartFile -Raw).Trim()).ToUniversalTime()
            $elapsedMin = [int]((Get-Date).ToUniversalTime() - $t0).TotalMinutes
            $remainMin = $jobBudgetMin - $elapsedMin - 15
            if ($remainMin -gt 5) {
                $maxDurArg = @('--max-duration', ($remainMin.ToString() + 'm'))
                Say ("  job 已跑 {0} 分钟，给 rclone 设 --max-duration {1}m" -f $elapsedMin, $remainMin)
                if ($etaMin -gt $remainMin) {
                    Warn ("  估算耗时 {0} 分钟 > 剩余 {1} 分钟 —— 本次可能传不完；大目录用 copy 可续传，下次继续" -f $etaMin, $remainMin)
                }
            }
        } catch { Warn "读取 job 起始时间失败：$_" }
    }
    if ($maxDurArg.Count -eq 0 -and $etaMin -gt 300) { Warn "估算耗时较长（$etaMin 分钟），本次可能传不完（可续传）" }

    $rcCommon = @('--transfers','4','--checkers','8','--timeout','0','--contimeout','0',
                  '--retries','3','--low-level-retries','5','--stats-one-line','-v') + $maxDurArg

    # ① 大目录（files / programs）：用 copy —— 只增不删、可断点续传，被中断也不会删远端
    foreach ($big in @('files', 'programs')) {
        $bigPath = Join-Path $Stage $big
        if (-not (Test-Path -LiteralPath $bigPath)) { continue }
        Say ("  推送大目录 {0}（copy，可续传）..." -f $big)
        & $RcloneExe copy $bigPath (($Remote.TrimEnd('/')) + '/' + $big) @rcCommon 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Warn ("  {0} 推送返回码 {1}（copy 可续传，下次继续）" -f $big, $LASTEXITCODE) }
    }

    # ② 其余（manifest/registry/shortcuts/system/apps/_tools）：用 sync —— 远端镜像本地，
    #    避免已删除的元数据在还原时「复活」；用 --exclude 保护大目录不被删除
    Say "  推送元数据（sync，排除大目录）..."
    & $RcloneExe sync $Stage $Remote --exclude "/files/**" --exclude "/programs/**" @rcCommon
    if ($LASTEXITCODE -eq 0) {
        Say "推送完成"
        Set-GhEnv "SNAPSHOT_PUSH=OK"

        # 回读远端做校验：本地文件数/字节 vs 远端，给出「确实落盘」的日志证据
        try {
            $szJson = (& $RcloneExe size $Remote --json --timeout 0 --contimeout 0 2>$null | Out-String)
            if ($szJson -match '\{') {
                $sz = ($szJson.Substring($szJson.IndexOf('{')) | ConvertFrom-Json)
                $rCount = [int]$sz.count
                $rBytes = [double]$sz.bytes
                $rMB = [math]::Round($rBytes / 1MB, 2)
                Say ("远端校验：{0} 个文件 / {1} MB（本地 {2} 个 / {3} MB）" -f $rCount, $rMB, $totalFiles, $mb)
                if ($rCount -lt $totalFiles) {
                    Warn ("远端文件数少于本地（{0} < {1}）—— 可能有文件未上传成功" -f $rCount, $totalFiles)
                    Set-GhEnv "SNAPSHOT_VERIFY=PARTIAL"
                } else {
                    Say "远端校验通过：快照已完整落盘 139"
                    Set-GhEnv "SNAPSHOT_VERIFY=OK"
                }
                Set-GhEnv ("SNAPSHOT_REMOTE_FILES=" + $rCount)
                Set-GhEnv ("SNAPSHOT_REMOTE_MB=" + $rMB)
            } else {
                Warn "远端校验跳过（rclone size 无输出）"
                Set-GhEnv "SNAPSHOT_VERIFY=SKIPPED"
            }
        } catch {
            Warn "远端校验异常：$_"
            Set-GhEnv "SNAPSHOT_VERIFY=SKIPPED"
        }
    } else {
        Warn "推送失败（rclone 码 $LASTEXITCODE）"
        Set-GhEnv "SNAPSHOT_PUSH=FAILED"
    }
}

exit 0
