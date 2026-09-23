<#
.SYNOPSIS
  开机时从 139 云盘恢复数据到本地数据目录（先判「瞬时故障 vs 真的没有」，再决定拉不拉）。

.DESCRIPTION
  依赖 setup-rclone.ps1 已配置好 remote: alist
  远端路径: alist:/cloudrdp/AI文件库/CloudRDP
  本地路径: D:\a\cloud-rdp

  ⚠️ 本地数据目录是 Actions 工作区的父目录，仓库 checkout 在其下（D:\a\cloud-rdp\cloud-rdp），
     必须排除，避免远端同名目录反向覆盖仓库。排除规则见下方。

  ── 为什么不再拿 rclone 退出码当结论 ──
  139 的 DNS 抖动几秒 → AList 对 WebDAV PROPFIND 回 404 → rclone 把 404 归类成「目录不存在」→
  退出码 3。旧逻辑见 3/4 就写 RESTORE_STATUS=EMPTY，等于把「网络抖了一下」记成「远端本来就是空的」：
  开机日志照样报成功，实际一个文件都没拉回来。
  本脚本改为「先探再拉」：
    ① 逐级列目录探测，判定 OK / EMPTY / TRANSIENT / AUTH（判定逻辑见 remote-lib.ps1）；
    ② 只有 OK 才真正 copy；EMPTY 直接收工；TRANSIENT 不拉、报 TRANSIENT，交给保活循环自愈；
    ③ 拉取失败后再复探一次，只有复探确认「远端真的空」才报 EMPTY。

  本脚本永不返回非 0（不阻断 RDP 启动）。状态透出：
    RESTORE_STATUS / RESTORE_REASON（GITHUB_ENV）+ <SysDir>\_state\restore-status.json

.PARAMETER Repull  保活循环里的「自愈重拉」：日志带 :repull 前缀，不写遗留标记文件（少碰数据目录）。
#>
[CmdletBinding()]
param(
    [string]$RemoteBase = $(if ($env:CLOUDRDP_REMOTE_BASE) { $env:CLOUDRDP_REMOTE_BASE } else { "alist:/cloudrdp/AI文件库" }),
    [string]$Remote,                                   # 可选：直接覆盖完整远端路径
    [string]$Local  = $(if ($env:CLOUDRDP_DATA_DIR) { $env:CLOUDRDP_DATA_DIR } else { "D:\a\cloud-rdp" }),
    [int]$MaxAttempts = 3,
    [int]$RetryDelaySec = 8,
    [int]$ProbeAttempts = 3,
    [int]$ProbeDelaySec = 6,
    [int]$ProbeTimeoutSec = 25,
    [switch]$Repull,
    [string[]]$Exclude = @()
)

