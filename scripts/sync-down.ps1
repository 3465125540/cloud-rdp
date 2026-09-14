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

# 首次运行远端目录还不存在时，rclone 退出码 3/4 属正常，不应让整个 Job 失败
if ($LASTEXITCODE -eq 0) {
    Write-Host "[sync-down] 完成"
} elseif ($LASTEXITCODE -eq 3 -or $LASTEXITCODE -eq 4) {
    Write-Host "[sync-down] 远端目录尚不存在（首次运行正常），跳过拉取"
} else {
    Write-Warning "[sync-down] rclone 退出码 $LASTEXITCODE（139 Authorization 过期或网络异常）"
}
exit 0
