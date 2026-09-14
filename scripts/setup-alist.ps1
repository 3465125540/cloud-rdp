<#
.SYNOPSIS
  在 GitHub Actions Windows runner 上部署 AList，并把「中国移动云盘(139)」挂载成 WebDAV，
  供 rclone 读写，实现数据持久化。

.NOTES
  依赖环境变量（来自 GitHub Secret）：
    ALIST_139_AUTHORIZATION   139 云盘 Authorization（F12 → Cookies → yun.139.com → Authorization，
                              只填 "Basic " 后面的内容）
  可选环境变量：
    ALIST_ADMIN_PASS          AList 管理员密码，默认 CloudRdp-Alist-2026（仅本机 127.0.0.1 可见）
    ALIST_139_TYPE            云盘类型，默认 personal_new（新个人云）
    ALIST_139_ROOT_FOLDER_ID  根文件夹ID，默认 "/"（整个盘）
    ALIST_139_CLOUD_ID        家庭云/共享群专用ID，默认空

  产物：
    C:\alist\alist.exe  +  C:\alist\data\  （AList 数据目录）
    AList 服务监听 http://127.0.0.1:5244 ，WebDAV 在 /dav
    存储挂载路径 /cloudrdp ，实际数据目录建议用 /cloudrdp/CloudRDP
#>

$ErrorActionPreference = "Stop"

$AlistDir  = "C:\alist"
$AlistExe  = Join-Path $AlistDir "alist.exe"
$DataDir   = Join-Path $AlistDir "data"
$BaseUrl   = "http://127.0.0.1:5244"
$Port      = 5244
$AdminUser = "admin"
$AdminPass = if ([string]::IsNullOrWhiteSpace($env:ALIST_ADMIN_PASS)) { "CloudRdp-Alist-2026" } else { $env:ALIST_ADMIN_PASS }
$MountPath = "/cloudrdp"

$Authorization = $env:ALIST_139_AUTHORIZATION
$StorageType   = if ([string]::IsNullOrWhiteSpace($env:ALIST_139_TYPE)) { "personal_new" } else { $env:ALIST_139_TYPE }
$RootFolderID  = if ([string]::IsNullOrWhiteSpace($env:ALIST_139_ROOT_FOLDER_ID)) { "/" } else { $env:ALIST_139_ROOT_FOLDER_ID }
$CloudID       = if ($null -eq $env:ALIST_139_CLOUD_ID) { "" } else { $env:ALIST_139_CLOUD_ID }

if ([string]::IsNullOrWhiteSpace($Authorization)) {
    throw "缺少环境变量 ALIST_139_AUTHORIZATION —— 请确认 GitHub Secret 已配置且未过期。"
}

function Wait-Http([string]$Url, [int]$TimeoutSec = 90) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5 | Out-Null
            return $true
        } catch { Start-Sleep -Seconds 2 }
    }
    return $false
}

# ---------- 1. 下载 AList ----------
New-Item -ItemType Directory -Force -Path $AlistDir | Out-Null
if (-not (Test-Path $AlistExe)) {
    Write-Host "[AList 1/5] 下载 Windows 版..."
    $api = "https://api.github.com/repos/AlistGo/alist/releases/latest"
    try {
        $release = Invoke-RestMethod -Uri $api -Headers @{ "User-Agent" = "gh-actions" }
    } catch {
        Write-Host "[AList] AlistGo/alist 拉取失败，回退 alist-org/alist"
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/alist-org/alist/releases/latest" -Headers @{ "User-Agent" = "gh-actions" }
    }
    $asset = $release.assets | Where-Object { $_.name -match "windows-amd64" -and $_.name -match "\.zip$" } | Select-Object -First 1
    if (-not $asset) { throw "未找到 AList windows-amd64 发布包" }
    $zip = Join-Path $AlistDir "alist.zip"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $AlistDir -Force
    if (-not (Test-Path $AlistExe)) { throw "AList 解压失败，未找到 $AlistExe" }
}

# ---------- 2. 初始化数据目录并设置管理员密码 ----------
Write-Host "[AList 2/5] 设置管理员密码..."
& $AlistExe admin set $AdminPass --data $DataDir | Out-Null

