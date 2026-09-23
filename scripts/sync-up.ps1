<#
.SYNOPSIS
  把本地数据目录推回 139 云盘（运行中定期调用 + 收尾全量调用）。
.NOTES
  用 rclone copy（只增不删），避免远端误删。
  远端路径: alist:/cloudrdp/AI文件库/CloudRDP
  本地路径: D:\a\cloud-rdp

  ⚠️ 关键：本地数据目录是 Actions 工作区的**父目录**（工作区 = D:\a\<仓库名>\<仓库名>），
     仓库 checkout 就落在它下面（D:\a\cloud-rdp\cloud-rdp）。**必须排除**，否则会把
     整个仓库（含 .git）同步到云盘。排除规则见下方。

  139 走 WebDAV 上传大文件有 5 分钟超时风险，故加 --timeout 0 --contimeout 0。

  ⚠️ 防污染（acc-1 事故教训）—— 两道守卫，任一不过就整段跳过：
     守卫 A：推之前**先证明 139 根可列**。探不到就跳过 —— 绝不在 139 根 mkdir，
             否则会造出一个「幽灵 AI文件库」目录，把后续「远端为空」的判定带偏。
     守卫 B：本次开机「数据恢复」没成功（TRANSIENT / FAILED / PENDING）时拒绝推送 ——
             本地此刻是**未还原的空壳**，推上去会把 139 上的好数据覆盖掉。
             确认无误可加 -Force 强制推送。

.PARAMETER Force  跳过守卫 B（数据恢复状态不佳也强制推送）。守卫 A 无法跳过。
#>

param(
    [string]$Local  = $(if ($env:CLOUDRDP_DATA_DIR)    { $env:CLOUDRDP_DATA_DIR }    else { "D:\a\cloud-rdp" }),
    [string]$Remote = $(if ($env:CLOUDRDP_REMOTE_BASE) { $env:CLOUDRDP_REMOTE_BASE + "/CloudRDP" } else { "alist:/cloudrdp/AI文件库/CloudRDP" }),
    [string]$RemoteRoot = "",
    [string[]]$Exclude = @(),
    [int]$ProbeAttempts   = 3,
    [int]$ProbeDelaySec   = 6,
    [int]$ProbeTimeoutSec = 25,
    [switch]$Force
)

