<#
.SYNOPSIS
  安装 UU远程（网易 GameViewer）并打印 / 邮件它的「连接信息」—— 远程连接的备用通道。

.DESCRIPTION
  为什么要有这一步（挂在 0c Tailscale 之后）：
    Tailscale 是主通道，但它有单点：authkey 会过期、tailnet 会受限、DNS 会抖。
    UU远程（网易自研中继，GameViewer）只要机器能上网就能被连上 —— 是主通道之外的兜底。
    又因为第 10 步「重装软件」要等 30~60 分钟才轮到它，这里必须**早装**，
    否则「备用通道」在用户最需要的前半小时里根本不存在。

  安装策略（分层，全部 fail-soft，绝不阻断开机）：
    ① 已装？  C:\Program Files\Netease\GameViewer\GameViewer.exe
              %LOCALAPPDATA%\Programs\GameViewer\GameViewer.exe
              D 盘便携副本（CLOUDRDP_DATA_DIR\GameViewer\GameViewer.exe）
    ② winget install --id NetEase.UURemote --exact --silent   （运行器镜像自带 winget）
    ③ 官方安装包直链下载 + NSIS /S 静默安装
  装完拉起一次（让它写设备身份），再读连接信息。

  连接信息从哪来（UU远程 免登录也能被「远程协助」，靠的就是设备码 + 验证码）：
    机器级  C:\ProgramData\Netease\GameViewer\user_info.ini            → deviceId（设备码）
            C:\ProgramData\Netease\GameViewer\remote_assist_code.ini    → 协助码 / 验证码
            C:\ProgramData\Netease\GameViewer\config.ini                → uuid
    协助方拿到「设备码 + 验证码」即可发起远控，无需登录 UU 账号。

.NOTES
  环境变量：
    CLOUDRDP_DATA_DIR  数据目录（找 D 盘便携副本用），默认 D:\a\cloud-rdp
    RDP_USERNAME       被控账户（默认 a），只用于正文提示
    MAIL_*             与 0e 步同一套 SMTP 配置（缺失则自动跳过发信）
  退出码：**始终 0**（安装/发信失败都不该让开机流程变红）。
          状态写 <sysdir>\_state\uu-remote.json，并透出 UU_REMOTE=OK|PARTIAL|FAIL 到 GITHUB_ENV。
  开关：CLOUDRDP_UU_INSTALL=0 → 只读现有信息、不装；-SkipInstall / -NoMail / -DryRun。
  诊断日志：默认 <sysdir>\_state\uu-remote.log（用 -LogPath 覆盖）。
