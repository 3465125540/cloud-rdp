<#
.SYNOPSIS
  开机瘦身：删除 runner 镜像自带、本项目用不到的大件，把 C 盘占用压到阈值以下。

.DESCRIPTION
  为什么需要它：GitHub 托管 Windows runner 的 C 盘 150GB 里约 **120GB 是镜像自带**（开机即约 80%）：
    · Visual Studio 2022 Enterprise                     约 30-35 GB
    · Android SDK                                       约 10-15 GB
    · hostedtoolcache（Node/Python/Java/Go/Ruby 缓存）    约 10-12 GB
    · Windows SDK / WDK / MSBuild / SQL Server / JDK /
      浏览器 / LLVM / CMake / R / Strawberry / AzureCLI   约 15-20 GB
  本项目完全用不到它们（只用 pwsh / git / robocopy / winget / 自己下载的 rclone + AList），
  开机删掉可释放约 70 GB，把 C 盘占用压到 30% 以下。

  安全设计（重要）：
    ① 硬保护名单（写死，配置里写了也不会删）：
       C:\Windows、C:\Users、C:\Program Files\WindowsApps（**winget 在这**）、
       C:\Program Files\PowerShell（**我们自己要跑 pwsh**）、Windows Defender、
       Common Files、Windows NT、IE、Windows Media Player、
       Microsoft\Edge 与 EdgeWebView（WebView2 依赖）、C:\actions-runner，
       以及工作区 / 数据目录 / 系统目录 / 快照暂存 / 程序还原根
    ② 保护判断同时拦「受保护目录内部」**和**「受保护目录的父目录」—— 所以配置里写 `C:\Program Files\Microsoft`
       这种宽泛父目录会被直接拒绝（因为它内含受保护的 Edge）
    ③ 只删配置里显式列出的路径（targets + extraPaths − keepPaths），不做任何通配扫描
    ④ fail-soft：单个目标删不掉只告警，**永不返回非 0**
    ⑤ `-DryRun` 只报告不删

.PARAMETER Mode
  auto（默认）= 仅当 C 盘占用 > TargetPercent 时才瘦身；always = 每次开机都瘦身；off = 不瘦身

.NOTES
  透出环境变量：
    SLIM_STATUS = OK | PARTIAL | SKIPPED | DRYRUN | FAILED
    SLIM_FREED_GB / SLIM_C_USED_PCT / SLIM_TARGETS_DELETED / SLIM_TARGETS_GUARDED
    SLIM_UNINSTALL_OK / SLIM_UNINSTALL_FAILED     ← blockedApps 真卸载结果
    SLIM_PURGED_DIRS / SLIM_PURGED_GB             ← 清空型目标（保留目录本身）结果
    SLIM_ARP_CLEANED / SLIM_ARP_FAILED            ← 残留 ARP 卸载项清理（「未卸载成功」的真凶）
    SLIM_DIRS_CLEARED / SLIM_DIRS_LEFTOVER        ← 残留空壳目录清理

  执行顺序（顺序是硬约束）：
    ① 卸载 blockedApps（真卸载）—— 必须在清空 C:\Windows\Installer **之前**：
       MSI 卸载依赖缓存里的安装包，缓存先没了卸载就会失败
    ② 删除 targets 大件
    ③ 清空 purgeContents（如 C:\Windows\Installer）—— 此时已无人需要 MSI 缓存
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "",
    [string]$Mode = "",
    [int]   $TargetPercent = 0,
    [string[]]$ExtraPaths = @(),
    [string[]]$KeepPaths = @(),
    [switch]$DryRun,
    [switch]$Quiet
)

$ErrorActionPreference = "Continue"

# 配置文件路径：不在 param 默认值里依赖 $PSScriptRoot（某些调用方式下它可能为空），显式兜底
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot "snapshot-config.json"
}

function Set-GhEnv([string]$kv) {
    if ($env:GITHUB_ENV) { $kv | Out-File $env:GITHUB_ENV -Append -Encoding ascii }
}
function Say([string]$m)  { if (-not $Quiet) { Write-Host "[slim] $m" } }
function Note([string]$m) { Write-Warning "[slim] $m" }

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

