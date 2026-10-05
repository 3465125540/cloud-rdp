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

  连接信息从哪来（★ 优先走官方 CLI —— 它给的是「设备 ID + 验证码」这一对能直接输入的凭据）：
    官方命令行  <安装目录>\bin\uuyc-cli.exe      （运维版文档里叫 uuycmgr.exe；两个名字都认）
      -d                 取「设备 ID」—— 纯数字，就是远程协助页面那个 ID（需主程序在跑）
      -c <code>          设置自定义验证码，并把验证方式切成「仅使用自定义验证码」
                         （客户端日志：setCustomVerifyCode: verify_type is TEMPORARY, switching to CUSTOMIZE）
    取不到 CLI 时退回读 ini —— 注意那里的协助码是 DPAPI 密文，跨机解不开，只能当排查信息：
      C:\ProgramData\Netease\GameViewer\user_info.ini          → deviceId（16 位内部设备码）
      C:\ProgramData\Netease\GameViewer\remote_assist_code.ini → code / customize_code（DPAPI）/ id（8 位）
      C:\ProgramData\Netease\GameViewer\config.ini             → uuid
    协助方拿到「设备 ID + 验证码」即可发起远控，无需登录 UU 账号。

  机器怎么标识（★ 别用 $env:COMPUTERNAME）：
    云机本身就是 GitHub 托管运行器 —— COMPUTERNAME 每次开机都是随机的 runnervmXXXX，打印它没意义
    （2026-10-02 用户反馈：「我要的是账户a的连接信息，不要runnervmfi6oq」）。
    用户认机器靠两样：账户（默认 a —— UU远程 连的就是它的控制台会话）+ Tailscale 身份
    （github-rdp-server-N + 100.x，登录界面/README 里用的就是它）。
    所以「机器」一行优先用 Tailscale 身份；COMPUTERNAME 降级成灰色「运行器名（仅排查）」。
    可用 CLOUDRDP_UU_MACHINE 覆盖机器标识（mail-test 单跑时用它标明「非账户 a 的云机」）。

.NOTES
  环境变量：
    CLOUDRDP_DATA_DIR  数据目录（找 D 盘便携副本用），默认 D:\a\cloud-rdp
    CLOUDRDP_UU_CODE   自定义验证码（默认 a1234567；等价于 -CustomCode）
    CLOUDRDP_UU_MACHINE 机器标识覆盖（默认自动取 Tailscale 身份；mail-test 用）
    RDP_USERNAME       被控账户（默认 a），用于「账户」一行 + 正文提示
    MAIL_*             与 0e 步同一套 SMTP 配置（缺失则自动跳过发信）
  退出码：**始终 0**（安装/发信失败都不该让开机流程变红）。
          状态写 <sysdir>\_state\uu-remote.json，并透出 UU_REMOTE=OK|PARTIAL|FAIL 到 GITHUB_ENV。
  开关：CLOUDRDP_UU_INSTALL=0 → 只读现有信息、不装；-SkipInstall / -NoSetCode / -NoMail / -DryRun。
  诊断日志：默认 <sysdir>\_state\uu-remote.log（用 -LogPath 覆盖）。