#>
[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\Program Files\Netease\GameViewer',
    [string]$DataDir    = $(if ($env:CLOUDRDP_DATA_DIR) { [string]$env:CLOUDRDP_DATA_DIR } else { 'D:\a\cloud-rdp' }),
    [string]$LogPath    = '',
    [string]$MailTo     = '',
    [switch]$SkipInstall,
    [switch]$NoMail,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------- 路径 / 日志
$sysDir = if ($env:CLOUDRDP_SYS_DIR) { [string]$env:CLOUDRDP_SYS_DIR }
          elseif (Test-Path 'D:\') { 'D:\cloudrdp-sys' } else { 'C:\cloudrdp-sys' }
$stateDir = Join-Path $sysDir '_state'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
if ([string]::IsNullOrWhiteSpace($LogPath)) { $LogPath = Join-Path $stateDir 'uu-remote.log' }
$StatusFile = Join-Path $stateDir 'uu-remote.json'

function Say([string]$m)  { Write-Host "[0c1] $m" }
function Warn([string]$m) { Write-Host "[0c1] $m" -ForegroundColor Yellow }
function Log([string]$m) {
    try { ("[{0}] {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $m) |
            Out-File -LiteralPath $LogPath -Append -Encoding utf8 } catch { }
}
function Set-GhEnv([string]$kv) {
    if ($env:GITHUB_ENV) { try { $kv | Out-File $env:GITHUB_ENV -Append -Encoding ascii } catch { } }
}

$uuUser = if ($env:RDP_USERNAME) { [string]$env:RDP_USERNAME } else { 'a' }
$programDataGV = 'C:\ProgramData\Netease\GameViewer'

# ---------------------------------------------------------------- ① 定位已装
function Get-UUCandidateExes {
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($p in @(
        (Join-Path $InstallDir 'GameViewer.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\GameViewer\GameViewer.exe'),
        (Join-Path $env:LOCALAPPDATA 'GameViewer\GameViewer.exe'),
        'C:\Program Files (x86)\Netease\GameViewer\GameViewer.exe'
    )) { if ($p -and (Test-Path -LiteralPath $p)) { $list.Add($p) } }
    # D 盘便携副本（数据目录里的绿色版；0c 时刻多半还没从 139 拉下来，但拉到了就直接用）
    if ($DataDir) {
        foreach ($p in @(
            (Join-Path $DataDir 'GameViewer\GameViewer.exe'),
            (Join-Path $DataDir '_portable\C\Program Files\Netease\GameViewer\GameViewer.exe')
        )) { if (Test-Path -LiteralPath $p) { $list.Add($p) } }
    }
    # ⚠️ 必须 `,@(...)`：PowerShell 返回单元素数组会被**解包成标量**，
    #    于是 `$exe[0]` 变成字符串的首字符 'C'（实测踩过：安装路径显示成 "C"）。
    return ,@($list)
}

function Get-UUVersion([string]$Exe) {
    try {
        $vi = (Get-Item -LiteralPath $Exe).VersionInfo
        foreach ($c in @($vi.ProductVersion, $vi.FileVersion)) {
            if (-not [string]::IsNullOrWhiteSpace($c)) { return ([string]$c).Trim() }
        }
    } catch { }
    return ''
}

function Find-Winget {
    $c = Get-Command winget -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'),
        'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe'
    )) { if (Test-Path -LiteralPath $p) { return $p } }
    return ''
}

# ---------------------------------------------------------------- ②③ 安装
function Install-UUViaWinget {
    $wg = Find-Winget
    if (-not $wg) { return @{ ok = $false; note = 'winget 不存在' } }
    Say "winget 安装 NetEase.UURemote ...（$wg）"
    try {
        $out = & $wg install --id NetEase.UURemote --exact --silent `
                    --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-String
        Log "winget out: $out"
        # 0 成功；-1978335189 (0x8A15002B) = 已安装最新版，同样算成功
        if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq -1978335189) { return @{ ok = $true; note = "winget exit=$LASTEXITCODE" } }
        return @{ ok = $false; note = "winget exit=$LASTEXITCODE" }
    } catch { return @{ ok = $false; note = "winget 异常：$($_.Exception.Message)" } }
}

function Install-UUViaDownload {
    # 官方 PC 直链（uuyc.163.com → adl.netease.com 的 NSIS 安装包）
    $urls = @(
        'https://adl.netease.com/d/g/uuremote/c/gw?type=pc',
        'https://gv.163.com/download/GameViewer_Setup.exe'
    )
    $dest = Join-Path $env:TEMP 'uuremote_setup.exe'
    foreach ($u in $urls) {
        try {
            Say "下载 UU远程 安装包：$u"
            Invoke-WebRequest -Uri $u -OutFile $dest -UseBasicParsing -TimeoutSec 180
            if ((Test-Path -LiteralPath $dest) -and ((Get-Item -LiteralPath $dest).Length -gt 1MB)) {
                Say "静默安装（NSIS /S）..."
                Start-Process -FilePath $dest -ArgumentList '/S' -Wait
                return @{ ok = $true; note = "下载安装：$u" }
            }
            Warn "下载结果异常（过小），换下一个源"
        } catch { Warn "下载失败：$($_.Exception.Message)" }
    }
    return @{ ok = $false; note = '官方安装包下载/安装均失败' }
}

# ---------------------------------------------------------------- 设备身份解析
function Get-IniKV([string]$Path) {
    $h = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $h }
    try {
        foreach ($ln in (Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop)) {
            $s = ([string]$ln).Trim()
            if (-not $s -or $s.StartsWith(';') -or $s.StartsWith('#') -or $s.StartsWith('[')) { continue }
            $i = $s.IndexOf('=')
            if ($i -le 0) { continue }
            $k = $s.Substring(0, $i).Trim()
            $v = $s.Substring($i + 1).Trim().Trim('"')
            if ($k) { $h[$k] = $v }
        }
    } catch { }
    return $h
}

# 值可能是 DPAPI 密文（base64 或 hex）——尽力在本机解开；解不开就原样返回。
function Try-Unprotect([string]$Val) {
    if ([string]::IsNullOrWhiteSpace($Val)) { return '' }
    # 已经是明文短码（数字/字母/连字符）→ 直接用
    if ($Val -match '^[A-Za-z0-9\-_]{3,32}$') { return $Val }
    $raw = $null
    try { $raw = [Convert]::FromBase64String($Val) } catch {
        try {
            if ($Val -match '^[0-9A-Fa-f]{16,}$' -and ($Val.Length % 2 -eq 0)) {
                $b = New-Object byte[] ($Val.Length / 2)
                for ($i = 0; $i -lt $b.Length; $i++) { $b[$i] = [Convert]::ToByte($Val.Substring($i * 2, 2), 16) }
                $raw = $b
            }
        } catch { }
    }
    if ($null -eq $raw) { return $Val }
    try { Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue } catch { }
    foreach ($scope in @('LocalMachine', 'CurrentUser')) {
        try {
            $sc = [System.Security.Cryptography.DataProtectionScope]::$scope
            $dec = [System.Security.Cryptography.ProtectedData]::Unprotect($raw, $null, $sc)
            if ($dec) {
                $txt = [System.Text.Encoding]::UTF8.GetString($dec).Trim([char]0).Trim()
                if ($txt) { return $txt }
            }
        } catch { }
    }
    return $Val
}

function Get-UUConnectionInfo {
    $info = [ordered]@{
        deviceName = $env:COMPUTERNAME
        deviceId   = ''
        assistId   = ''
        uuid       = ''
        assistCode = ''
        assistRaw  = ''
        version    = ''
        installPath= ''
    }
    $ui = Get-IniKV (Join-Path $programDataGV 'user_info.ini')
    $cf = Get-IniKV (Join-Path $programDataGV 'config.ini')
    $ac = Get-IniKV (Join-Path $programDataGV 'remote_assist_code.ini')

    foreach ($k in @('deviceId', 'device_id', 'deviceid', 'deviceID')) {
        if ($ui.ContainsKey($k) -and $ui[$k]) { $info.deviceId = [string]$ui[$k]; break }
    }
    foreach ($k in @('uuid', 'UUID')) {
        if ($cf.ContainsKey($k) -and $cf[$k]) { $info.uuid = [string]$cf[$k]; break }
    }
    # 协助码：优先自定义码（用户可固定），否则服务端下发的 code
    foreach ($k in @('customize_code', 'customizeCode', 'customCode')) {
        if ($ac.ContainsKey($k) -and $ac[$k]) { $info.assistRaw = [string]$ac[$k]; break }
    }
    if (-not $info.assistRaw) {
        foreach ($k in @('code', 'verify_code', 'verifyCode', 'assist_code', 'assistCode')) {
            if ($ac.ContainsKey($k) -and $ac[$k]) { $info.assistRaw = [string]$ac[$k]; break }
        }
    }
    if ($info.assistRaw) { $info.assistCode = Try-Unprotect $info.assistRaw }
    # 协助码所在 section 里还带一个 8 位 id（远程协助的「设备码」候选），一并带出
    foreach ($k in @('id', 'assistId', 'assist_id')) {
        if ($ac.ContainsKey($k) -and $ac[$k]) { $info.assistId = [string]$ac[$k]; break }
    }
    return $info
}

function Write-Status($obj) {
    try { $obj | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $StatusFile -Encoding UTF8 } catch { }
}

# ================================================================ 主流程
Say "UU远程（备用远程通道）—— 安装 + 连接信息"
Log "start; DataDir=$DataDir InstallDir=$InstallDir SkipInstall=$SkipInstall DryRun=$DryRun"

$install = @{ ok = $false; note = ''; exe = ''; source = '' }

# ① 已装
$existing = Get-UUCandidateExes
if ($existing.Count -gt 0) {
    $install = @{ ok = $true; note = '已安装（跳过安装）'; exe = $existing[0]; source = 'existing' }
    Say "已检测到 UU远程：$($existing[0])"
}

# ②③ 安装
$doInstall = -not $SkipInstall -and -not $DryRun
if ($env:CLOUDRDP_UU_INSTALL -eq '0') { $doInstall = $false; Say "CLOUDRDP_UU_INSTALL=0 → 跳过安装" }
if (-not $install.ok -and $doInstall) {
    $r = Install-UUViaWinget
    if ($r.ok) { Say "winget 安装成功（$($r.note)）" } else { Warn "winget 路线失败：$($r.note)" }
    if (-not $r.ok) {
        $r2 = Install-UUViaDownload
        if ($r2.ok) { Say "下载安装成功（$($r2.note)）" } else { Warn "下载路线失败：$($r2.note)" }
        if ($r2.ok) { $r = $r2 }
    }
    if ($r.ok) {
        Start-Sleep -Seconds 3
        $existing = Get-UUCandidateExes
        if ($existing.Count -gt 0) { $install = @{ ok = $true; note = $r.note; exe = $existing[0]; source = 'installed' } }
        else { $install = @{ ok = $false; note = "安装命令返回成功但找不到 GameViewer.exe（$($r.note)）"; exe = ''; source = '' } }
    } else {
        $install = @{ ok = $false; note = $r.note; exe = ''; source = '' }
    }
} elseif (-not $install.ok -and -not $doInstall) {
    $install = @{ ok = $false; note = '未安装且已跳过安装'; exe = ''; source = '' }
}

# 拉起一次，让它写设备身份（幂等：已在跑就不重复起）。
# ★ 关键：协助码（验证码）是 **DPAPI 密文** —— 只有「本机 + 本用户」加密的那份才解得开。
#   从 139 还原来的旧码跨机解不开（README §UU 已记），所以必须让 UU远程 在本机重新生成一份，
#   再读一次，才可能拿到「能用的验证码」。
function Test-AssistUsable([string]$v) {
    return [bool]($v -and ($v -notmatch '^[A-Za-z0-9+/=]{40,}$'))
}
if ($install.ok -and $install.exe -and -not $DryRun) {
    try {
        $running = @(Get-Process -Name 'GameViewer' -ErrorAction SilentlyContinue)
        if ($running.Count -eq 0) {
            Start-Process -FilePath $install.exe -ErrorAction Stop | Out-Null
            Say "已拉起 UU远程（等它写设备身份 / 生成本机协助码 ...）"
            Start-Sleep -Seconds 15
        } else { Say "UU远程 已在运行" }
    } catch { Warn "拉起 UU远程 失败（可忽略）：$($_.Exception.Message)" }
}

# 读连接信息（拉起后再读一次；谁的协助码可用就用谁）
$info = Get-UUConnectionInfo
if (-not (Test-AssistUsable $info.assistCode) -and $install.ok -and -not $DryRun) {
    Say "协助码仍是 DPAPI 密文（多半是从别的机器还原来的）—— 再等 20s 让 UU远程 在本机重生成 ..."
    Start-Sleep -Seconds 20
    $again = Get-UUConnectionInfo
    if (Test-AssistUsable $again.assistCode) { $info = $again; Say "已拿到本机可用的协助码" }
}
if ($install.exe) { $info.version = Get-UUVersion $install.exe }
$info.installPath = [string]$install.exe

# 判定：设备码 + **可用**的验证码才算 OK；只有一个算 PARTIAL
$assistUsable = Test-AssistUsable $info.assistCode
$state = 'FAIL'
if ($install.ok -and $info.deviceId -and $assistUsable) { $state = 'OK' }
elseif ($install.ok -or $info.deviceId) { $state = 'PARTIAL' }

$assistDisplay = if (-not $info.assistCode) { '(未取到)' }
                 elseif ($assistUsable) { $info.assistCode }
                 else { '(DPAPI 密文·跨机解不开 —— 需在机器上打开 UU远程 查看验证码，或登录 UU 账号走设备列表)' }

# ---------------------------------------------------------------- 打印
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  UU远程（备用远程通道）连接信息" -ForegroundColor Cyan
Write-Host "  设备名   : $($info.deviceName)"
Write-Host "  设备码   : $(if ($info.deviceId) { $info.deviceId } else { '(未取到)' })" -ForegroundColor Yellow
Write-Host "  协助 id  : $(if ($info.assistId) { $info.assistId } else { '(无)' })" -ForegroundColor Yellow
Write-Host "  验证码   : $assistDisplay" -ForegroundColor Yellow
if ($info.uuid)    { Write-Host "  uuid     : $($info.uuid)" -ForegroundColor DarkGray }
if ($info.version) { Write-Host "  版本     : $($info.version)" -ForegroundColor DarkGray }
Write-Host "  安装     : $($install.note)"
Write-Host "  安装路径 : $(if ($info.installPath) { $info.installPath } else { '(无)' })" -ForegroundColor DarkGray
Write-Host "  状态     : $state" -ForegroundColor $(if ($state -eq 'OK') { 'Green' } elseif ($state -eq 'PARTIAL') { 'Yellow' } else { 'Red' })
Write-Host "  >> 协助方：装「网易UU远程」→ 远程协助 → 输入上面的「设备码 + 验证码」" -ForegroundColor Magenta
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""

Log ("state=$state deviceId=$($info.deviceId) assistUsable=$assistUsable version=$($info.version) install=$($install.note)")
Write-Status ([ordered]@{
    state = $state; deviceName = $info.deviceName; deviceId = $info.deviceId; assistId = $info.assistId
    assistCode = $info.assistCode; assistUsable = $assistUsable; uuid = $info.uuid; version = $info.version
    installPath = $info.installPath; installOk = [bool]$install.ok; installNote = $install.note
    source = $install.source; updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
})
Set-GhEnv "UU_REMOTE=$state"
if ($info.deviceId)   { Set-GhEnv "UU_REMOTE_DEVICE=$($info.deviceId)" }
if ($assistUsable)    { Set-GhEnv "UU_REMOTE_ASSIST=$($info.assistCode)" }

# 公共桌面留一份（人在 RDP 里看不到 Actions 日志）
try {
    $pub = if ($env:PUBLIC) { $env:PUBLIC } else { 'C:\Users\Public' }
    $txt = Join-Path $pub 'Desktop\_CloudRDP_UU远程连接信息.txt'
    @(
        "UU远程（备用远程通道）连接信息"
        ""
        "  设备名 : $($info.deviceName)"
        "  设备码 : $($info.deviceId)"
        "  协助 id: $($info.assistId)"
        "  验证码 : $assistDisplay"
        ""
        "怎么连：装「网易UU远程」→ 远程协助 → 输入「设备码 + 验证码」。"
        "注意：UU远程 连的是控制台会话；若控制台不是 $uuUser，请在 $uuUser 桌面双击「切到 UU远程」。"
        ""
        "（本文件由开机流程 0c1 步自动生成）"
    ) | Out-File -LiteralPath $txt -Encoding UTF8
} catch { }

# ---------------------------------------------------------------- 发信
if ($NoMail -or $DryRun) { Say "已跳过发信（NoMail/DryRun）" }
else {
    $bodyLines = @(
        'CloudRDP 备用远程通道：UU远程（网易 GameViewer）'
        ''
        "  设备名   : $($info.deviceName)"
        "  设备码   : $(if ($info.deviceId) { $info.deviceId } else { '(未取到)' })"
        "  协助 id  : $(if ($info.assistId) { $info.assistId } else { '(无)' })"
        "  验证码   : $assistDisplay"
        "  版本     : $($info.version)"
        "  安装     : $($install.note)"
        "  状态     : $state"
        ''
        '怎么连（备用通道）：'
        '  1. 在手机 / 电脑装「网易UU远程」( https://uuyc.163.com/ )'
        '  2. 打开 → 远程协助 → 输入「设备码 + 验证码」（验证码解不开时用「协助 id」）'
        '  3. 即可看到本机桌面（控制台会话）'
        ''
        "注意：UU远程 连的是机器的控制台会话；若控制台不是 $uuUser，请在 $uuUser 桌面双击「切到 UU远程」。"
        '（Tailscale 主通道见 0e 步那封邮件。）'
        ''
        '-- 由 GitHub Actions 自动发送'
    )
    $body = ($bodyLines -join "`r`n")
    $mailScript = Join-Path $PSScriptRoot 'send-mail.ps1'
    if (Test-Path -LiteralPath $mailScript) {
        Say "发送 UU远程 连接信息到邮箱（日志：$LogPath）"
        try {
            & $mailScript -Subject "CloudRDP 备用通道 · UU远程（$($info.deviceName)）" -BodyText $body -MailTo $MailTo -LogPath $LogPath
            if ($LASTEXITCODE -eq 0) { Say "邮件已发送" }
            else { Warn "邮件发送失败（返回码 $LASTEXITCODE）—— 连接信息已明文打印在上方" }
        } catch { Warn "邮件发送异常：$($_.Exception.Message)" }
    } else { Warn "找不到 send-mail.ps1，跳过发信" }
}

exit 0