function Get-FreeBytes {
    param([string]$DriveLetter = 'C')
    $d = Get-PSDrive -Name $DriveLetter -ErrorAction SilentlyContinue
    if ($null -eq $d) { return [long]0 }
    return [long]$d.Free
}

function Get-UsedPercent {
    param([string]$DriveLetter = 'C')
    $d = Get-PSDrive -Name $DriveLetter -ErrorAction SilentlyContinue
    if ($null -eq $d) { return -1 }
    $used = [long]$d.Used
    $total = $used + [long]$d.Free
    if ($total -le 0) { return -1 }
    return [math]::Round($used * 100.0 / $total, 1)
}

# ---------------------------------------------------------------- 硬保护名单
$neverDelete = @(
    'C:\Windows',
    'C:\Users',
    'C:\actions-runner',
    'C:\Program Files\WindowsApps',                    # winget / 商店应用
    'C:\Program Files\PowerShell',                     # 我们自己的 pwsh
    'C:\Program Files\WindowsPowerShell',
    'C:\Program Files\Windows Defender',
    'C:\ProgramData\Microsoft\Windows Defender',
    'C:\Program Files\Windows NT',
    'C:\Program Files\Windows Portable Devices',
    'C:\Program Files\Windows Sidebar',
    'C:\Program Files\Internet Explorer',
    'C:\Program Files\Windows Media Player',
    'C:\Program Files\Common Files',
    'C:\Program Files (x86)\Common Files',
    'C:\Program Files\Microsoft\Edge',
    'C:\Program Files (x86)\Microsoft\Edge',
    'C:\Program Files\Microsoft\EdgeWebView',
    'C:\Program Files (x86)\Microsoft\EdgeWebView',
    'C:\Program Files\Microsoft\EdgeUpdate',
    'C:\Program Files (x86)\Microsoft\EdgeUpdate'
)
$protect = New-Object System.Collections.Generic.List[string]
foreach ($x in $neverDelete) { $protect.Add($x.TrimEnd('\')) }
foreach ($x in @($env:GITHUB_WORKSPACE, $env:CLOUDRDP_DATA_DIR, $env:CLOUDRDP_SYS_DIR,
                 $env:CLOUDRDP_SNAPSHOT_STAGE, $env:CLOUDRDP_PROGRAMS_DIR, $env:CLOUDRDP_PORTABLE_DIR)) {
    if (-not [string]::IsNullOrWhiteSpace($x)) { $protect.Add($x.TrimEnd('\')) }
}
foreach ($x in $KeepPaths) {
    if (-not [string]::IsNullOrWhiteSpace($x)) { $protect.Add($x.TrimEnd('\')) }
}

function Test-NeverDelete {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
    $p = $Path.TrimEnd('\')
    if ($p -notmatch '^[A-Za-z]:\\') { return $true }                 # 必须绝对路径
    if (@($p -split '\\').Count -lt 3) { return $true }               # 禁止盘根（C:\、C:\Foo）
    $pl = $p.ToLower()
    foreach ($x in $protect) {
        $xl = $x.ToLower()
        if ($pl -eq $xl) { return $true }                             # 就是受保护目录
        if ($pl.StartsWith($xl + "\")) { return $true }               # 在受保护目录内部
        if ($xl.StartsWith($pl + "\")) { return $true }               # 是受保护目录的父目录（宽泛路径）
    }
    return $false
}

# 停掉常见的文件占用者（best-effort），提高删除成功率
function Stop-Lockers {
    foreach ($svc in @('GoogleUpdate.exe','GoogleUpdateTaskMachineCore','GoogleUpdateTaskMachineUA','MSSQLSERVER','SQLSERVERAGENT','docker')) {
        try { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue } catch { }
    }
    foreach ($proc in @('devenv','MSBuild','vctip','ServiceHub.Host.Node.x86','ServiceHub.RoslynCodeAnalysisService',
                        'GoogleUpdate','chrome','firefox','msedge','sqlservr','Rgui','Rterm','cmake','clang','perl',
                        'python','node','java','VBCSCompiler','VsDebugConsole')) {
        try { Get-Process -Name $proc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Remove-BigTree {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    # cmd 的 rmdir 比 Remove-Item 快得多，也更耐长路径
    & cmd.exe /c rmdir /s /q "$Path" 2>&1 | Out-Null
    if (Test-Path -LiteralPath $Path) {
        try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
    return (-not (Test-Path -LiteralPath $Path))
}

# ---------------------------------------------------------------- 卸载能力（blockedApps）
# 卸载库：ARP 扫描 / 停服务 / 三级降级卸载（winget → ARP → 目录兜底）
$uninstallLib = Join-Path $PSScriptRoot "uninstall-apps-lib.ps1"
$script:HasUninstallLib = $false
if (Test-Path -LiteralPath $uninstallLib) {
    . $uninstallLib
    $script:HasUninstallLib = $true
}

# ---------------------------------------------------------------- 清空型目标（只清内容、保留目录本身）

# 守卫：允许「受保护目录的内部」（如 C:\Windows\Installer），但必须
#   ① 绝对路径 ② 不是盘根（C:\）③ 不是硬保护名单里的目录本身
# 只对配置里显式列出的路径生效、不做任何通配扫描 ——
# 所以不会把 targets 里误配的宽泛路径变成「可清空目标」。
# 注：允许 2 层（如 C:\Config.Msi）；真正的安全网是「保护名单」那一条。
function Test-PurgeAllowed {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $p = $Path.TrimEnd('\')
    if ($p -notmatch '^[A-Za-z]:\\') { return $false }
    if (@($p -split '\\').Count -lt 2) { return $false }
    $pl = $p.ToLower()
    foreach ($x in $protect) { if ($pl -eq ([string]$x).ToLower()) { return $false } }
    return $true
}

# 清空目录内容、保留目录本身。优先 robocopy 镜像空目录（快、耐长路径、退出码 <8 视为成功），
# 失败再逐子项兜底。返回 @{ ok; freedBytes; left; rc }
function Clear-DirContents {
    param([string]$Path)
    $res = [ordered]@{ ok = $false; freedBytes = [long]0; left = -1; rc = -1 }
    if (-not (Test-Path -LiteralPath $Path)) { return $res }

    $empty = Join-Path $env:TEMP ("slimempty_" + [guid]::NewGuid().ToString('N'))
    try { New-Item -ItemType Directory -Force -Path $empty | Out-Null } catch { }

    $f0 = Get-FreeBytes 'C'
    try {
        & robocopy.exe "$empty" "$Path" /MIR /NFL /NDL /NJH /NJS /NC /NS /NP /R:1 /W:1 2>&1 | Out-Null
        $res.rc = $LASTEXITCODE
    } catch { $res.rc = -1 }
    try { Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue } catch { }

    # robocopy 退出码 >= 8 = 有失败项 → 逐子项兜底
    if ($res.rc -ge 8 -or $res.rc -lt 0) {
        foreach ($c in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
            try {
                if ($c.PSIsContainer) { Remove-Item -LiteralPath $c.FullName -Recurse -Force -ErrorAction SilentlyContinue }
                else { Remove-Item -LiteralPath $c.FullName -Force -ErrorAction SilentlyContinue }
            } catch { }
        }
    }

    $f1 = Get-FreeBytes 'C'
    $freed = $f1 - $f0
    if ($freed -lt 0) { $freed = 0 }
    $res.freedBytes = [long]$freed
    $res.left = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue).Count
    $res.ok = ($res.left -eq 0)
    return $res
}

# ---------------------------------------------------------------- 读配置
$cfg = $null
if (Test-Path -LiteralPath $ConfigPath) {
    try { $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
}
$slimCfg = Get-Cfg $cfg 'slim' $null
$enabled = [bool](Get-Cfg $slimCfg 'enabled' $true)

# 模式优先级：命令行 > 环境变量 INPUT_SLIM（workflow_dispatch 输入）> 配置
if ([string]::IsNullOrWhiteSpace($Mode)) {
    if (-not [string]::IsNullOrWhiteSpace($env:INPUT_SLIM)) { $Mode = $env:INPUT_SLIM.Trim().ToLower() }
}
if ([string]::IsNullOrWhiteSpace($Mode)) { $Mode = [string](Get-Cfg $slimCfg 'mode' 'auto') }
$Mode = ([string]$Mode).Trim().ToLower()

if ($TargetPercent -le 0) { $TargetPercent = [int](Get-Cfg $slimCfg 'targetPercent' 30) }

$usedBefore = Get-UsedPercent 'C'
$freeBefore = Get-FreeBytes 'C'

Say ("C 盘当前：已用 {0}%（可用 {1:N1} GB）| 模式 {2} | 目标 <= {3}%" -f `
    $usedBefore, ($freeBefore / 1GB), $Mode, $TargetPercent)

# ---------------------------------------------------------------- 无条件删除（不受 enabled/mode/targetPercent 影响）
# 例：用户明确不想保留的程序（Unity Hub）。放在 enabled/mode 检查之前，保证每次开机都执行。
# 仍受硬保护名单（Test-NeverDelete）约束。
$alwaysDelete = @(Get-Cfg $slimCfg 'alwaysDelete' @())
if ($alwaysDelete.Count -gt 0) {
    Say ("无条件删除清单：{0} 项" -f $alwaysDelete.Count)
    if (-not $DryRun) { Stop-Lockers }
    $adDone = 0; $adSkip = 0; $adGuard = 0; $adFail = 0
    foreach ($p in $alwaysDelete) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $pp = ([string]$p).TrimEnd('\')
        if (-not (Test-Path -LiteralPath $pp)) { $adSkip++; continue }
        if (Test-NeverDelete -Path $pp) { Note "受保护，拒绝删除：$pp"; $adGuard++; continue }
        if ($DryRun) { Say "[DryRun] 将删除 $pp"; continue }
        if (Remove-BigTree -Path $pp) { Say "  已删除 $pp"; $adDone++ }
        else { Warn "删除失败：$pp"; $adFail++ }
    }
    Set-GhEnv "SLIM_ALWAYS_DELETED=$adDone"
    Say ("  无条件删除结果：删除 {0} / 不存在 {1} / 受保护 {2} / 失败 {3}" -f $adDone, $adSkip, $adGuard, $adFail)
}

if (-not $enabled -or $Mode -eq 'off') {
    Say "瘦身已关闭（enabled=$enabled, mode=$Mode），跳过"
    Set-GhEnv "SLIM_STATUS=SKIPPED"
    Set-GhEnv ("SLIM_C_USED_PCT=" + $usedBefore)
    exit 0
}
if ($Mode -eq 'auto' -and $usedBefore -ge 0 -and $usedBefore -le $TargetPercent) {
    Say ("C 盘已用 {0}% <= 目标 {1}%，无需瘦身" -f $usedBefore, $TargetPercent)
    Set-GhEnv "SLIM_STATUS=SKIPPED"
    Set-GhEnv ("SLIM_C_USED_PCT=" + $usedBefore)
    exit 0
}

# ---------------------------------------------------------------- 组装目标清单
$targets = New-Object System.Collections.Generic.List[string]
foreach ($t in @(Get-Cfg $slimCfg 'targets' @())) {
    if ($null -eq $t) { continue }
    if (-not [bool](Get-Cfg $t 'enabled' $true)) { continue }
    $pth = [string](Get-Cfg $t 'path' '')
    if (-not [string]::IsNullOrWhiteSpace($pth)) { $targets.Add($pth.TrimEnd('\')) }
}
foreach ($p in @(Get-Cfg $slimCfg 'extraPaths' @())) {
    if (-not [string]::IsNullOrWhiteSpace($p)) { $targets.Add(([string]$p).TrimEnd('\')) }
}
foreach ($p in $ExtraPaths) {
    if (-not [string]::IsNullOrWhiteSpace($p)) { $targets.Add(([string]$p).TrimEnd('\')) }
}
$targetList = @($targets | Select-Object -Unique)
Say ("目标清单：{0} 项（去重后）" -f $targetList.Count)

if (-not $DryRun) { Stop-Lockers }

# ---------------------------------------------------------------- ① 真卸载「明确不要」的程序（blockedApps）
# 为什么排最前：MSI 卸载依赖 C:\Windows\Installer 里缓存的安装包 ——
# 必须在下游「清空 MSI 缓存」之前完成，否则卸载必然失败。
# 预算：整体 20 分钟；超预算的剩余项直接交给目录兜底，避免拖死开机。
$blockedApps = @()
if ($script:HasUninstallLib) { $blockedApps = @(Get-BlockedAppEntries -ConfigPath $ConfigPath) }

$uninstOk = 0; $uninstFail = 0; $uninstSkip = 0; $uninstDry = 0
if (-not $script:HasUninstallLib) {
    Note "未找到 uninstall-apps-lib.ps1，跳过程序卸载"
} elseif ($blockedApps.Count -eq 0) {
    Say "卸载清单为空（blockedApps），跳过"
} else {
    Say ("卸载清单：{0} 个程序" -f $blockedApps.Count)
    $arpEntries = @(Get-UninstallEntries)
    Say ("  ARP 条目：{0} 条（已排除系统组件）" -f $arpEntries.Count)
    $budgetEnd = (Get-Date).AddMinutes(20)

    foreach ($app in $blockedApps) {
        if ($DryRun) {
            $d = Invoke-AppUninstall -Entry $app -ArpEntries $arpEntries -DryRun
            $uninstDry++
            Say ("  [DryRun] 将卸载 {0}（{1}）" -f $app.name, $d.detail)
            foreach ($pth in @($app.paths)) {
                if (-not [string]::IsNullOrWhiteSpace($pth)) { Say ("  [DryRun] 将清理残留目录 {0}" -f $pth) }
            }
            continue
        }
        if ((Get-Date) -gt $budgetEnd) {
            Note ("  预算用尽，跳过卸载：{0}（改由目录兜底）" -f $app.name)
            $uninstSkip++
        } else {
            $r = Invoke-AppUninstall -Entry $app -ArpEntries $arpEntries -TimeoutSec 300
            if ($r.ok) {
                $uninstOk++
                Say ("  已卸载 {0}（方式 {1}）" -f $app.name, $r.method)
            } else {
                $uninstFail++
                Note ("  卸载未成功：{0}（{1}）—— 改由目录兜底" -f $app.name, $r.detail)
            }
        }
        # 无论卸载成功与否，残留目录都清一遍（MSI 卸载常留空壳目录与数据目录）
        foreach ($pth in @($app.paths)) {
            if ([string]::IsNullOrWhiteSpace($pth)) { continue }
            if (-not (Test-Path -LiteralPath $pth)) { continue }
            if (Test-NeverDelete -Path $pth) { Note "  受保护，拒绝删除：$pth"; continue }
            if (Remove-BigTree -Path $pth) { Say ("  已清理残留目录 {0}" -f $pth) }
            else { Note ("  残留目录删除未完成：{0}" -f $pth) }
        }
    }
    Set-GhEnv ("SLIM_UNINSTALL_OK=" + $uninstOk)
    Set-GhEnv ("SLIM_UNINSTALL_FAILED=" + $uninstFail)
    if ($DryRun) { Say ("  卸载计划：{0} 个（DryRun，未执行）" -f $uninstDry) }
    else { Say ("  卸载结果：成功 {0} / 未成功 {1} / 跳过 {2}" -f $uninstOk, $uninstFail, $uninstSkip) }
}

# ---------------------------------------------------------------- ② 逐个删除大件
$deleted = 0
$skipped = 0
$guarded = 0
$failed  = 0

foreach ($t in $targetList) {
    if (-not (Test-Path -LiteralPath $t)) { $skipped++; continue }
    if (Test-NeverDelete -Path $t) {
        Note "受保护，拒绝删除：$t"
        $guarded++
        continue
    }
    if ($DryRun) {
        Say "  [DryRun] 将删除 $t"
        $deleted++
        continue
    }
    $f0 = Get-FreeBytes 'C'
    $ok = Remove-BigTree -Path $t
    $f1 = Get-FreeBytes 'C'
    $freed = $f1 - $f0
    if ($freed -lt 0) { $freed = 0 }
    if ($ok) {
        $deleted++
        Say ("  已删除 {0}  （释放 {1:N1} GB）" -f $t, ($freed / 1GB))
    } else {
        $failed++
        Note ("  删除未完成（可能被占用）：{0}" -f $t)
    }
}

# ---------------------------------------------------------------- ③ 清空型目标（只清内容、保留目录本身）
# 为什么单独一套：C:\Windows\Installer 位于硬保护名单内部（C:\Windows），走 targets 必被拒；
# 但它只该「清空内容」—— 目录本身必须留着（Windows Installer 服务预期它存在）。
# 顺序：必须在上面「卸载 blockedApps」之后 —— MSI 卸载依赖缓存里的安装包。
$purgeList = @(Get-Cfg $slimCfg 'purgeContents' @())
$purgeDone = 0; $purgeSkip = 0; $purgeFail = 0; $purgeFreed = [long]0
if ($purgeList.Count -gt 0) {
    Say ("清空型目标：{0} 项" -f $purgeList.Count)
    foreach ($it in $purgeList) {
        if ($null -eq $it) { continue }
        if (-not [bool](Get-Cfg $it 'enabled' $true)) { continue }
        $pp = ([string](Get-Cfg $it 'path' '')).TrimEnd('\')
        if (-not (Test-PurgeAllowed -Path $pp)) {
            Note ("  清空型目标被守卫拒绝（需绝对路径 + 层级>=3 + 非保护目录本身）：{0}" -f $pp)
            $purgeSkip++
            continue
        }
        if (-not (Test-Path -LiteralPath $pp)) { $purgeSkip++; continue }
        if ($DryRun) { Say ("  [DryRun] 将清空 {0} 的内容（保留目录本身）" -f $pp); continue }

        $rr = Clear-DirContents -Path $pp
        $purgeFreed += [long]$rr.freedBytes
        if ($rr.ok) {
            $purgeDone++
            Say ("  已清空 {0} 的内容（释放 {1:N1} GB）" -f $pp, ($rr.freedBytes / 1GB))
        } else {
            $purgeFail++
            Note ("  清空未完成：{0}（剩余 {1} 项，可能被占用）" -f $pp, $rr.left)
        }
    }
    Set-GhEnv ("SLIM_PURGED_DIRS=" + $purgeDone)
    Set-GhEnv ("SLIM_PURGED_GB=" + [math]::Round($purgeFreed / 1GB, 1))
    Say ("  清空结果：成功 {0} / 跳过 {1} / 未完成 {2}" -f $purgeDone, $purgeSkip, $purgeFail)
}

# ---------------------------------------------------------------- ④ 残留清理（卸载器不管的部分）
# 为什么需要（真机实测 server-18）：8 个目标程序的目录都删干净了，但
#   HKLM\...\Uninstall\Unity Technologies - Hub 还在 —— 程序在「应用和功能」里
#   依旧显示已安装，用户看到的就是「未卸载成功」；另有 2 个空壳目录残留。
# 顺序：必须在 ①（真卸载）之后 —— 先让卸载器自己删，删不掉的我们再补。
$arpCleaned = 0; $arpFailed = 0; $dirsCleared = 0; $dirsLeft = 0
if ($script:HasUninstallLib -and @($blockedApps).Count -gt 0) {
    if (-not $DryRun) {
        $wingetPath = ''
        if (Get-Command Test-WingetAvailable -ErrorAction SilentlyContinue) { $wingetPath = [string](Test-WingetAvailable) }
        Say ("  winget：" + $(if ($wingetPath) { $wingetPath } else { '不可用（卸载只能靠 ARP / 目录兜底）' }))
    }
    Say ("残留清理：{0} 个程序的 ARP 卸载项 + 残留目录" -f @($blockedApps).Count)
    foreach ($app in $blockedApps) {
        if ($DryRun) { Note ("  [DryRun] 将清理 {0} 的残留卸载项与残留目录" -f $app.name); continue }
        try {
            $ra = Remove-BlockedAppArpKeys -Entry $app -ArpEntries $arpEntries -Log { param($m) Say ("    " + $m) }
            if (@($ra.removed).Count -gt 0) { $arpCleaned += @($ra.removed).Count }
            if (@($ra.failed).Count -gt 0) {
                $arpFailed += @($ra.failed).Count
                foreach ($f in @($ra.failed)) { Note ("    ARP 键删除失败：{0}" -f $f) }
            }
            $rd = Remove-BlockedAppLeftoverDirs -Entry $app -Log { param($m) Say ("    " + $m) }
            if (@($rd.removed).Count  -gt 0) { $dirsCleared += @($rd.removed).Count }
            if (@($rd.leftover).Count -gt 0) {
                $dirsLeft += @($rd.leftover).Count
                foreach ($f in @($rd.leftover)) { Note ("    残留目录仍存在：{0}" -f $f) }
            }
        } catch { Note ("  残留清理异常（{0}）：{1}" -f $app.name, $_.Exception.Message) }
    }
    Set-GhEnv ("SLIM_ARP_CLEANED="   + $arpCleaned)
    Set-GhEnv ("SLIM_ARP_FAILED="    + $arpFailed)
    Set-GhEnv ("SLIM_DIRS_CLEARED="  + $dirsCleared)
    Set-GhEnv ("SLIM_DIRS_LEFTOVER=" + $dirsLeft)
    Say ("  残留清理结果：ARP 键清除 {0}（失败 {1}）/ 残留目录清除 {2}（仍剩 {3}）" -f `
         $arpCleaned, $arpFailed, $dirsCleared, $dirsLeft)
} else {
    Say "残留清理：跳过（未加载卸载库，或 blockedApps 清单为空）"
}

# ---------------------------------------------------------------- 附加优化
if (-not $DryRun) {
    if ([bool](Get-Cfg $slimCfg 'disableHibernation' $true)) {
        if (Test-Path -LiteralPath 'C:\hiberfil.sys') {
            $f0 = Get-FreeBytes 'C'
            & powercfg.exe /hibernate off 2>&1 | Out-Null
            $f1 = Get-FreeBytes 'C'
            $g = ($f1 - $f0) / 1GB
            if ($g -lt 0) { $g = 0 }
            Say ("  已关闭休眠（hiberfil.sys），释放 {0:N1} GB" -f $g)
        }
    }
    if ([bool](Get-Cfg $slimCfg 'runDismComponentCleanup' $false)) {
        Say "  执行 DISM 组件清理（可能数分钟）…"
        & dism.exe /Online /Cleanup-Image /StartComponentCleanup 2>&1 | Out-Null
        Say "  DISM 组件清理完成"
    }
}

# ---------------------------------------------------------------- 结果
$usedAfter = Get-UsedPercent 'C'
$freeAfter = Get-FreeBytes 'C'
$freedTotal = $freeAfter - $freeBefore
if ($freedTotal -lt 0) { $freedTotal = 0 }

$status = "PARTIAL"
if ($DryRun) { $status = "DRYRUN" }
elseif ($usedAfter -ge 0 -and $usedAfter -le $TargetPercent) { $status = "OK" }
elseif ($deleted -eq 0 -and $uninstOk -eq 0 -and $purgeDone -eq 0 -and $arpCleaned -eq 0) { $status = "SKIPPED" }

Say ("瘦身结果：C 盘已用 {0}% -> {1}%（释放 {2:N1} GB）| 删除 {3} / 跳过 {4} / 受保护 {5} / 失败 {6}" -f `
    $usedBefore, $usedAfter, ($freedTotal / 1GB), $deleted, $skipped, $guarded, $failed)
Say ("  卸载 {0}（未成功 {1} / 跳过 {2}）| 清空型目标 {3} 项（释放 {4:N1} GB / 未完成 {5}）" -f `
    $uninstOk, $uninstFail, $uninstSkip, $purgeDone, ($purgeFreed / 1GB), $purgeFail)
if ($status -eq "PARTIAL") {
    Note ("瘦身后 C 盘仍为 {0}%（目标 {1}%）—— 可能还有未列入清单的大件；把路径加到 slim.targets 即可" -f $usedAfter, $TargetPercent)
}

Set-GhEnv ("SLIM_STATUS=" + $status)
Set-GhEnv ("SLIM_FREED_GB=" + [math]::Round($freedTotal / 1GB, 1))
Set-GhEnv ("SLIM_C_USED_PCT=" + $usedAfter)
Set-GhEnv ("SLIM_TARGETS_DELETED=" + $deleted)
Set-GhEnv ("SLIM_TARGETS_GUARDED=" + $guarded)

exit 0
