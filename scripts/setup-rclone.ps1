<#
.SYNOPSIS
  在 GitHub Actions Windows runner 上安装 rclone，并写好指向本机 AList WebDAV 的配置。

.NOTES
  依赖环境变量：
    ALIST_ADMIN_PASS  AList 管理员密码（与 setup-alist.ps1 保持一致）
  产物：
    C:\rclone\rclone.exe
    %USERPROFILE%\.config\rclone\rclone.conf  （remote 名：alist）
#>

$ErrorActionPreference = "Stop"

$RcloneDir = "C:\rclone"
$RcloneExe = Join-Path $RcloneDir "rclone.exe"
$AlistPort = 5244
$AlistUser = "admin"
$AlistPass = if ([string]::IsNullOrWhiteSpace($env:ALIST_ADMIN_PASS)) { "CloudRdp-Alist-2026" } else { $env:ALIST_ADMIN_PASS }

# ---------- 1. 下载 rclone ----------
if (-not (Test-Path $RcloneExe)) {
    Write-Host "[rclone] 下载中..."
    $zip = "C:\rclone.zip"
    $tmp = "C:\rclone-tmp"
    Invoke-WebRequest -Uri "https://downloads.rclone.org/rclone-current-windows-amd64.zip" -OutFile $zip -UseBasicParsing
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $found = Get-ChildItem $tmp -Recurse -Filter "rclone.exe" | Select-Object -First 1
    if (-not $found) { throw "rclone 解压失败" }
    New-Item -ItemType Directory -Force -Path $RcloneDir | Out-Null
    Copy-Item $found.FullName $RcloneExe -Force
}
Write-Host "[rclone] 版本: $(& $RcloneExe version | Select-Object -First 1)"

# ---------- 2. 生成 obscured 密码 ----------
# rclone 配置文件里的 pass 必须是 obscured 值
$obscured = (& $RcloneExe obscure $AlistPass).Trim()

# ---------- 3. 写配置 ----------
$confDir = Join-Path $env:USERPROFILE ".config\rclone"
New-Item -ItemType Directory -Force -Path $confDir | Out-Null
$confFile = Join-Path $confDir "rclone.conf"

$conf = @"
[alist]
type = webdav
url = http://127.0.0.1:$AlistPort/dav
vendor = other
user = $AlistUser
pass = $obscured
"@
$conf | Out-File -FilePath $confFile -Encoding ascii -Force

Write-Host "[rclone] 配置已写入: $confFile"
Write-Host "[rclone] remote 名称: alist"