# ---------- 3. 后台启动 AList ----------
Write-Host "[AList 3/5] 启动 AList..."
Start-Process -FilePath $AlistExe -ArgumentList "server --data `"$DataDir`"" -WorkingDirectory $AlistDir -WindowStyle Hidden
if (-not (Wait-Http "$BaseUrl/api/public/settings" 90)) { throw "AList 启动失败（$BaseUrl 无响应）" }
Write-Host "[AList] 服务已就绪：$BaseUrl"

# ---------- 4. 登录取 token ----------
Write-Host "[AList 4/5] 登录并创建 139 存储..."
$loginBody = @{ username = $AdminUser; password = $AdminPass } | ConvertTo-Json -Compress
try {
    $login = Invoke-RestMethod -Uri "$BaseUrl/api/auth/login" -Method Post -Body $loginBody -ContentType "application/json"
} catch {
    throw "AList 登录请求失败：$($_.Exception.Message)"
}
if ($login.code -ne 200) { throw "AList 登录失败：$($login.message)" }
$token = $login.data.token

# 自动探测 139 驱动名。
# 注意：/api/admin/driver/list 返回的是「驱动名 -> schema」的对象（不是数组），
# 必须取属性名，不能直接 Where-Object 过滤整个对象。
$driverKey = "139Yun"
try {
    $drivers = Invoke-RestMethod -Uri "$BaseUrl/api/admin/driver/list" -Headers @{ Authorization = $token }
    if ($drivers.code -eq 200) {
        $names = @($drivers.data.PSObject.Properties.Name)
        $hit = $names | Where-Object { $_ -eq "139Yun" } | Select-Object -First 1
        if (-not $hit) { $hit = $names | Where-Object { $_ -match "139|MCS|移动" } | Select-Object -First 1 }
        if ($hit) { $driverKey = [string]$hit }
    }
} catch { Write-Host "[AList] 驱动列表探测失败，使用默认 $driverKey" }
Write-Host "[AList] 使用驱动: $driverKey"

# 取驱动字段 schema，用真实字段名构造 addition（AList 的 json tag 是小写+下划线）
$schemaNames = @()
try {
    $info = Invoke-RestMethod -Uri "$BaseUrl/api/admin/driver/info?driver=$driverKey" -Headers @{ Authorization = $token }
    $schemaNames = @($info.data.additional | ForEach-Object { [string]$_.name })
    Write-Host "[AList] 驱动字段: $($schemaNames -join ', ')"
} catch { Write-Host "[AList] 驱动 schema 获取失败，使用默认字段名" }

function Resolve-Field([string[]]$candidates, [string]$fallback) {
    foreach ($c in $candidates) { if ($schemaNames -contains $c) { return $c } }
    return $fallback
}

$kAuth  = Resolve-Field @("authorization", "Authorization") "authorization"
$kType  = Resolve-Field @("type", "Type") "type"
$kRoot  = Resolve-Field @("root_folder_id", "RootFolderID") "root_folder_id"
$kCloud = Resolve-Field @("cloud_id", "CloudID") "cloud_id"
$kPart  = Resolve-Field @("custom_upload_part_size", "CustomUploadPartSize") "custom_upload_part_size"

# ---------- 5. 创建存储 ----------
$addObj = @{}
$addObj[$kAuth] = $Authorization
$addObj[$kType] = $StorageType
$addObj[$kRoot] = $RootFolderID
if (-not [string]::IsNullOrWhiteSpace($CloudID)) { $addObj[$kCloud] = $CloudID }
$addObj[$kPart] = 0
$addition = $addObj | ConvertTo-Json -Compress

$createBody = @{
    mount_path       = $MountPath
    order            = 0
    driver           = [string]$driverKey
    cache_expiration = 30
    status           = "work"
    addition         = $addition
    remark           = "139 cloudrdp"
    web_proxy        = $false
    webdav_policy    = "302_redirect"
} | ConvertTo-Json -Compress

try {
    $resp = Invoke-RestMethod -Uri "$BaseUrl/api/admin/storage/create" -Method Post -Headers @{ Authorization = $token } -Body $createBody -ContentType "application/json"
} catch {
    throw "创建 139 存储请求失败：$($_.Exception.Message)"
}
if ($resp.code -ne 200) {
    Write-Host "----- 诊断：可用驱动 -----"
    try { (Invoke-RestMethod -Uri "$BaseUrl/api/admin/driver/list" -Headers @{ Authorization = $token }).data | Format-Table } catch {}
    Write-Host "----- 诊断：$driverKey 期望字段 -----"
    try { (Invoke-RestMethod -Uri "$BaseUrl/api/admin/driver/info?driver=$driverKey" -Headers @{ Authorization = $token }).data.additional | ConvertTo-Json -Depth 6 } catch {}
    throw "创建 139 存储失败：$($resp.message)"
}

Write-Host "[AList 5/5] 完成。挂载路径: $MountPath （数据建议放 $MountPath/CloudRDP）"
