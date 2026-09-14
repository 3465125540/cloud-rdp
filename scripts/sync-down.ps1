<#
.SYNOPSIS
  开机时从 139 云盘自动恢复数据到本地数据目录。
.NOTES
  依赖 setup-rclone.ps1 已配置好 remote: alist
  远端路径: alist:/cloudrdp/AI文件库/CloudRDP
  本地路径: D:\a\cloud-rdp

  ⚠️ 本地数据目录是 Actions 工作区的父目录，仓库 checkout 在其下（D:\a\cloud-rdp\cloud-rdp），
     必须排除，避免远端同名目录反向覆盖仓库。排除规则见下方。

  行为：
    - 远端目录不存在（首次运行）→ 视为正常，本地留空
    - 鉴权/网络失败 → 重试 MaxAttempts 次，仍失败则写入 _RESTORE_FAILED.txt 标记
    - 恢复成功 → 输出文件数/大小清单，并导出 RESTORE_STATUS 供后续步骤展示
  本脚本永不返回非 0（不阻断 RDP 启动），失败信息通过日志 + 标记文件 + RESTORE_STATUS 透出。
#>

param(
    [string]$RemoteBase = $(if ($env:CLOUDRDP_REMOTE_BASE) { $env:CLOUDRDP_REMOTE_BASE } else { "alist:/cloudrdp/AI文件库" }),
    [string]$Remote,                                   # 可选：直接覆盖完整远端路径
    [string]$Local  = $(if ($env:CLOUDRDP_DATA_DIR) { $env:CLOUDRDP_DATA_DIR } else { "D:\a\cloud-rdp" }),
    [int]$MaxAttempts = 3,
    [int]$RetryDelaySec = 8,
    [string[]]$Exclude = @()
)

$ErrorActionPreference = "Continue"
$RcloneExe = "C:\rclone\rclone.exe"

if ([string]::IsNullOrWhiteSpace($Remote)) { $Remote = $RemoteBase.TrimEnd('/') + "/CloudRDP" }

function Set-GhEnv([string]$kv) {
    if ($env:GITHUB_ENV) { $kv | Out-File $env:GITHUB_ENV -Append -Encoding ascii }
}

if (-not (Test-Path $RcloneExe)) { Write-Warning "[sync-down] 未找到 rclone，跳过恢复"; exit 0 }

# ---------- 计算排除规则（与 sync-up 保持一致） ----------
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

New-Item -ItemType Directory -Force -Path $Local | Out-Null
$marker = Join-Path $Local "_RESTORE_FAILED.txt"
if (Test-Path $marker) { Remove-Item $marker -Force -ErrorAction SilentlyContinue }

# ---------- 预检：139 侧「AI文件库」是否存在（不自动创建，避免建出影子目录） ----------
$probe = & $RcloneExe lsf $RemoteBase --max-depth 1 --timeout 0 --contimeout 0 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warning "[sync-down] 预检未通过：远端 $RemoteBase 不存在或不可访问"
    Write-Warning "  → 请在 139 云盘根目录下建好「AI文件库」文件夹后重跑；"
    Write-Warning "  → 或改用「根 ID 法」：把 AList 存储的 root_folder_id 设为该文件夹 ID（环境变量 ALIST_139_ROOT_FOLDER_ID），远端路径即可回归 ASCII。"
    Write-Warning "  （继续尝试恢复，失败会走重试逻辑）"
}

Write-Host "[sync-down] 开始恢复: $Remote  ->  $Local"
Write-Host ("[sync-down] 排除: " + ($excludeList -join ' '))

$code     = 0
$restored = $false
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
