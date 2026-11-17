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

  ⚠️ 139 凭据二选一：
    A) 只配 ALIST_139_AUTHORIZATION（浏览器 yun.139.com 的 Authorization，约 15 天过期）；
    B) 或同时配 ALIST_139_USERNAME + ALIST_139_PASSWORD + ALIST_139_MAIL_COOKIES
       （三者齐全时 authorization 留空，驱动会全量登录并把新 token 回写存储 → 长期免维护）。
    两者都配时以 B 为准。A 过期时 AList 只会回一句晦涩的
    "failed init storage but storage is already created: ... authorization has expired"。

  产物：
    <SysDir>\alist\alist.exe  +  <SysDir>\alist\data\  （AList 数据目录；SysDir 默认 D:\cloudrdp-sys）
    AList 服务监听 http://127.0.0.1:5244 ，WebDAV 在 /dav
    存储挂载路径 / （= 139 云盘整盘，AI文件库 是根直接子项；由 $RootFolderID 决定）
    数据实际落在 /AI文件库/CloudRDP （139 根目录 > AI文件库 > CloudRDP）
    快照落在   /AI文件库/_snapshot

  ⚠️ 备选「根 ID 法」：若不想让远端路径里出现中文，可把 ALIST_139_ROOT_FOLDER_ID 设为
     「AI文件库」文件夹的 ID（139 网页 F12 从请求里取），则 AList 的 / 直接映射到
     该文件夹，rclone 远端即可回归纯 ASCII：alist:/CloudRDP
#>

$ErrorActionPreference = "Stop"

# 统一系统目录：放 D 盘（C 盘只保留 runner 镜像基线，不额外占用）
$SysDir = if ($env:CLOUDRDP_SYS_DIR) { $env:CLOUDRDP_SYS_DIR } elseif (Test-Path 'D:\') { "D:\cloudrdp-sys" } else { "C:\cloudrdp-sys" }
$AlistDir  = Join-Path $SysDir "alist"
$AlistExe  = Join-Path $AlistDir "alist.exe"
$DataDir   = Join-Path $AlistDir "data"
$BaseUrl   = "http://127.0.0.1:5244"
$Port      = 5244
$AdminUser = "admin"
$AdminPass = if ([string]::IsNullOrWhiteSpace($env:ALIST_ADMIN_PASS)) { "CloudRdp-Alist-2026" } else { $env:ALIST_ADMIN_PASS }
$MountPath = "/"

$Authorization = $env:ALIST_139_AUTHORIZATION
$StorageType   = if ([string]::IsNullOrWhiteSpace($env:ALIST_139_TYPE)) { "personal_new" } else { $env:ALIST_139_TYPE }
$RootFolderID  = if ([string]::IsNullOrWhiteSpace($env:ALIST_139_ROOT_FOLDER_ID)) { "/" } else { $env:ALIST_139_ROOT_FOLDER_ID }
$CloudID       = if ($null -eq $env:ALIST_139_CLOUD_ID) { "" } else { $env:ALIST_139_CLOUD_ID }

# ---------- 0. 凭据解析 + 预检（真机 2026-10-14 踩坑）----------
# Authorization = base64("pc:<账号>:<token>|<..>|<..>|<过期毫秒>|..")，约 15 天过期。
# 过期后 AList 只会回一句晦涩的
#   "failed init storage but storage is already created: failed init storage: authorization has expired"
# （"storage is already created" 是 CreateStorage 的固定包装文案，真因永远是最后那句）。
# 且驱动 refreshToken() 先判 expiration<0 → 直接报错，**不会**续期、也**不会**回退密码登录。
# 这里提前解码判有效期：已过期**不再中断开机**（2026-11-16 起）——跳过 139 挂载照常开 RDP，
# 同时把状态写进 GITHUB_ENV，由连接邮件 / ENV READY / warning 三处醒目提示数据不会恢复。
function Get-139AuthExpiry([string]$Auth) {
    if ([string]::IsNullOrWhiteSpace($Auth)) { return $null }
    try { $dec = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Auth.Trim())) }
    catch { return $null }
    $parts = $dec -split ':'
    if ($parts.Count -lt 3) { return $null }
    $seg = $parts[2] -split '\|'
    if ($seg.Count -lt 4) { return $null }
    $ms = 0L
    if (-not [long]::TryParse($seg[3], [ref]$ms)) { return $null }
    if ($ms -le 0) { return $null }
    return [DateTimeOffset]::FromUnixTimeMilliseconds($ms)
}