# 统一系统目录：rclone 装在 D 盘（C 盘只保留 runner 镜像基线，不额外占用）
$SysDir    = if ($env:CLOUDRDP_SYS_DIR) { $env:CLOUDRDP_SYS_DIR } elseif (Test-Path 'D:\') { "D:\cloudrdp-sys" } else { "C:\cloudrdp-sys" }
$RcloneExe = if ($env:CLOUDRDP_RCLONE_EXE) { $env:CLOUDRDP_RCLONE_EXE } else { Join-Path $SysDir "rclone\rclone.exe" }
if (-not (Test-Path $RcloneExe)) { Write-Warning "[sync-up] 未找到 rclone，跳过"; exit 0 }
if (-not (Test-Path $Local))    { Write-Host "[sync-up] 本地 $Local 不存在，跳过"; exit 0 }

# 远端判定共享库（与 sync-down / pre-restore 同源，口径一致）
$remoteLib    = Join-Path $PSScriptRoot "remote-lib.ps1"
$hasRemoteLib = Test-Path -LiteralPath $remoteLib
if ($hasRemoteLib) { . $remoteLib }
else { Write-Warning "[sync-up] 未找到 remote-lib.ps1，远端可达性判定退化为「直接 lsf 根目录」" }

# ---------- 计算排除规则 ----------
# 1) 固定防御：.git / _temp
# 2) 动态：由 GITHUB_WORKSPACE 相对 $Local 求出仓库 checkout 目录名
# 3) 兜底：仓库名恰为 cloud-rdp
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

# ---------- 守卫 A：139 根必须可列（否则绝不 mkdir / copy）----------
$rootOk = $false
if ($hasRemoteLib) {
    $rootOk = [bool](Test-AlistRemoteReachable -RcloneExe $RcloneExe -Remote $Remote -Root $RemoteRoot `
                 -Attempts $ProbeAttempts -DelaySec $ProbeDelaySec -TimeoutSec $ProbeTimeoutSec -Quiet)
} else {
    $rroot = if (-not [string]::IsNullOrWhiteSpace($RemoteRoot)) { $RemoteRoot }
             elseif ($env:CLOUDRDP_REMOTE_ROOT) { $env:CLOUDRDP_REMOTE_ROOT }
             elseif ($env:CLOUDRDP_REMOTE_BASE) { ((($env:CLOUDRDP_REMOTE_BASE -split '/')[0..1]) -join '/') }
             else { 'alist:/cloudrdp' }
    & $RcloneExe lsf $rroot --max-depth 1 --timeout "$($ProbeTimeoutSec)s" --contimeout "$($ProbeTimeoutSec)s" --retries 1 --low-level-retries 1 2>&1 | Out-Null
    $rootOk = ($LASTEXITCODE -eq 0)
}
if (-not $rootOk) {
    Write-Warning "[sync-up] 139 根目录不可达（网络抖动或鉴权过期）—— 本次不推送，避免在 139 根留下幽灵目录"
    exit 0
}

# ---------- 守卫 B：数据恢复未成功时拒绝推送 ----------
if (-not $Force) {
    $dataStatus = ''
    if ($hasRemoteLib) { $dataStatus = [string](Get-RestoreStatusValue -Scope data -SysDir $SysDir) }

    if ($dataStatus -in @('TRANSIENT', 'FAILED', 'PENDING')) {
        Write-Warning "[sync-up] 本次开机数据恢复状态 = $dataStatus（未成功）—— 拒绝推送，以免用未还原的本地状态覆盖 139。确认无误请加 -Force"
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($dataStatus) -and $hasRemoteLib) {
        # 没有状态记录（非 workflow 调用 / 极早期）→ 远端已有数据就保守拒绝
        $pp    = Get-RemoteProbe -RcloneExe $RcloneExe -Remote $Remote -Root $RemoteRoot -TimeoutSec $ProbeTimeoutSec
        $leafN = @($pp.LeafNames).Count
        if ($pp.Verdict -eq 'OK' -and $leafN -gt 0) {
            Write-Warning "[sync-up] 无数据恢复状态记录，而远端已有数据（$leafN 项）—— 保守拒绝推送。确认无误请加 -Force"
            exit 0
        }
        if ($pp.Verdict -eq 'TRANSIENT' -or $pp.Verdict -eq 'AUTH') {
            Write-Warning "[sync-up] 无数据恢复状态记录，且远端不可判（$($pp.Verdict)）—— 本次不推送"
            exit 0
        }
    }
}

# 确保远端目录存在（本地为空时 rclone copy 不会创建目录）
& $RcloneExe mkdir $Remote --timeout 0 --contimeout 0 2>&1 | Out-Null

Write-Host "[sync-up] $Local  ->  $Remote"
Write-Host ("[sync-up] 排除: " + ($excludeList -join ' '))

$rcArgs = @(
    "copy", $Local, $Remote,
    "--update", "--create-empty-src-dirs",
    "--transfers", "4", "--checkers", "8",
    "--timeout", "0", "--contimeout", "0",
    "--retries", "3", "--low-level-retries", "5",
    "--stats-one-line", "-v"
)
foreach ($ex in $excludeList) { $rcArgs += @("--exclude", $ex) }

& $RcloneExe @rcArgs

if ($LASTEXITCODE -eq 0) {
    Write-Host "[sync-up] 完成"
} else {
    Write-Warning "[sync-up] rclone 退出码 $LASTEXITCODE（139 Authorization 过期或大文件超时）"
}
exit 0
