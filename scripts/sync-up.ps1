<#
.SYNOPSIS
  把本地 C:\data 推回 139 云盘（运行中定期调用 + 收尾全量调用）。
.NOTES
  用 rclone copy（只增不删），避免远端误删。
  远端路径: alist:/cloudrdp/CloudRDP
  本地路径: C:\data
  139 走 WebDAV 上传大文件有 5 分钟超时风险，故加 --timeout 0 --contimeout 0。
#>

param(
    [string]$Local  = "C:\data",
    [string]$Remote = "alist:/cloudrdp/CloudRDP"
)

$RcloneExe = "C:\rclone\rclone.exe"
if (-not (Test-Path $RcloneExe)) { Write-Warning "[sync-up] 未找到 rclone，跳过"; exit 0 }
if (-not (Test-Path $Local))    { Write-Host "[sync-up] 本地 $Local 不存在，跳过"; exit 0 }

# 确保远端目录存在（本地为空时 rclone copy 不会创建目录）
& $RcloneExe mkdir $Remote --timeout 0 --contimeout 0 2>&1 | Out-Null

Write-Host "[sync-up] $Local  ->  $Remote"
& $RcloneExe copy $Local $Remote `
    --update --create-empty-src-dirs `
    --transfers 4 --checkers 8 `
    --timeout 0 --contimeout 0 `
    --retries 3 --low-level-retries 5 `
    --stats-one-line -v

if ($LASTEXITCODE -eq 0) {
    Write-Host "[sync-up] 完成"
} else {
    Write-Warning "[sync-up] rclone 退出码 $LASTEXITCODE（139 Authorization 过期或大文件超时）"
}
exit 0