function Set-AlistAuthState {
    <#
      把 139 授权状态透出到 GITHUB_ENV（供邮件之后的步骤 / ENV READY 汇总 / 保活诊断用）。
      状态：FULL_LOGIN / VALID / EXPIRING / EXPIRED / UNKNOWN / MISSING
      DAYS_LEFT 带符号一位小数（过期时为负数，便于判断）；非 VALID/EXPIRING/EXPIRED 时留空。
      绝不写 Authorization / 密码 / Cookie 本身。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [object]$DaysLeft = $null
    )
    if ([string]::IsNullOrWhiteSpace($env:GITHUB_ENV)) { return }
    $days = ''
    if ($null -ne $DaysLeft) {
        try { $days = ([double]$DaysLeft).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture) }
        catch { $days = '' }
    }
    try {
        @(
            "ALIST_AUTH_STATUS=$Status"
            "ALIST_AUTH_DAYS_LEFT=$days"
        ) | Out-File -LiteralPath $env:GITHUB_ENV -Append -Encoding ascii
    } catch {
        Write-Warning "[AList] 写 139 授权状态到 GITHUB_ENV 失败：$($_.Exception.Message)"
    }
}

# 可选「账号密码全量登录」：三件套齐全时**优先**走它（不填 authorization，驱动自己登录并把
# 新 token 回写存储 → 长期免维护，不再 15 天一手动）。详见 README「139 凭据」。
$FullLoginUser = $env:ALIST_139_USERNAME
$FullLoginPass = $env:ALIST_139_PASSWORD
$FullLoginCook = $env:ALIST_139_MAIL_COOKIES

$missingFull = @()
if ([string]::IsNullOrWhiteSpace($FullLoginUser)) { $missingFull += 'ALIST_139_USERNAME' }
if ([string]::IsNullOrWhiteSpace($FullLoginPass)) { $missingFull += 'ALIST_139_PASSWORD' }
if ([string]::IsNullOrWhiteSpace($FullLoginCook)) { $missingFull += 'ALIST_139_MAIL_COOKIES' }

$UseFullLogin = ($missingFull.Count -eq 0)
$HasAnyFullLogin = (-not [string]::IsNullOrWhiteSpace($FullLoginUser)) -or
                   (-not [string]::IsNullOrWhiteSpace($FullLoginPass)) -or
                   (-not [string]::IsNullOrWhiteSpace($FullLoginCook))
$HasPartialFullLogin = $HasAnyFullLogin -and (-not $UseFullLogin)

# 过期**不再中断开机**（真机 2026-11-16：过期 3 天直接 throw，整台机器起不来，代价过大）。
# $Skip139Storage = 本次跳过 139 存储创建（AList 服务照常起、RDP 照常开），
# 但数据/快照的恢复与上传都会缺席 —— 必须由邮件 + ENV READY + warning 三处醒目提示。
$Skip139Storage = $false
$left = $null

if ($UseFullLogin) {
    Set-AlistAuthState -Status 'FULL_LOGIN'
    Write-Host "[AList] 139 凭据：账号密码全量登录（忽略 authorization，由 AList 自动登录/续期）"
} elseif ([string]::IsNullOrWhiteSpace($Authorization)) {
    Set-AlistAuthState -Status 'MISSING'
    throw ("缺少 139 凭据。二选一：`n" +
           "  A) 配置 Secret ALIST_139_AUTHORIZATION（浏览器 yun.139.com 的 Authorization，约 15 天过期）；或`n" +
           "  B) 同时配置 ALIST_139_USERNAME + ALIST_139_PASSWORD + ALIST_139_MAIL_COOKIES（长期自愈）。")
} else {
    $exp = Get-139AuthExpiry $Authorization
    if ($null -eq $exp) {
        Set-AlistAuthState -Status 'UNKNOWN'
        Write-Host "[AList] 警告：无法解析 Authorization 有效期（格式可能异常），仍继续尝试挂载。" -ForegroundColor Yellow
    } else {
        $left = ($exp - [DateTimeOffset]::UtcNow).TotalDays
        if ($left -le 0) {
            Set-AlistAuthState -Status 'EXPIRED' -DaysLeft $left
            $Skip139Storage = $true
            $expiredDays = [math]::Round([math]::Abs($left), 1)
            Write-Warning ("139 Authorization 已过期约 $expiredDays 天 —— 本次跳过 139 挂载，但 RDP 继续开机。" +
                           "数据与快照不会恢复、新数据也无法上传 139。" +
                           "请更新 Secret ALIST_139_AUTHORIZATION 后重跑，或配置全量登录三件套" +
                           "（ALIST_139_USERNAME / ALIST_139_PASSWORD / ALIST_139_MAIL_COOKIES）实现长期自愈。")
        } elseif ($left -lt 15) {
            Set-AlistAuthState -Status 'EXPIRING' -DaysLeft $left
            Write-Host "[AList] 注意：139 Authorization 仅剩 $([math]::Round($left,1)) 天；AList 运行时每 12h 会自动续期，但请尽快更新 Secret。" -ForegroundColor Yellow
        } else {
            Set-AlistAuthState -Status 'VALID' -DaysLeft $left
            Write-Host "[AList] 139 Authorization 有效，剩余约 $([math]::Round($left,1)) 天。"
        }
    }
}