#>
[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\Program Files\Netease\GameViewer',
    [string]$DataDir    = $(if ($env:CLOUDRDP_DATA_DIR) { [string]$env:CLOUDRDP_DATA_DIR } else { 'D:\a\cloud-rdp' }),
    [string]$LogPath    = '',
    [string]$MailTo     = '',
    # ★ 自定义验证码 —— 用官方 CLI `uuyc-cli.exe -c` 写进 UU远程。
    #   为什么要有它：ini 里的协助码是 DPAPI 密文，且从 139 还原来的那份是在**别的机器**上加密的，
    #   跨机解不开 —— 打印出来等于没打印。设一个我们自己的固定码之后，「验证码」就是一串
    #   已知的明文，主控端拿来就能连。
    #   格式（客户端硬校验）：8~16 位，字母 + 数字**都要有**，否则 CLI 直接报
    #   `Error: Invalid verification code format (must be 8-16 letters/digits, containing both)`。
    [string]$CustomCode = $(if ($env:CLOUDRDP_UU_CODE) { [string]$env:CLOUDRDP_UU_CODE } else { 'a1234567' }),
    [switch]$SkipInstall,
    [switch]$NoSetCode,
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
# ★ 兜底：winget 装到哪**不一定**（实测 windows-latest 上 winget 报 Successfully installed，
#    已知路径却找不到 GameViewer.exe —— 新版可能换了目录名）。在常见安装根里**有界扫描**兜住。
function Find-GameViewerExe([int]$Depth = 3) {
    $roots = @(
        'C:\Program Files', 'C:\Program Files (x86)',
        (Join-Path $env:LOCALAPPDATA 'Programs'),
        $env:LOCALAPPDATA
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    foreach ($r in $roots) {
        try {
            $hit = Get-ChildItem -LiteralPath $r -Filter 'GameViewer.exe' -Recurse -Depth $Depth `
                       -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        } catch { }
    }
    return ''
}

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
    # 已知路径全没命中 → 有界扫描兜底（只在这时才扫，平时零开销）
    if ($list.Count -eq 0) {
        $hit = Find-GameViewerExe
        if ($hit) { $list.Add($hit) }
    }
    # ⚠️ 必须 `,@(...)`：PowerShell 返回单元素数组会被**解包成标量**，
    #    于是 `$exe[0]` 变成字符串的首字符 'C'（实测踩过：安装路径显示成 "C"）。
    return ,@($list)
}

# 装完找不到 exe 时的**取证**：列出候选根目录里像 UU远程 的目录（下次好定位它到底装哪了）。
function Get-UUInstallHints {
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($r in @(
        'C:\Program Files', 'C:\Program Files (x86)',
        (Join-Path $env:LOCALAPPDATA 'Programs'),
        $env:LOCALAPPDATA
    )) {
        if (-not $r -or -not (Test-Path -LiteralPath $r)) { continue }
        try {
            Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '(?i)netease|uu|gameviewer|game viewer|网易|远程' } |
                ForEach-Object { $hits.Add($_.FullName) }
        } catch { }
    }
    return ,@($hits)
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

# ---------------------------------------------------------------- ★ 官方 CLI：设备 ID + 自定义验证码
# UU远程 自带命令行工具 <安装目录>\bin\uuyc-cli.exe（运维版文档里叫 uuycmgr.exe，两个名字都认）。
# 为什么用它，而不是自己去改 remote_assist_code.ini：
#   ini 里的 code / customize_code 是 DPAPI 密文，只有「本机 + 写它的那个账户」解得开。
#   从 139 云盘还原过来的那份是在**别的机器**上加密的 → 本机 Unprotect 直接报「数据无效」。
#   CLI 走的是官方通道：-d 读设备 ID，-c 让主程序自己把自定义码写进去（它自己加解密，稳）。
# 前提：主程序 GameViewer.exe 必须在跑（同一个会话里，走 IPC）。
function Find-UUCli {
    $names = @('uuyc-cli.exe', 'uuycmgr.exe')
    $dirs = New-Object System.Collections.Generic.List[string]
    foreach ($exe in (Get-UUCandidateExes)) {
        $d = Split-Path -Parent $exe
        if ($d) {
            $dirs.Add($d)                                   # …\GameViewer\bin
            $dirs.Add((Split-Path -Parent $d))              # …\GameViewer
            $dirs.Add((Join-Path (Split-Path -Parent $d) 'bin'))
        }
    }
    foreach ($d in @($InstallDir, (Join-Path $InstallDir 'bin'),
                     (Join-Path $env:LOCALAPPDATA 'Programs\GameViewer'),
                     (Join-Path $env:LOCALAPPDATA 'Programs\GameViewer\bin'))) {
        if ($d) { $dirs.Add([string]$d) }
    }
    foreach ($d in $dirs) {
        foreach ($n in $names) {
            try {
                $p = Join-Path $d $n
                if (Test-Path -LiteralPath $p) { return $p }
            } catch { }
        }
    }
    return ''
}

# 直接 & 调用（不要 Start-Process：那会换会话，IPC 就断了）。
function Invoke-UUCli([string[]]$CliArgs) {
    if (-not $CliPath) { return @{ ok = $false; out = '未找到 CLI'; code = -1 } }
    try {
        $out = (& $CliPath @CliArgs 2>&1 | Out-String).Trim()
        return @{ ok = ($LASTEXITCODE -eq 0); out = $out; code = $LASTEXITCODE }
    } catch {
        return @{ ok = $false; out = [string]$_.Exception.Message; code = -1 }
    }
}

# 设备 ID：主控端要输入的就是它（纯数字）。主程序刚起时要等一会儿 IPC 才通，所以重试几轮。
function Get-UUDeviceIdViaCli([int]$Tries = 6, [int]$SleepSec = 5) {
    if (-not $CliPath) { return '' }
    for ($i = 0; $i -lt $Tries; $i++) {
        $r = Invoke-UUCli -CliArgs @('-d')
        if ($r.out -match '(\d{6,12})') { return $Matches[1] }
        if ($i -lt $Tries - 1) { Start-Sleep -Seconds $SleepSec }
    }
    return ''
}

# 设置自定义验证码 = 把验证方式切成「仅使用自定义验证码」（客户端会自动做这个切换）。
# 成功：exit 0 + "Verification code reset successfully"
# 失败：exit 4 + "Error: Invalid verification code format (must be 8-16 letters/digits, containing both)"
function Set-UUCustomCode([string]$Code) {
    if (-not $CliPath) { return @{ ok = $false; note = '未找到 uuyc-cli.exe / uuycmgr.exe' } }
    if ([string]::IsNullOrWhiteSpace($Code)) { return @{ ok = $false; note = '自定义验证码为空' } }
    $last = ''
    for ($i = 0; $i -lt 3; $i++) {
        $r = Invoke-UUCli -CliArgs @('-c', $Code)
        $last = $r.out
        if ($r.ok -and ($r.out -notmatch '(?i)^\s*error')) {
            return @{ ok = $true; note = "已设置（uuyc-cli -c，exit=$($r.code)）" }
        }
        # 个别版本把 code 当交互输入读 stdin → 再试一次管道方式
        try {
            $Code | & $CliPath -c 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { return @{ ok = $true; note = '已设置（stdin 方式）' } }
        } catch { }
        if ($i -lt 2) { Start-Sleep -Seconds 5 }
    }
    return @{ ok = $false; note = "设置失败：$last" }
}

# ---------------------------------------------------------------- ★ 机器标识（用户视角）
# ⚠️ 云机本身就是 GitHub 托管运行器 —— $env:COMPUTERNAME 每次开机都是随机的 runnervmXXXX。
#    打印它等于没打印：用户收到邮件只看到一串乱码名（2026-10-02 用户反馈原话：
#    「我要的是账户a的连接信息，不要runnervmfi6oq」）。用户认机器靠的是两样 ——
#      * Tailscale 名（github-rdp-server-N）+ 100.x IP（登录界面/README 里都是它）
#      * 被控账户（默认 a）—— UU远程 连的就是它的控制台会话
#    所以「机器」一行优先用 Tailscale 身份 + 账户；COMPUTERNAME 只留作灰色排查信息。
function Find-Tailscale {
    foreach ($p in @(
        'C:\Program Files\Tailscale\tailscale.exe',
        'C:\Program Files (x86)\Tailscale\tailscale.exe'
    )) { if (Test-Path -LiteralPath $p) { return $p } }
    $c = Get-Command tailscale -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return ''
}

function Get-UUMachineIdentity {
    $id = [ordered]@{ name = ''; ip = ''; account = $uuUser; label = ''; source = '' }
    # ① Tailscale 自身身份（hostname + 100.x）
    try {
        $ts = Find-Tailscale
        if ($ts) {
            $json = (& $ts status --json 2>$null | Out-String)
            if ($json) {
                $o = $json | ConvertFrom-Json
                if ($o.Self) {
                    $id.name = [string]$o.Self.HostName
                    if (-not $id.name -and $o.Self.DNSName) { $id.name = ([string]$o.Self.DNSName).Split('.')[0] }
                    # 优先 IPv4（100.x）—— 用户拿它 RDP；Tailscale 有时把 IPv6 排前面
                    $ips = @($o.Self.TailscaleIPs)
                    $v4 = $ips | Where-Object { [string]$_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1
                    if ($v4) { $id.ip = [string]$v4 } elseif ($ips.Count -gt 0) { $id.ip = [string]$ips[0] }
                }
            }
        }
    } catch { }
    # ② 兜底：0c 步已把 TS_IP 写进 GITHUB_ENV
    if (-not $id.ip -and $env:TS_IP) { $id.ip = ([string]$env:TS_IP).Trim() }
    # ③ 组装标签
    if ($id.name -and $id.ip) { $id.label = "$($id.name) ($($id.ip))"; $id.source = 'tailscale' }
    elseif ($id.ip)           { $id.label = "($($id.ip))";               $id.source = 'tailscale-ip' }
    else                      { $id.label = '(本机 · 未接入 Tailscale)';  $id.source = 'none' }
    return $id
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

# 机器标识（账户 + Tailscale）—— 用于打印 / 邮件 / 桌面文件。
# ★ 绝不再出现随机 runnervmXXXX：云机 = GitHub 托管运行器，COMPUTERNAME 每次开机都变。
$mi = Get-UUMachineIdentity
$machineLabel = if ($env:CLOUDRDP_UU_MACHINE) { [string]$env:CLOUDRDP_UU_MACHINE } else { $mi.label }
Say "机器标识：账户 $uuUser · $machineLabel（来源 $($mi.source)）"

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
        # 给安装器落盘留时间；已知路径找不到就再等一轮（新版换目录 / 落盘慢都可能）。
        # 三轮 × 5s 后仍找不到 → 记「取证」（候选目录），下次好定位它到底装哪了。
        $existing = @()
        for ($i = 0; $i -lt 3; $i++) {
            Start-Sleep -Seconds 5
            $existing = Get-UUCandidateExes
            if ($existing.Count -gt 0) { break }
        }
        if ($existing.Count -gt 0) { $install = @{ ok = $true; note = $r.note; exe = $existing[0]; source = 'installed' } }
        else {
            $hints = Get-UUInstallHints
            $hintTxt = if ($hints.Count -gt 0) { $hints -join ' | ' } else { '(无)' }
            Log "install hints: $hintTxt"
            Warn "装完找不到 GameViewer.exe；候选目录：$hintTxt"
            $install = @{ ok = $false; note = "安装命令返回成功但找不到 GameViewer.exe（$($r.note)）"; exe = ''; source = '' }
        }
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

# ---------------------------------------------------------------- ★ 官方 CLI 就位
$CliPath = ''
$devNum  = ''
$codeSet = @{ ok = $false; note = '未执行' }
if ($install.ok -and $install.exe) {
    $CliPath = Find-UUCli
    if ($CliPath) { Say "官方 CLI：$CliPath" }
    else { Warn "未找到 uuyc-cli.exe / uuycmgr.exe（老版本可能没有）—— 退回只读 ini" }
}

# ★ 用官方 CLI 取「设备 ID」+ 设「自定义验证码」（都要主程序在跑；-d 只读，DryRun 也允许试）
if ($CliPath) {
    $devNum = Get-UUDeviceIdViaCli
    if ($devNum) { Say "设备 ID（CLI -d）= $devNum" }
    else { Warn "CLI -d 未取到设备 ID（主程序可能还没起好）" }

    if ($NoSetCode -or $DryRun) {
        $codeSet = @{ ok = $false; note = '已跳过（NoSetCode/DryRun）' }
        Say "已跳过设置自定义验证码（NoSetCode/DryRun）"
    } else {
        $codeSet = Set-UUCustomCode $CustomCode
        if ($codeSet.ok) { Say "自定义验证码已设为「$CustomCode」→ 验证方式 = 仅使用自定义验证码" }
        else { Warn "设置自定义验证码失败：$($codeSet.note)" }
    }
}

# 读连接信息（CLI 没设成自定义码，才需要退回 ini 的协助码 —— 那份多半是跨机 DPAPI 密文）
$info = Get-UUConnectionInfo
if (-not $codeSet.ok -and -not (Test-AssistUsable $info.assistCode) -and $install.ok -and -not $DryRun) {
    Say "CLI 未设成自定义码，且 ini 里的协助码是 DPAPI 密文（多半从别的机器还原来的）—— 再等 20s 让 UU远程 在本机重生成 ..."
    Start-Sleep -Seconds 20
    $again = Get-UUConnectionInfo
    if (Test-AssistUsable $again.assistCode) { $info = $again; Say "已拿到本机可用的协助码" }
}
if ($install.exe) { $info.version = Get-UUVersion $install.exe }
$info.installPath = [string]$install.exe

# 验证码取值优先级：① 我们自己设的自定义码（已知明文，最可靠）→ ② ini 里能解开的协助码
$assistCode = ''
$codeSource = ''
if ($codeSet.ok)                              { $assistCode = $CustomCode;          $codeSource = 'custom(CLI 已设置)' }
elseif (Test-AssistUsable $info.assistCode)   { $assistCode = [string]$info.assistCode; $codeSource = 'ini(本机可解密)' }
$assistUsable = [bool]$assistCode

# 设备 ID 取值：CLI 的数字 ID 优先（主控端就输它）；否则退回 ini 的 16 位内部设备码
$deviceDisplay = if ($devNum) { $devNum } elseif ($info.deviceId) { [string]$info.deviceId } else { '' }
$deviceIsNumeric = [bool]($deviceDisplay -match '^\d+$')

# 判定：装了 + 有设备 ID + 有可用验证码 = OK；缺一档 = PARTIAL
$state = 'FAIL'
if ($install.ok -and $deviceDisplay -and $assistUsable) { $state = 'OK' }
elseif ($install.ok -or $deviceDisplay) { $state = 'PARTIAL' }

$assistDisplay = if ($assistCode) { $assistCode }
                 elseif ($NoSetCode -or $DryRun) { '(已跳过设置)' }
                 else { '(未取到：官方 CLI 不可用，且 ini 里的码是 DPAPI 密文·跨机解不开 —— 需在机器上打开 UU远程 查看)' }

# ---------------------------------------------------------------- 打印
$devLine = if (-not $deviceDisplay) { '(未取到)' }
           elseif ($deviceIsNumeric) { $deviceDisplay }
           else { "$deviceDisplay  (CLI 不可用，退回内部 deviceId)" }
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  UU远程（备用远程通道）连接信息" -ForegroundColor Cyan
Write-Host "  账户       : $uuUser（UU远程 连的就是它的控制台会话）" -ForegroundColor Cyan
Write-Host "  机器       : $machineLabel" -ForegroundColor Cyan
Write-Host "  设备 ID    : $devLine" -ForegroundColor Yellow
Write-Host "  验证码     : $assistDisplay" -ForegroundColor Yellow
Write-Host "  >> 主控端只输上面两项：设备 ID + 验证码" -ForegroundColor Magenta
Write-Host "  运行器名   : $($info.deviceName)  ← 仅排查（云机 = GitHub 托管运行器，每次开机都变）" -ForegroundColor DarkGray
if ($info.deviceId -and $info.deviceId -ne $deviceDisplay) { Write-Host "  设备码(内部): $($info.deviceId)" -ForegroundColor DarkGray }
if ($info.assistId) { Write-Host "  协助 id    : $($info.assistId)" -ForegroundColor DarkGray }
if ($info.uuid)     { Write-Host "  uuid       : $($info.uuid)" -ForegroundColor DarkGray }
if ($info.version)  { Write-Host "  版本       : $($info.version)" -ForegroundColor DarkGray }
Write-Host "  安装       : $($install.note)"
Write-Host "  安装路径   : $(if ($info.installPath) { $info.installPath } else { '(无)' })" -ForegroundColor DarkGray
Write-Host "  自定义码   : $($codeSet.note)" -ForegroundColor DarkGray
Write-Host "  状态       : $state" -ForegroundColor $(if ($state -eq 'OK') { 'Green' } elseif ($state -eq 'PARTIAL') { 'Yellow' } else { 'Red' })
Write-Host "  >> 协助方：装「网易UU远程」→ 远程协助 → 输入「设备 ID + 验证码」" -ForegroundColor Magenta
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""

Log ("state=$state account=$uuUser machine=$machineLabel machineSrc=$($mi.source) deviceId=$deviceDisplay devNum=$devNum assistUsable=$assistUsable codeSource=$codeSource cli=$CliPath version=$($info.version) install=$($install.note) runner=$($info.deviceName)")
Write-Status ([ordered]@{
    state = $state; account = $uuUser
    machine = $machineLabel; machineName = $mi.name; machineIp = $mi.ip; machineSource = $mi.source
    runnerName = $info.deviceName; deviceName = $info.deviceName
    deviceId = $deviceDisplay; deviceIdNumeric = $devNum; deviceIdInternal = $info.deviceId
    assistId = $info.assistId; assistCode = $assistCode; codeSource = $codeSource
    customCode = $(if ($codeSet.ok) { $CustomCode } else { '' }); customCodeNote = $codeSet.note
    assistUsable = $assistUsable; uuid = $info.uuid; version = $info.version
    cliPath = $CliPath
    installPath = $info.installPath; installOk = [bool]$install.ok; installNote = $install.note
    source = $install.source; updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
})
Set-GhEnv "UU_REMOTE=$state"
Set-GhEnv "UU_REMOTE_ACCOUNT=$uuUser"
if ($machineLabel)  { Set-GhEnv "UU_REMOTE_MACHINE=$machineLabel" }
if ($deviceDisplay) { Set-GhEnv "UU_REMOTE_DEVICE=$deviceDisplay" }
if ($devNum)        { Set-GhEnv "UU_REMOTE_DEVICE_ID=$devNum" }
if ($info.deviceId) { Set-GhEnv "UU_REMOTE_DEVICE_LONG=$($info.deviceId)" }
if ($assistUsable)  { Set-GhEnv "UU_REMOTE_ASSIST=$assistCode" }
if ($codeSet.ok)    { Set-GhEnv "UU_REMOTE_CODE=$CustomCode" }

# 桌面 / 状态目录各留一份（人在 RDP 里看不到 Actions 日志）。
# ⚠️ 非管理员时 C:\Users\Public\Desktop 是**拒绝写**的（实测 Access denied）——
#    所以逐个候选目录试，首个成功即止，并把落点写进日志（别再静默吞掉）。
try {
    $infoLines = @(
        "UU远程（备用远程通道）连接信息"
        ""
        "  账户    : $uuUser（UU远程 连的就是它的控制台会话）"
        "  机器    : $machineLabel"
        "  设备 ID : $devLine"
        "  验证码  : $assistDisplay"
        ""
        "主控端只输上面两项：设备 ID + 验证码。"
        ""
        "  ── 以下为排查信息，连接不需要 ──"
        "  运行器名  : $($info.deviceName)（云机 = GitHub 托管运行器，每次开机都变，别记它）"
        "  内部设备码: $($info.deviceId)"
        "  协助 id   : $($info.assistId)"
        "  自定义码  : $($codeSet.note)"
        "  状态      : $state"
        ""
        "怎么连：装「网易UU远程」→ 远程协助 → 输入「设备 ID + 验证码」。"
        "注意：UU远程 连的是控制台会话；若控制台不是 $uuUser，请在 $uuUser 桌面双击「切到 UU远程」。"
        ""
        "（本文件由开机流程 0c1 步自动生成）"
    )
    $cands = New-Object System.Collections.Generic.List[string]
    if ($env:PUBLIC)      { $cands.Add((Join-Path $env:PUBLIC      'Desktop\_CloudRDP_UU远程连接信息.txt')) }
    if ($env:USERPROFILE) { $cands.Add((Join-Path $env:USERPROFILE 'Desktop\_CloudRDP_UU远程连接信息.txt')) }
    $cands.Add((Join-Path $stateDir 'uu-remote-info.txt'))
    $wrote = ''
    foreach ($t in $cands) {
        try {
            $dir = Split-Path -Parent $t
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { continue }
            $infoLines | Out-File -LiteralPath $t -Encoding UTF8
            $wrote = $t; break
        } catch { }
    }
    if ($wrote) { Say "连接信息已写到：$wrote"; Log "info file: $wrote" }
    else { Warn "连接信息文件写不进去（Public 桌面 / 用户桌面 / 状态目录都不行）" }
} catch { Warn "写连接信息文件异常：$($_.Exception.Message)" }

# ---------------------------------------------------------------- 发信
if ($NoMail -or $DryRun) { Say "已跳过发信（NoMail/DryRun）" }
else {
    # ★ 邮件正文刻意**精简** —— 139 的反垃圾是**按内容评分**的，超阈值直接拒
    #   （真机 run #84：`550 … Mail rejected score is 20.156`）。
    #   决定性证据：同一批发信、同一套邮件头 / 编码 / 发件人 / IP、相隔 5 秒，
    #   0e 那封（结构相同、内容更素）当场收 250，只有这封被 550 —— **差别只在内容**，
    #   与账号 / 发信 IP / CTE 编码无关。高判分特征全集中在这封：
    #     ① 主题里塞了 IP + 设备 ID + 验证码（又长又像机器生成）；
    #     ② 正文反复出现「验证码」（= 钓鱼邮件「您的验证码是 XXXX」的典型特征）；
    #     ③ 品牌名（网易 / UU远程 / GameViewer）+ 下载链接（推广特征）；
    #     ④ 一整段内部排查信息（运行器名 / 内部设备码 / 协助 id / 版本 …）。
    #   ⇒ 邮件版只留「怎么连」必需的三行；品牌 / 链接 / 排查块一律不进邮件。
    #   桌面 txt（$infoLines）与 Actions 日志仍然保留完整信息 —— 那两处不过滤。
    $bodyLines = @(
        'CloudRDP 备用通道已就绪，现在就能连。'
        ''
        "  机器    : $machineLabel"
        "  设备 ID : $devLine"
        "  连接码  : $assistDisplay"
        ''
        '怎么连：安装「UU远程」客户端 -> 远程协助 -> 填上面的设备 ID 和连接码。'
        ''
        '这是主通道之外的备用方案；主通道信息见另一封邮件。'
        ''
        '-- 由 GitHub Actions 自动发送'
    )
    $body = ($bodyLines -join "`r`n")
    $mailScript = Join-Path $PSScriptRoot 'send-mail.ps1'
    if (Test-Path -LiteralPath $mailScript) {
        Say "发送 UU远程 连接信息到邮箱（日志：$LogPath）"
        try {
            # ★ 主题必须是**中性短句**：旧主题把 账户 / 机器 / 设备 ID / 验证码 全塞进去，
            #   又长又像机器生成，是 139 反垃圾的加分项（真机 run #84 那封就栽在内容评分上）。
            & $mailScript -Subject "CloudRDP 备用通道信息" -BodyText $body -MailTo $MailTo -LogPath $LogPath
            if ($LASTEXITCODE -eq 0) { Say "邮件已发送" }
            else { Warn "邮件发送失败（返回码 $LASTEXITCODE）—— 连接信息已明文打印在上方" }
        } catch { Warn "邮件发送异常：$($_.Exception.Message)" }
    } else { Warn "找不到 send-mail.ps1，跳过发信" }
}

exit 0
