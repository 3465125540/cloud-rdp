<#
.SYNOPSIS
  C 盘占用守卫：测量 → 记录基线 → 校验「我们的增量」是否超限 → 必要时安全清理 → 透出状态。

.DESCRIPTION
  为什么不是「C 盘占用 ≤ 30%」：
    GitHub 托管的 Windows runner，C 盘 150 GB 里约 120 GB 是**镜像自带**的
    （Visual Studio 2022 / Android SDK / hostedtoolcache / Azure CLI 等），开机即 ~80%。
    这个基线动不了（删它要 10-25 分钟且会破坏依赖工具链的程序）。
  所以本脚本保证的是**我们产生的增量**：

      增量 = 当前 C: 已用 − 开机基线已用   ≤  基线可用空间 × MaxIncrementalPercent%

  默认 30% × 约 31 GB ≈ 9.3 GB。我们的所有产物（数据 / 快照暂存 / rclone / AList /
  还原的程序实体）都放 D 盘，正常情况下增量接近 0。

  超出且带 -Enforce 时执行一组**安全清理**：临时目录、Windows 更新缓存、
  安装包残留、遗留的旧 C:\_snapshot 等，然后重新测量。

.PARAMETER Baseline
  记录（或重置）基线。开机早期调用一次。

.PARAMETER Enforce
  超限时执行清理。

.NOTES
  本脚本永不返回非 0。透出环境变量：
    DISK_C_TOTAL_GB / DISK_C_USED_GB / DISK_C_USED_PCT / DISK_C_FREE_GB
    DISK_C_DELTA_MB / DISK_C_LIMIT_MB / DISK_D_FREE_GB
    DISK_GUARD_STATUS = BASELINE | OK | FIXED | OVER | UNKNOWN
#>
[CmdletBinding()]
param(
    [string]$SysDir = "",
    [int]   $MaxIncrementalPercent = 30,
    [int]   $MaxIncrementalMB = 0,        # 0 = 按百分比；>0 = 用绝对上限
    [switch]$Baseline,
    [switch]$Enforce,
    [switch]$Quiet
)

$ErrorActionPreference = "Continue"

# 从 snapshot-config.json 读取 disk.* 配置（命令行显式传入的参数优先）
$cfgPath = Join-Path $PSScriptRoot "snapshot-config.json"
if (Test-Path -LiteralPath $cfgPath) {
    try {
        $cfgAll = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $dk = $cfgAll.disk
        if ($dk) {
            if (-not $PSBoundParameters.ContainsKey('MaxIncrementalPercent') -and $null -ne $dk.maxIncrementalPercent) {
                $MaxIncrementalPercent = [int]$dk.maxIncrementalPercent
            }
            if (-not $PSBoundParameters.ContainsKey('MaxIncrementalMB') -and $null -ne $dk.maxIncrementalMB) {
                $MaxIncrementalMB = [int]$dk.maxIncrementalMB
            }
        }
    } catch { }
}