if ($HasPartialFullLogin) {
    Write-Warning ("[AList] 全量登录三件套未配齐，缺少：" + ($missingFull -join ', ') + "；本次不会启用全量登录。")
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

    # 下载策略（2026-09-21 真机踩坑）：
    #   匿名调 api.github.com 只有 60 次/小时/IP 的额度，GitHub runner 的出口 IP 是共享的，
    #   很容易被打满 → 报 "API rate limit exceeded" 直接挂。
    #   所以改为「latest 直链优先」：releases/latest/download/<固定资产名> 是 302 重定向，
    #   不经过 api.github.com，不受 rate limit 约束。资产名 alist-windows-amd64.zip 稳定不变。
    #   直链失败再退回 API（带 GITHUB_TOKEN 认证，认证限流 5000/h）。
    $zip = Join-Path $AlistDir "alist.zip"
    $downloaded = $false

    # ① 直链优先（最稳，绕过 API rate limit）。AlistGo 是权威源，alist-org 是镜像，放前面。
    $directUrls = @(
        "https://github.com/AlistGo/alist/releases/latest/download/alist-windows-amd64.zip",
        "https://github.com/alist-org/alist/releases/latest/download/alist-windows-amd64.zip"
    )
    foreach ($u in $directUrls) {
        try {
            Write-Host "[AList] 直链下载：$u"
            Invoke-WebRequest -Uri $u -OutFile $zip -UseBasicParsing -TimeoutSec 180 -ErrorAction Stop
            if ((Get-Item -LiteralPath $zip).Length -gt 1MB) { $downloaded = $true; break }
        } catch {
            Write-Host "[AList] 直链失败：$($_.Exception.Message)"
        }
    }

    # ② 直链都失败，退回 API（认证拿确切资产 URL）
    if (-not $downloaded) {
        $headers = @{ "User-Agent" = "gh-actions" }
        if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
            $headers["Authorization"] = "Bearer $env:GITHUB_TOKEN"
        }
        foreach ($repo in @("AlistGo/alist", "alist-org/alist")) {
            try {
                Write-Host "[AList] API 拉取 release：$repo"
                $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers $headers
                $asset = $release.assets | Where-Object { $_.name -match "windows-amd64" -and $_.name -match "\.zip$" } | Select-Object -First 1
                if ($asset) {
                    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
                    if ((Get-Item -LiteralPath $zip).Length -gt 1MB) { $downloaded = $true; break }
                }
            } catch {
                Write-Host "[AList] API 拉取失败（$repo）：$($_.Exception.Message)"
            }
        }
    }

    if (-not $downloaded) { throw "AList 下载失败（直链与 API 均失败）" }
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
$kUser  = Resolve-Field @("username", "Username") "username"
$kPass  = Resolve-Field @("password", "Password") "password"
$kCook  = Resolve-Field @("mail_cookies", "MailCookies") "mail_cookies"
$kType  = Resolve-Field @("type", "Type") "type"
$kRoot  = Resolve-Field @("root_folder_id", "RootFolderID") "root_folder_id"
$kCloud = Resolve-Field @("cloud_id", "CloudID") "cloud_id"
$kPart  = Resolve-Field @("custom_upload_part_size", "CustomUploadPartSize") "custom_upload_part_size"

