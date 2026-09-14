<#
.SYNOPSIS
  把本地数据目录推回 139 云盘（运行中定期调用 + 收尾全量调用）。
.NOTES
  用 rclone copy（只增不删），避免远端误删。
  远端路径: alist:/cloudrdp/AI文件库/CloudRDP
  本地路径: D:\a\cloud-rdp

  ⚠️ 关键：本地数据目录是 Actions 工作区的**父目录**（工作区 = D:\a\<仓库名>\<仓库名>），
     仓库 checkout 就落在它下面（D:\a\cloud-rdp\cloud-rdp）。**必须排除**，否则会把
     整个仓库（含 .git）同步到云盘。排除规则见下方 Get-SyncExclude。

  139 走 WebDAV 上传大文件有 5 分钟超时风险，故加 --timeout 0 --contimeout 0。
#>

param(
    [string]$Local  = $(if ($env:CLOUDRDP_DATA_DIR)    { $env:CLOUDRDP_DATA_DIR }    else { "D:\a\cloud-rdp" }),
    [string]$Remote = $(if ($env:CLOUDRDP_REMOTE_BASE) { $env:CLOUDRDP_REMOTE_BASE + "/CloudRDP" } else { "alist:/cloudrdp/AI文件库/CloudRDP" }),
    [string[]]$Exclude = @()
)

$RcloneExe = "C:\rclone\rclone.exe"
if (-not (Test-Path $RcloneExe)) { Write-Warning "[sync-up] 未找到 rclone，跳过"; exit 0 }
if (-not (Test-Path $Local))    { Write-Host "[sync-up] 本地 $Local 不存在，跳过"; exit 0 }

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
