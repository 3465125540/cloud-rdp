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
    [string]$Stage      = "C:\_snapshot",
    [string]$Remote     = "alist:/cloudrdp/_snapshot",
    [string]$ConfigPath = (Join-Path $PSScriptRoot "snapshot-config.json"),
    [string]$RdpUser    = $(if ($env:RDP_USERNAME) { $env:RDP_USERNAME } else { "NvdAdmin" }),
    [switch]$Push,
    [switch]$Quick
)

$ErrorActionPreference = "Continue"
$RcloneExe       = "C:\rclone\rclone.exe"
$SnapshotVersion = 1
$UserHiveToken   = "__RDPUSER__"     # 归一化后的 HKCU 占位符，还原时按当前 SID 替换

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
if (Test-Path -LiteralPath $Stage) { Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue }
foreach ($sub in @("files", "registry\user", "registry\machine", "apps", "system", "shortcuts", "_tools")) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Stage $sub) | Out-Null
}

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
    if ((($totalBytes + $size.Bytes) / 1MB) -gt $maxTotalMB) {
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
        source = $src; mirror = $rel; files = $got.Files; bytes = $got.Bytes; robocopy = $code
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

if (-not $Quick) {
    if ([bool](Get-Cfg $cfg.apps 'wingetExport' $true)) {
        $wg = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($wg) {
            $out = Join-Path $Stage "apps\winget-export.json"
            & winget.exe export -o "$out" --include-versions --accept-source-agreements 2>&1 | Out-Null
            if (Test-Path -LiteralPath $out) { Say "  winget 清单已导出" }
            else { Warn "winget export 失败（可忽略）" }
        } else { Warn "未找到 winget，跳过软件清单导出" }
    }

    if ([bool](Get-Cfg $cfg.apps 'uninstallScan' $true)) {
        $paths = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        $apps = foreach ($p in $paths) {
            Get-ItemProperty -Path $p -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName } |
                Select-Object DisplayName, DisplayVersion, Publisher, InstallLocation, UninstallString
        }
        $apps = @($apps | Sort-Object DisplayName -Unique)
        $apps | ConvertTo-Json -Depth 4 | Out-File -LiteralPath (Join-Path $Stage "apps\installed-apps.json") -Encoding UTF8
        Say ("  已装软件扫描：{0} 项" -f $apps.Count)
    }
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

$manifest = [ordered]@{
    version     = $SnapshotVersion
    mode        = $mode
    status      = $status
    createdUtc  = (Get-Date).ToUniversalTime().ToString("o")
    createdLocal= (Get-Date).ToString("o")
    hostname    = $env:COMPUTERNAME
    rdpUser     = $RdpUser
    files       = @{ entries = $fileEntries; totalFiles = $totalFiles; totalBytes = $totalBytes; skipped = $skippedDirs }
    registry    = $regFiles
    shortcuts   = $scCount
    system      = $sys
    problems    = $problems
}
$manifest | ConvertTo-Json -Depth 6 | Out-File -LiteralPath (Join-Path $Stage "manifest.json") -Encoding UTF8

$mb = [math]::Round($totalBytes / 1MB, 2)
Say ("抓取完成：{0} 个文件 / {1} MB / 状态 {2}" -f $totalFiles, $mb, $status)

Set-GhEnv ("SNAPSHOT_STATUS=" + $status)
Set-GhEnv ("SNAPSHOT_FILES=" + $totalFiles)
Set-GhEnv ("SNAPSHOT_MB=" + $mb)
Set-GhEnv ("SNAPSHOT_ENTRIES=" + $fileEntries.Count)

# ---------------------------------------------------------------- 8. 推送

if ($Push) {
    if (-not (Test-Path -LiteralPath $RcloneExe)) {
        Warn "未找到 rclone，跳过推送（本地快照仍在 $Stage）"
        Set-GhEnv "SNAPSHOT_PUSH=SKIPPED"
        exit 0
    }
    Say "推送到 $Remote ..."
    & $RcloneExe mkdir $Remote --timeout 0 --contimeout 0 2>&1 | Out-Null
    # 用 sync：远端镜像本地，避免已删除的文件在还原时「复活」
    & $RcloneExe sync $Stage $Remote `
        --transfers 4 --checkers 8 `
        --timeout 0 --contimeout 0 `
        --retries 3 --low-level-retries 5 `
        --stats-one-line -v
    if ($LASTEXITCODE -eq 0) {
        Say "推送完成"
        Set-GhEnv "SNAPSHOT_PUSH=OK"
    } else {
        Warn "推送失败（rclone 码 $LASTEXITCODE）"
        Set-GhEnv "SNAPSHOT_PUSH=FAILED"
    }
}

exit 0