# ---------- 5. 创建 / 更新存储（幂等）----------
if ($Skip139Storage) {
    Write-Warning "[AList 5/5] Authorization 已确认过期：跳过 139 存储创建/更新；AList 服务保留运行，RDP 开机继续。"
    exit 0
}
# 真机踩坑：同一台机器重跑（或数据目录被还原）时，挂载点已存在 → create 会报
#   "failed create storage in database"（重复挂载路径）。所以先查列表，存在就 update。
$addObj = @{}
if ($UseFullLogin) {
    # 三件套齐全 → 不填 authorization，驱动走全量登录并把新 token 回写存储。
    $addObj[$kUser] = $FullLoginUser
    $addObj[$kPass] = $FullLoginPass
    $addObj[$kCook] = $FullLoginCook
} else {
    $addObj[$kAuth] = $Authorization
}
$addObj[$kType] = $StorageType
$addObj[$kRoot] = $RootFolderID
if (-not [string]::IsNullOrWhiteSpace($CloudID)) { $addObj[$kCloud] = $CloudID }
$addObj[$kPart] = 0
$addition = $addObj | ConvertTo-Json -Compress

$storageObj = @{
    mount_path       = $MountPath
    order            = 0
    driver           = [string]$driverKey
    cache_expiration = 30
    status           = "work"
    addition         = $addition
    remark           = "139 cloudrdp"
    web_proxy        = $false
    webdav_policy    = "302_redirect"
}

# 查是否已存在同挂载路径的存储
$existingId = $null
try {
    $listResp = Invoke-RestMethod -Uri "$BaseUrl/api/admin/storage/list" -Headers @{ Authorization = $token }
    if ($listResp.code -eq 200) {
        $hit = @($listResp.data.content) | Where-Object { $_.mount_path -eq $MountPath } | Select-Object -First 1
        if ($hit) { $existingId = $hit.id }
    }
} catch { Write-Host "[AList] 存储列表读取失败（继续按新建处理）：$($_.Exception.Message)" }

$apiPath = "$BaseUrl/api/admin/storage/create"
if ($null -ne $existingId) {
    Write-Host "[AList] 挂载点已存在（id=$existingId）→ 改为更新"
    $storageObj["id"] = $existingId
    $apiPath = "$BaseUrl/api/admin/storage/update"
}
$body = $storageObj | ConvertTo-Json -Compress

try {
    $resp = Invoke-RestMethod -Uri $apiPath -Method Post -Headers @{ Authorization = $token } -Body $body -ContentType "application/json"
} catch {
    $msg = $_.Exception.Message
    # 预检解析不出有效期（UNKNOWN）时，AList 运行时才暴露过期 —— 同样降级，不中断开机。
    if ((-not $UseFullLogin) -and ($msg -match 'authorization has expired')) {
        Set-AlistAuthState -Status 'EXPIRED' -DaysLeft $left
        Write-Warning ("AList 确认 139 Authorization 已过期：本次不挂载 139，但 RDP 继续开机。" +
                       "数据/快照不会恢复、新数据也无法上传 139。请更新 Secret 后重跑。")
        exit 0
    }
    throw "139 存储请求失败（$apiPath）：$msg"
}
if ($resp.code -ne 200) {
    Write-Host "----- 诊断：可用驱动 -----"
    try { (Invoke-RestMethod -Uri "$BaseUrl/api/admin/driver/list" -Headers @{ Authorization = $token }).data | Format-Table } catch {}
    Write-Host "----- 诊断：$driverKey 期望字段 -----"
    try { (Invoke-RestMethod -Uri "$BaseUrl/api/admin/driver/info?driver=$driverKey" -Headers @{ Authorization = $token }).data.additional | ConvertTo-Json -Depth 6 } catch {}
    if ("$($resp.message)" -match "authorization has expired") {
        Set-AlistAuthState -Status 'EXPIRED' -DaysLeft $left
        Write-Warning ("AList 确认 139 Authorization 已过期：本次不挂载 139，但 RDP 继续开机。" +
                       "数据/快照不会恢复、新数据也无法上传 139。请更新 Secret 后重跑，或配置全量登录三件套。")
        exit 0
    }
    if ("$($resp.message)" -match "already|exist") {
        throw ("创建 139 存储失败：$($resp.message)`n" +
               "  （挂载路径 $MountPath 可能已被别的存储占用；删掉旧存储或改 $MountPath。）")
    }
    throw "创建 139 存储失败：$($resp.message)"
}

Write-Host "[AList 5/5] 完成。挂载路径: $MountPath （数据放 $MountPath/AI文件库/CloudRDP）"