if ([string]::IsNullOrWhiteSpace($SysDir)) {
    $SysDir = if ($env:CLOUDRDP_SYS_DIR) { $env:CLOUDRDP_SYS_DIR } elseif (Test-Path 'D:\') { "D:\cloudrdp-sys" } else { "C:\cloudrdp-sys" }
}

function Set-GhEnv([string]$kv) {
    if ($env:GITHUB_ENV) { $kv | Out-File $env:GITHUB_ENV -Append -Encoding ascii }
}
function Say([string]$m)   { if (-not $Quiet) { Write-Host "[disk] $m" } }
function Note([string]$m)  { if (-not $Quiet) { Write-Warning "[disk] $m" } }

function Get-VolumeStat {
    param([string]$DriveLetter)
    $d = Get-PSDrive -Name $DriveLetter -ErrorAction SilentlyContinue
    if ($null -eq $d) { return $null }
    $used  = [long]$d.Used
    $free  = [long]$d.Free
    $total = $used + $free
    if ($total -le 0) { return $null }
    return [pscustomobject]@{
        drive      = $DriveLetter
        totalBytes = $total
        usedBytes  = $used
        freeBytes  = $free
        usedPct    = [math]::Round($used * 100.0 / $total, 1)
    }
}

# ---------------------------------------------------------------- 受保护路径
# 清理时绝不触碰：数据目录、快照暂存、系统目录自身，以及它们的父目录
$protect = New-Object System.Collections.Generic.List[string]
if ($env:CLOUDRDP_SNAPSHOT_STAGE) { $protect.Add($env:CLOUDRDP_SNAPSHOT_STAGE.TrimEnd('\')) }
if ($env:CLOUDRDP_DATA_DIR)       { $protect.Add($env:CLOUDRDP_DATA_DIR.TrimEnd('\')) }
$protect.Add($SysDir.TrimEnd('\'))

function Test-Protected {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
    $p = $Path.TrimEnd('\').ToLower()
    foreach ($x in $protect) {
        $xl = $x.ToLower()
        if ($p -eq $xl) { return $true }
        if ($p.StartsWith($xl + "\")) { return $true }      # 在受保护目录内部
        if ($xl.StartsWith($p + "\")) { return $true }      # 是受保护目录的父目录
    }
    return $false
}

function Remove-PathQuiet {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try { Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

# ---------------------------------------------------------------- 安全清理
function Invoke-SafeCleanup {
    $done = New-Object System.Collections.Generic.List[string]

    $dirs = New-Object System.Collections.Generic.List[string]
    if ($env:TEMP) { $dirs.Add($env:TEMP) }
    $dirs.Add("C:\Windows\Temp")
    $dirs.Add("C:\Windows\SoftwareDistribution\Download")
    $dirs.Add("C:\Windows\LiveKernelReports")
    $dirs.Add("C:\Windows\Logs\CBS")
    if ($env:LOCALAPPDATA) { $dirs.Add((Join-Path $env:LOCALAPPDATA "Temp\WinGet")) }
    foreach ($u in @(Get-ChildItem 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue)) {
        $dirs.Add((Join-Path $u.FullName "AppData\Local\Temp"))
    }

    foreach ($d in $dirs) {
        if ([string]::IsNullOrWhiteSpace($d)) { continue }
        if (Test-Protected -Path $d) { continue }
        if (-not (Test-Path -LiteralPath $d)) { continue }
        Remove-PathQuiet -Path $d
        $done.Add($d)
    }

    # 明确的安装包 / 遗留物清单（旧 C 盘布局）
    $legacy = @(
        "C:\tailscale.msi",
        "C:\rclone.zip",
        "C:\rclone-tmp",
        "C:\alist.zip",
        "C:\_snapshot"
    )
    foreach ($f in $legacy) {
        if (Test-Protected -Path $f) { continue }
        if (-not (Test-Path -LiteralPath $f)) { continue }
        Remove-PathQuiet -Path $f
        $done.Add($f)
    }

    return $done.ToArray()
}

# ---------------------------------------------------------------- 主流程
$c = Get-VolumeStat 'C'
$dStat = Get-VolumeStat 'D'

if ($null -eq $c) {
    Say "无法读取 C 盘信息，跳过守卫"
    Set-GhEnv "DISK_GUARD_STATUS=UNKNOWN"
    exit 0
}

$stateDir = Join-Path $SysDir "_state"
try { New-Item -ItemType Directory -Force -Path $stateDir | Out-Null } catch { }
$baseFile = Join-Path $stateDir "disk-baseline.json"

$base = $null
if (Test-Path -LiteralPath $baseFile) {
    try { $base = Get-Content -LiteralPath $baseFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $base = $null }
}

$status     = "OK"
$deltaBytes = [long]0
$limitBytes = [long]0

if ($Baseline -or $null -eq $base -or -not $base.cUsedBytes) {
    $obj = [pscustomobject]@{
        recordedUtc           = (Get-Date).ToUniversalTime().ToString('o')
        cTotalBytes           = $c.totalBytes
        cUsedBytes            = $c.usedBytes
        cFreeBytes            = $c.freeBytes
        cUsedPct              = $c.usedPct
        maxIncrementalPercent = $MaxIncrementalPercent
    }
    try { $obj | ConvertTo-Json -Depth 4 | Out-File -LiteralPath $baseFile -Encoding UTF8 } catch { }
    $base   = $obj
    $status = "BASELINE"
    Say ("基线已记录：C 盘已用 {0:N1} / {1:N1} GB（{2}%），可用 {3:N1} GB" -f `
        ($c.usedBytes / 1GB), ($c.totalBytes / 1GB), $c.usedPct, ($c.freeBytes / 1GB))
    Say ("  基线可用 {0:N1} GB 的 {1}% = 本次增量上限 {2:N1} GB" -f `
        ($c.freeBytes / 1GB), $MaxIncrementalPercent, ($c.freeBytes * $MaxIncrementalPercent / 100.0 / 1GB))
} else {
    $deltaBytes = $c.usedBytes - [long]$base.cUsedBytes
    if ($MaxIncrementalMB -gt 0) {
        $limitBytes = [long]$MaxIncrementalMB * 1MB
    } else {
        $limitBytes = [long][math]::Round([long]$base.cFreeBytes * $MaxIncrementalPercent / 100.0)
    }
    if ($deltaBytes -gt $limitBytes) { $status = "OVER" }
}

if ($status -eq "OVER" -and $Enforce) {
    Note ("C 盘增量 {0:N0} MB 超限（上限 {1:N0} MB），执行安全清理…" -f ($deltaBytes / 1MB), ($limitBytes / 1MB))
    $cleaned = Invoke-SafeCleanup
    foreach ($x in $cleaned) { Say "  已清理 $x" }
    $beforeFix = $c.usedBytes
    $c = Get-VolumeStat 'C'
    $freed = [long]$beforeFix - [long]$c.usedBytes
    if ($freed -lt 0) { $freed = 0 }
    Say ("清理释放 {0:N0} MB" -f ($freed / 1MB))
    $deltaBytes = $c.usedBytes - [long]$base.cUsedBytes
    if ($deltaBytes -le $limitBytes) { $status = "FIXED" } else { $status = "OVER" }
}

# ---------------------------------------------------------------- 报告
$deltaMB = [math]::Round($deltaBytes / 1MB, 0)
$limitMB = [math]::Round($limitBytes / 1MB, 0)

Say ("C 盘：已用 {0:N1} / {1:N1} GB（{2}%）| 可用 {3:N1} GB" -f `
    ($c.usedBytes / 1GB), ($c.totalBytes / 1GB), $c.usedPct, ($c.freeBytes / 1GB))
if ($dStat) {
    Say ("D 盘：已用 {0:N1} / {1:N1} GB（{2}%）| 可用 {3:N1} GB" -f `
        ($dStat.usedBytes / 1GB), ($dStat.totalBytes / 1GB), $dStat.usedPct, ($dStat.freeBytes / 1GB))
}
if ($status -ne "BASELINE") {
    Say ("本次增量 {0:N0} MB（上限 {1:N0} MB）→ {2}" -f $deltaMB, $limitMB, $status)
}

switch ($status) {
    "OK"       { Say "✅ 我们的 C 盘增量在限额内" }
    "FIXED"    { Say "✅ 清理后已回到限额内" }
    "OVER"     { Note ("⚠️ C 盘增量仍超限：{0:N0} MB > {1:N0} MB。建议把大文件放 D 盘，或调大 files.maxTotalMB / 检查是否有程序装到了 C 盘" -f $deltaMB, $limitMB) }
    "BASELINE" { }
}

Set-GhEnv ("DISK_C_TOTAL_GB=" + [math]::Round($c.totalBytes / 1GB, 1))
Set-GhEnv ("DISK_C_USED_GB="  + [math]::Round($c.usedBytes / 1GB, 1))
Set-GhEnv ("DISK_C_USED_PCT=" + $c.usedPct)
Set-GhEnv ("DISK_C_FREE_GB="  + [math]::Round($c.freeBytes / 1GB, 1))
Set-GhEnv ("DISK_C_DELTA_MB=" + $deltaMB)
Set-GhEnv ("DISK_C_LIMIT_MB=" + $limitMB)
Set-GhEnv ("DISK_GUARD_STATUS=" + $status)
if ($dStat) { Set-GhEnv ("DISK_D_FREE_GB=" + [math]::Round($dStat.freeBytes / 1GB, 1)) }

exit 0
