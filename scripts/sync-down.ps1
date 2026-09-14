<#
.SYNOPSIS
  开机时从 139 云盘自动恢复数据到本地 C:\data。
.NOTES
  依赖 setup-rclone.ps1 已配置好 remote: alist
  远端路径: alist:/cloudrdp/CloudRDP
  本地路径: C:\data
  行为：
    - 远端目录不存在（首次运行）→ 视为正常，本地留空
    - 鉴权/网络失败 → 重试 MaxAttempts 次，仍失败则写入 _RESTORE_FAILED.txt 标记
    - 恢复成功 → 输出文件数/大小清单，并导出 RESTORE_STATUS 供后续步骤展示
  本脚本永不返回非 0（不阻断 RDP 启动），失败信息通过日志 + 标记文件 + RESTORE_STATUS 透出。
#>

param(
    [string]$Remote = "alist:/cloudrdp/CloudRDP",
    [string]$Local  = "C:\data",
    [int]$MaxAttempts = 3,
    [int]$RetryDelaySec = 8
)

$ErrorActionPreference = "Continue"
$RcloneExe = "C:\rclone\rclone.exe"

function Set-GhEnv([string]$kv) {
    if ($env:GITHUB_ENV) { $kv | Out-File $env:GITHUB_ENV -Append -Encoding ascii }
}

if (-not (Test-Path $RcloneExe)) { Write-Warning "[sync-down] 未找到 rclone，跳过恢复"; exit 0 }

New-Item -ItemType Directory -Force -Path $Local | Out-Null
$marker = Join-Path $Local "_RESTORE_FAILED.txt"
if (Test-Path $marker) { Remove-Item $marker -Force -ErrorAction SilentlyContinue }

Write-Host "[sync-down] 开始恢复: $Remote  ->  $Local"

$code     = 0
$restored = $false
for ($i = 1; $i -le $MaxAttempts; $i++) {
    & $RcloneExe copy $Remote $Local `
        --update `
        --transfers 4 --checkers 8 `
        --timeout 0 --contimeout 0 `
        --retries 3 --low-level-retries 5 `
        --stats-one-line -v
    $code = $LASTEXITCODE
    if ($code -eq 0) { $restored = $true; break }
    if ($code -eq 3 -or $code -eq 4) { break }          # 远端目录不存在 —— 首次运行正常，不重试
    if ($i -lt $MaxAttempts) {
        Write-Warning "[sync-down] 第 $i/$MaxAttempts 次失败（rclone 码 $code），$RetryDelaySec 秒后重试..."
        Start-Sleep -Seconds $RetryDelaySec
    }
}

if ($restored) {
    $files = @(Get-ChildItem $Local -Recurse -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -ne "_RESTORE_FAILED.txt" })
    $bytes = ($files | Measure-Object -Property Length -Sum).Sum
    if (-not $bytes) { $bytes = 0 }
    Write-Host ("[sync-down] OK 恢复完成：{0} 个文件，{1:N2} MB" -f $files.Count, ($bytes / 1MB))
    Set-GhEnv "RESTORE_STATUS=OK"
}
elseif ($code -eq 3 -or $code -eq 4) {
    Write-Host "[sync-down] 远端目录尚不存在（首次运行正常），本地留空"
    Set-GhEnv "RESTORE_STATUS=EMPTY"
}
else {
    Write-Warning "[sync-down] FAIL 数据恢复失败（rclone 码 $code）—— 139 Authorization 大概率已过期！"
    "restore FAILED at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), rclone exit code = $code" |
        Out-File $marker -Encoding utf8
    Set-GhEnv "RESTORE_STATUS=FAILED"
}

exit 0
