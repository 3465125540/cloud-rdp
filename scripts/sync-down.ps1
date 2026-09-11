<#
.SYNOPSIS
  开机时从 139 云盘把数据拉取到本地 C:\data。
.NOTES
  依赖 setup-rclone.ps1 已配置好 remote: alist
  远端路径: alist:/cloudrdp/CloudRDP
  本地路径: C:\data
  首次运行远端为空属正常，不影响启动。
#>

param(
    [string]$Remote = "alist:/cloudrdp/CloudRDP",
    [string]$Local  = "C:\data"
)

$RcloneExe = "C:\rclone\rclone.exe"
if (-not (Test-Path $RcloneExe)) { Write-Warning "[sync-down] 未找到 rclone，跳过"; exit 0 }

New-Item -ItemType Directory -Force -Path $Local | Out-Null

Write-Host "[sync-down] $Remote  ->  $Local"
& $RcloneExe copy $Remote $Local `
    --update `
    --transfers 4 --checkers 8 `
    --timeout 0 --contimeout 0 `
    --retries 3 --low-level-retries 5 `
    --stats-one-line -v

if ($LASTEXITCODE -ne 0) {
    Write-Warning "[sync-down] rclone 退出码 $LASTEXITCODE（首次运行远端为空、或 139 Authorization 过期时会出现）"
} else {
    Write-Host "[sync-down] 完成"
}