$ErrorActionPreference = "Continue"
# 统一系统目录：rclone 装在 D 盘（C 盘只保留 runner 镜像基线，不额外占用）
$SysDir    = if ($env:CLOUDRDP_SYS_DIR) { $env:CLOUDRDP_SYS_DIR } elseif (Test-Path 'D:\') { "D:\cloudrdp-sys" } else { "C:\cloudrdp-sys" }
# rclone 位置：默认 <SysDir>\rclone\rclone.exe；可用 CLOUDRDP_RCLONE_EXE 覆盖（本地联调 / 单测用）
$RcloneExe = if ($env:CLOUDRDP_RCLONE_EXE) { $env:CLOUDRDP_RCLONE_EXE } else { Join-Path $SysDir "rclone\rclone.exe" }
$tag       = if ($Repull) { "sync-down:repull" } else { "sync-down" }

function Say([string]$m)  { Write-Host "[$tag] $m" }
function Warn([string]$m) { Write-Warning "[$tag] $m" }

# ---------------------------------------------------------------- 共享判定库
$lib = Join-Path $PSScriptRoot "remote-lib.ps1"
if (-not (Test-Path -LiteralPath $lib)) {
    Warn "未找到 remote-lib.ps1 —— 无法判定远端状态，跳过恢复（宁可不恢复，也不误报成功）"
    exit 0
}
. $lib

if ([string]::IsNullOrWhiteSpace($Remote)) { $Remote = $RemoteBase.TrimEnd('/') + "/CloudRDP" }

New-Item -ItemType Directory -Force -Path $Local | Out-Null

# 状态落盘的公共参数（Scope 由各调用点显式给；repull 时不写遗留标记文件，避免每 10 分钟往数据目录里写东西）
$stCommon = @{ Local = $Local; SysDir = $SysDir; Remote = $Remote; KeepLegacyMarker = (-not $Repull) }

# rclone 缺失：旧版是静默 exit 0（连状态都不写，日志里什么都看不到）—— 现在必须显式报出来
if (-not (Test-Path -LiteralPath $RcloneExe)) {
    Warn "未找到 rclone（$RcloneExe）—— 无法恢复数据"
    Set-RestoreStatus -Status 'FAILED' -Reason "未找到 rclone：$RcloneExe" @stCommon
    exit 0
}

# ---------------------------------------------------------------- 计算排除规则（与 sync-up 保持一致）
$excludeList = @("/.git/**", "/_temp/**", "/cloud-rdp/**")
$ws = $env:GITHUB_WORKSPACE
if (-not [string]::IsNullOrWhiteSpace($ws)) {
    $wsFull    = $ws.TrimEnd('\')
    $localFull = $Local.TrimEnd('\')
    if ($wsFull.Length -gt $localFull.Length -and $wsFull.ToLower().StartsWith($localFull.ToLower())) {
        $rel = $wsFull.Substring($localFull.Length).TrimStart('\') -replace '\\', '/'
        if ($rel) { $excludeList += ("/" + $rel + "/**") }
    }
}
if ($Exclude) { $excludeList += $Exclude }
$excludeList = @($excludeList | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

Say "目标: $Remote  ->  $Local"
Say ("排除: " + ($excludeList -join ' '))

# ---------------------------------------------------------------- ① 探测：先证明「能不能看见」，再谈「有没有」
Say "探测远端可达性（最多 $ProbeAttempts 次）……"
$probe = Resolve-RemoteVerdict -RcloneExe $RcloneExe -Remote $Remote `
         -Attempts $ProbeAttempts -DelaySec $ProbeDelaySec -TimeoutSec $ProbeTimeoutSec
Say ("探测结果: " + $probe.Verdict + " —— " + $probe.Message)

if ($probe.Verdict -eq 'EMPTY') {
    Say "远端确实还没有数据（首次运行正常），本地留空"
    Set-RestoreStatus -Status 'EMPTY' -Reason $probe.Message -Scope data `
                      @stCommon
    exit 0
}
if ($probe.Verdict -eq 'AUTH') {
    Warn "139 鉴权失败（Authorization 大概率已过期）—— 本次不拉取"
    Set-RestoreStatus -Status 'FAILED' -Reason ("AUTH: " + $probe.Message) -Scope data `
                      @stCommon
    exit 0
}
if ($probe.Verdict -ne 'OK') {
    Warn "远端不可达（$($probe.Verdict)）—— 这是网络/后端瞬时故障，**不是**「远端为空」；"
    Warn "  本次不拉取，保活循环每 10 分钟会自愈重拉，DNS/网络恢复后自动补齐。"
    Set-RestoreStatus -Status 'TRANSIENT' -Reason $probe.Message -Scope data `
                      @stCommon
    exit 0
}

# ---------------------------------------------------------------- ② 确认远端有东西，才真正拉
$restored = $false
$lastCode = 0
for ($i = 1; $i -le $MaxAttempts; $i++) {
    $rcArgs = @(
        "copy", $Remote, $Local,
        "--update",
        "--transfers", "4", "--checkers", "8",
        "--timeout", "0", "--contimeout", "0",
        "--retries", "3", "--low-level-retries", "5",
        "--stats-one-line", "-v"
    )
    foreach ($ex in $excludeList) { $rcArgs += @("--exclude", $ex) }

    & $RcloneExe @rcArgs
    $lastCode = $LASTEXITCODE
    if ($lastCode -eq 0) { $restored = $true; break }
    if ($i -lt $MaxAttempts) {
        Warn "第 $i/$MaxAttempts 次拉取失败（rclone 码 $lastCode），$RetryDelaySec 秒后重试……"
        Start-Sleep -Seconds $RetryDelaySec
    }
}

if ($restored) {
    $files = @(Get-ChildItem $Local -Recurse -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -notlike "_RESTORE_*.txt" })
    $bytes = ($files | Measure-Object -Property Length -Sum).Sum
    if (-not $bytes) { $bytes = 0 }
    Say ("OK 恢复完成：{0} 个文件，{1:N2} MB" -f $files.Count, ($bytes / 1MB))
    if ($files.Count -eq 0) {
        Warn "远端 $Remote 当前是空目录（$($probe.LeafNames.Count) 项）—— 本次没有文件可恢复"
    }
    $why = ("恢复 {0} 个文件 / {1:N2} MB" -f $files.Count, ($bytes / 1MB))
    Set-RestoreStatus -Status 'OK' -Reason $why -Scope data `
                      @stCommon
    exit 0
}

# ---------------------------------------------------------------- ③ 拉取失败：复探一次，区分「其实空」与「网络抖」
$again = Resolve-RemoteVerdict -RcloneExe $RcloneExe -Remote $Remote -Attempts 2 -DelaySec 4 -TimeoutSec $ProbeTimeoutSec
Say ("失败后复探: " + $again.Verdict + " —— " + $again.Message)

if ($again.Verdict -eq 'EMPTY') {
    Say "复探确认远端确实为空（copy 码 $lastCode）—— 视为首次运行"
    Set-RestoreStatus -Status 'EMPTY' -Reason ("copy 码 $lastCode，复探确认为空：" + $again.Message) -Scope data `
                      @stCommon
    exit 0
}
if ($again.Verdict -eq 'AUTH') {
    Warn "139 鉴权失败（Authorization 大概率已过期）"
    Set-RestoreStatus -Status 'FAILED' -Reason ("AUTH: " + $again.Message) -Scope data `
                      @stCommon
    exit 0
}
if ($again.Verdict -eq 'OK') {
    Warn "远端可达但拉取失败（rclone 码 $lastCode）—— 多半是单个文件/本地磁盘问题，保活循环会重试"
    Set-RestoreStatus -Status 'FAILED' -Reason ("远端可达但 copy 失败（rclone 码 $lastCode）") -Scope data `
                      @stCommon
    exit 0
}

Warn "数据恢复失败（rclone 码 $lastCode；复探 $($again.Verdict)）—— 保活循环会继续自愈重试"
Set-RestoreStatus -Status 'TRANSIENT' -Reason ("copy 码 $lastCode；" + $again.Message) -Scope data `
                  -Local $Local -SysDir $SysDir -Remote $Remote -KeepLegacyMarker
exit 0
