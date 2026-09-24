<#
.SYNOPSIS
  开机时（用户登录前）把系统语言配成「简体中文 + 微软拼音输入法」。

.DESCRIPTION
  为什么需要：GitHub runner 的 Windows Server 镜像默认 en-US，
  RDP 用户 a 首次登录是纯英文界面，且没有中文输入法。

  ⚠️ 本脚本的第一原则：**秒级放行，绝不拖慢开机**。
  Install-Language 联网下载 FoD 语言包实测要 30~43 分钟，而它只是「锦上添花」。
  所以语言包安装被交给**计划任务**在后台装，主脚本只做三件快事：
    ① 把安装挂到计划任务（Task Scheduler 服务拉起）
    ② 立刻写完机器级 locale + 用户级 HKCU 语言键（秒级）
    ③ 分段落盘 + 透出状态，最后最多再同步等 LangPackWaitSec 秒（默认 90）

  为什么用计划任务，而不是老的「Start-Process + 超时转后台」：
    2026-09-23 复盘（run 35813312970）查出两个硬伤：
      a) 0f 步 timeout-minutes=6（360s），而脚本同步等语言包就要 300s，
         加上系统 locale 2s + 用户 hive 33s + 增强步 ≥19s ≈ 360s —— **必然超时**。
         实测时间线：03:12:41 起 → 03:17:46 语言包等满 300s → 03:18:22 写完用户 hive
         → 03:18:41 被 step 超时杀掉，正好 360s。
      b) GitHub Actions 在 step 超时/结束时会把该 step 的**整棵进程树**杀掉。
         老代码 Start-Process 起的那个「后台」子进程跟 step 是同一棵树，
         于是它一起被 kill —— 语言包**从来没装成功过**（日志里只有 TIMEOUT_BACKGROUND，
         从没出现「语言包安装结束」）。计划任务由 Task Scheduler 服务启动，
         不属于本 step 的进程树，才能真正活到开机流程之后。
      c) 老代码把 CHINESE_STATUS 等状态写在脚本**最后**，被 kill 后一个都没透出 ——
         所以 ENV READY 里「中文环境」整行消失，看起来就是「每次都失败」。
         现在改成**分段落盘**，任何时刻被 kill 都留得下一份自洽的状态。

  两层设置：
    A. 机器级（HKLM）—— 安装 zh-Hans-CN 语言包 + 系统 locale / 显示语言覆盖。
       注册表立即写入；locale 类设置要重启才完全生效（对一次性 VM 意义有限，
       但用户登录后的大部分 UI 由 HKCU 决定，见 B）。
    B. 用户级（用户 a 的 HKCU）—— 直接写「语言列表 + 微软拼音 + 键盘布局」。
       必须在用户登录前写好，登录后才会带中文输入法。

  用户级为什么直接写注册表，而不是 Set-WinUserLanguageList？
    该 cmdlet 只作用于「当前用户」，而本脚本以 runneradmin 身份运行。
    因此先 reg load 用户 a 的 NTUSER.DAT 到 HKU\_LangCfg，再按 Windows
    真实结构写入（结构照抄一台中文 Windows 的
    HKCU\Control Panel\International\User Profile）。
    随后再尝试用 Start-Process -Credential 在该用户会话里跑一次
    Set-WinUserLanguageList 作为增强（失败不影响已写入的注册表）。

  本脚本永不返回非 0（失败只告警，不影响开机）。结果透出：
    CHINESE_STATUS / CHINESE_LANGPACK / CHINESE_SYSTEMLOCALE / CHINESE_USERHIVE
  同时落盘 <SysDir>\_state\chinese-status.json，供工作台 / 收尾核对步骤读取。
#>
[CmdletBinding()]
param(
    [string]$RdpUser         = $(if ($env:RDP_USERNAME) { $env:RDP_USERNAME } else { 'a' }),
    [string]$PrimaryLocale   = 'zh-Hans-CN',
    [string]$SecondaryLocale = 'en-US',
    [string]$ConfigPath      = '',
    # 状态目录（语言包进度 / 状态文件都在它下面的 _state）。
    # 必须能显式传入：计划任务子进程**不继承** job 环境变量，拿不到 CLOUDRDP_SYS_DIR。
    [string]$SysDir          = '',
    [switch]$SkipLanguagePack,
    [switch]$SkipUserHive,
    # 只补写「用户 HKCU 语言键」（秒级）。用于「预还原之后」再补一次 ——
    # 因为预还原会导入 registry\user\HKCU-Software.reg，把早段写的语言键覆盖掉。
    [switch]$UserHiveOnly,
    # 子进程模式：只装语言包，装完写 langpack-done.txt 后退出。
    # 由计划任务（首选）或 Start-Process（兜底）拉起。
    [switch]$InstallPackOnly,
    # 收尾核对模式：不装包、不写注册表，只把后台安装的最新结果透出（幂等、秒级）。
    # 用于 step 12b / keepalive 自愈循环 —— 后台装完了要有人把它记下来。
    [switch]$CheckOnly,
    # 同步等待语言包的上限（秒）。超时就把状态标成「后台安装中」，不阻塞开机。
    # 默认 90s：足够吃掉「已缓存 / 秒装完」的快路径，又远小于 step 超时。
    [int]$LangPackWaitSec    = 90,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

# 配置文件路径：不在 param 默认值里依赖 $PSScriptRoot（某些调用方式下它可能为空）
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'snapshot-config.json'
}

# 用户注册表 hive 共享库（定位 / 判断是否已加载）
# 「连接信息提前打印」之后，用户常常已经登录 —— 此时 hive 已被 Windows 加载，
# 不能再 reg load（必然失败），要直接写 HKU\<SID>，并且**绝不能 unload**。
$userHiveLib = Join-Path $PSScriptRoot 'userhive-lib.ps1'
$script:HasUserHiveLib = $false
if (Test-Path -LiteralPath $userHiveLib) { . $userHiveLib; $script:HasUserHiveLib = $true }
else { Write-Warning '[chinese] 未找到 userhive-lib.ps1，用户已登录时的兜底不可用' }

# 用户配置文件预创建共享库。为什么需要：写用户 HKCU 语言键的前提是 NTUSER.DAT 存在；
# 旧代码用 `Start-Process -Credential`（**缺 -LoadUserProfile**）预创建，进程起得来、
# 不报错，但 profile 根本没被创建 → 中文输入法这一轮落空（与用户数据丢失同一个根因）。
$userProfileLib = Join-Path $PSScriptRoot 'userprofile-lib.ps1'
$script:HasUserProfileLib = $false
if (Test-Path -LiteralPath $userProfileLib) { . $userProfileLib; $script:HasUserProfileLib = $true }
else { Write-Warning '[chinese] 未找到 userprofile-lib.ps1，用户配置文件预创建不可用' }

# 微软拼音输入法 TIP（简体中文默认输入法）
$PinyinTip = '0804:{81D4E9C9-1D3B-41BC-9E6C-4B40BF79E35E}{FA550B04-5AD7-411F-A5AC-CA038EC515D7}'
# 语言 -> 键盘布局 LCID（写入 Keyboard Layout\Preload）
$PreloadMap = @{
    'zh-Hans-CN' = '00000804'
    'zh-CN'      = '00000804'
    'en-US'      = '00000409'
}

function Say([string]$m)  { Write-Host "[chinese] $m" }
function Warn([string]$m) { Write-Warning "[chinese] $m" }
function Note([string]$m) { Write-Host "[chinese] $m" -ForegroundColor DarkGray }
function Set-GhEnv([string]$kv) { if ($env:GITHUB_ENV) { $kv | Out-File $env:GITHUB_ENV -Append -Encoding ascii } }
function Get-Cfg($obj, $name, $fallback) {
    if ($null -eq $obj) { return $fallback }
    if ($obj -is [System.Collections.IDictionary]) {
        if ($obj.Contains($name) -and $null -ne $obj[$name]) { return $obj[$name] }
        return $fallback
    }
    $p = $obj.PSObject.Properties[$name]
    if ($null -eq $p -or $null -eq $p.Value) { return $fallback }
    return $p.Value
}

# ---------------------------------------------------------------- 读配置
$cfg = $null
if (Test-Path -LiteralPath $ConfigPath) {
    try { $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Warn "配置解析失败（$ConfigPath）：$_" }
}
$chCfg   = Get-Cfg $cfg 'chinese' $null
$enabled = [bool](Get-Cfg $chCfg 'enabled' $true)
$wantLp  = [bool](Get-Cfg $chCfg 'installLanguagePack' $true)
if ($SkipLanguagePack) { $wantLp = $false }
# -UserHiveOnly：只补写用户 HKCU 语言键（预还原之后那次），不装包、不动机器级 locale
$wantSys = $true
if ($UserHiveOnly) { $wantLp = $false; $wantSys = $false }
$loc = [string](Get-Cfg $chCfg 'primaryLocale'   $PrimaryLocale)
$sec = [string](Get-Cfg $chCfg 'secondaryLocale' $SecondaryLocale)

# 命令行/环境变量覆盖（workflow_dispatch 输入）
if (-not [string]::IsNullOrWhiteSpace($env:INPUT_CHINESE)) {
    $ov = $env:INPUT_CHINESE.Trim().ToLower()
    if ($ov -eq 'off' -or $ov -eq 'false' -or $ov -eq '0') { $enabled = $false }
    elseif ($ov -eq 'on' -or $ov -eq 'true' -or $ov -eq '1') { $enabled = $true }
}

# ---------------------------------------------------------------- 状态目录（语言包进度 / 状态文件）
if ([string]::IsNullOrWhiteSpace($SysDir)) {
    $SysDir = if ($env:CLOUDRDP_SYS_DIR) { $env:CLOUDRDP_SYS_DIR } elseif (Test-Path 'D:\') { 'D:\cloudrdp-sys' } else { 'C:\cloudrdp-sys' }
}
$stateDir  = Join-Path $SysDir '_state'
$lpDone    = Join-Path $stateDir 'langpack-done.txt'
$lpLog     = Join-Path $stateDir 'langpack.log'
$stateJson = Join-Path $stateDir 'chinese-status.json'
$taskName  = 'CloudRDP-LangPack'
try { New-Item -ItemType Directory -Force -Path $stateDir | Out-Null } catch { }

# ---------------------------------------------------------------- 状态透出 / 落盘
$problems = New-Object System.Collections.Generic.List[string]

# 总状态口径（与工作台 server.py 的展示口径一致）：
#   语言包 PENDING / TIMEOUT_BACKGROUND = 还在后台装 → 不算 OK，但也不算失败
function Get-ChineseOverall {
    param([string]$LangState, [string]$HiveState)
    $langBusy = @('PENDING', 'TIMEOUT_BACKGROUND')
    if ($problems.Count -eq 0 -and ($langBusy -notcontains $LangState)) { return 'OK' }
    if ($LangState -eq 'FAILED' -and $HiveState -ne 'OK') { return 'FAILED' }
    return 'PARTIAL'
}

# 分段落盘：任何时刻调用都写出一份自洽快照。这样即使脚本在最后的同步等待里
# 被 step 超时杀掉，GITHUB_ENV 里也已经有前面写好的状态（老代码的致命缺陷）。
function Write-ChineseState {
    param([string]$LangState, [string]$SysState, [string]$HiveState, [string]$Phase, [string]$EnhState = '')
    $overall = Get-ChineseOverall -LangState $LangState -HiveState $HiveState
    Set-GhEnv "LANGPACK=$LangState"
    Set-GhEnv "CHINESE_LANGPACK=$LangState"
    Set-GhEnv "CHINESE_SYSTEMLOCALE=$SysState"
    Set-GhEnv "CHINESE_USERHIVE=$HiveState"
    Set-GhEnv "CHINESE_LOCALE=$loc"
    if (-not [string]::IsNullOrWhiteSpace($EnhState)) { Set-GhEnv "CHINESE_ENHANCE=$EnhState" }
    Set-GhEnv "CHINESE_STATUS=$overall"
    try {
        $obj = [ordered]@{
            updated_utc   = (Get-Date).ToUniversalTime().ToString('o')
            phase         = $Phase
            status        = $overall
            langpack      = $LangState
            systemlocale  = $SysState
            userhive      = $HiveState
            enhance       = $EnhState
            locale        = $loc
            secondary     = $sec
            host          = $env:COMPUTERNAME
            run_id        = $env:GITHUB_RUN_ID
            problems      = @($problems)
        }
        $tmp = $stateJson + '.tmp'
        ($obj | ConvertTo-Json -Depth 5) | Out-File -LiteralPath $tmp -Encoding utf8
        try { if ([System.IO.File]::Exists($stateJson)) { [System.IO.File]::Delete($stateJson) } } catch { }
        [System.IO.File]::Move($tmp, $stateJson)
    } catch { }
    return $overall
}

# ---------------------------------------------------------------- 后台安装：优先计划任务
# 为什么必须是计划任务：GitHub Actions 会在 step 结束/超时时杀掉该 step 的整棵进程树，
# Start-Process 的子进程活不过 step。计划任务由 Task Scheduler 服务拉起，不在那棵树里。
function Start-LangPackBackground {
    $exe = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $exe) { $exe = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source }
    if (-not $exe) { Warn '找不到 pwsh/powershell，无法启动语言包安装'; return 'FAILED' }

    $argStr = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -InstallPackOnly -PrimaryLocale "{1}" -RdpUser "{2}" -SysDir "{3}"' -f `
              $PSCommandPath, $loc, $RdpUser, $SysDir

    # ① 计划任务（首选；活得过 step 超时）
    try {
        if (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue) {
            $act = New-ScheduledTaskAction -Execute $exe -Argument $argStr -WorkingDirectory $PSScriptRoot
            $prn = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                       -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 3)
            Register-ScheduledTask -TaskName $taskName -Action $act -Principal $prn -Settings $set `
                -Description 'CloudRDP: 开机后台安装 zh-Hans-CN 语言包（含微软拼音）' -Force -ErrorAction Stop | Out-Null
            Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
            Note ("  已挂计划任务 {0}（Task Scheduler 拉起，不受 step 超时影响）" -f $taskName)
            return 'PENDING'
        }
        Warn '本机没有 Register-ScheduledTask，退回 Start-Process'
    } catch { Warn "计划任务方式失败（$($_.Exception.Message)），退回 Start-Process" }

    # ② Start-Process（兜底：step 超时会连同它一起被杀，但总比什么都不做强）
    try {
        $child = Start-Process -FilePath $exe -ArgumentList $argStr -WindowStyle Hidden -PassThru -ErrorAction Stop
        if ($child) { Note ("  已起后台进程 PID {0}（注意：step 超时会连同它一起被杀）" -f $child.Id); return 'PENDING' }
    } catch { Warn "Start-Process 也失败：$($_.Exception.Message)" }
    return 'FAILED'
}

# 在指定用户会话里跑一条命令。老代码用 -Wait，一旦凭证/二次登录服务有问题就永久挂住 ——
# 这里改成 -PassThru + Wait-Process -Timeout，超时就杀掉，绝不拖死开机。
# ⚠️ 必须带 -LoadUserProfile：缺了它 = LOGON_NETCREDENTIALS_ONLY，
#    进程起得来、不报错，但**目标用户的 profile 不会被创建/加载**
#    （这正是「用户数据/中文设置整段丢失」的根因，详见 userprofile-lib.ps1）。
function Invoke-AsUser {
    param(
        [System.Management.Automation.PSCredential]$Cred,
        [string]$FilePath,
        [string[]]$Arguments,
        [int]$TimeoutSec = 90,
        [string]$What = 'user-cmd'
    )
    $p = $null
    try { $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -Credential $Cred -LoadUserProfile -WindowStyle Hidden -PassThru -ErrorAction Stop }
    catch { Note ("  {0} 启动失败：{1}" -f $What, $_.Exception.Message); return $null }
    if (-not $p) { return $null }
    try { Wait-Process -Id $p.Id -Timeout $TimeoutSec -ErrorAction Stop }
    catch {
        try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
        Note ("  {0} 超过 {1} 秒未结束，已放弃（不阻塞开机）" -f $What, $TimeoutSec)
    }
    return $p
}

# ---------------------------------------------------------------- 写用户 HKCU 语言键
function Write-ChineseUserHive {
    param([string]$Hive, [string]$Locale, [string]$SecLocale, [string]$Tip)
    $ok = 0; $fail = 0
    $lc = $(if ($PreloadMap.ContainsKey($Locale)) { $PreloadMap[$Locale] } else { '00000804' })
    $sc = $(if ($PreloadMap.ContainsKey($SecLocale)) { $PreloadMap[$SecLocale] } else { '00000409' })

    $cmds = @(
        # 语言列表（REG_MULTI_SZ，用 \0 分隔）
        @('add', "$Hive\Control Panel\International\User Profile", '/v', 'Languages', '/t', 'REG_MULTI_SZ', '/d', "$Locale\0$SecLocale", '/f'),
        # 主语言：微软拼音输入法（TIP）+ 缓存语言名
        @('add', "$Hive\Control Panel\International\User Profile\$Locale", '/v', $Tip, '/t', 'REG_DWORD', '/d', '1', '/f'),
        @('add', "$Hive\Control Panel\International\User Profile\$Locale", '/v', 'CachedLanguageName', '/t', 'REG_SZ', '/d', '@Winlangdb.dll,-1650', '/f'),
        # 键盘布局：1 = 中文（微软拼音），2 = 美式键盘（Win+Space 切换）
        @('add', "$Hive\Keyboard Layout\Preload", '/v', '1', '/t', 'REG_SZ', '/d', $lc, '/f'),
        @('add', "$Hive\Keyboard Layout\Preload", '/v', '2', '/t', 'REG_SZ', '/d', $sc, '/f'),
        # 区域：Locale / sLanguage
        @('add', "$Hive\Control Panel\International", '/v', 'Locale',     '/t', 'REG_SZ', '/d', '00000804', '/f'),
        @('add', "$Hive\Control Panel\International", '/v', 'sLanguage',  '/t', 'REG_SZ', '/d', 'CHS', '/f')
    )
    foreach ($c in $cmds) {
        $a = [object[]]$c
        & reg.exe @a 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $ok++ } else { $fail++ }
    }
    return @{ ok = $ok; fail = $fail }
}

Say '===== 中文环境设置开始 ====='

if (-not $enabled) {
    Say '已关闭（chinese.enabled=false），跳过'
    Set-GhEnv 'CHINESE_STATUS=SKIPPED'
    exit 0
}

# ---------------------------------------------------------------- 子进程模式：只装语言包
# 由计划任务（首选）拉起。装完（无论成败）写 langpack-done.txt，
# 父进程 / 收尾核对步骤靠这个标记判断「后台装完没」。
if ($InstallPackOnly) {
    $res = 'FAILED'
    try {
        if (Get-Command Install-Language -ErrorAction SilentlyContinue) {
            Install-Language -Language $loc -ErrorAction Stop
            $res = 'OK'
        } else {
            throw 'Install-Language 不可用'
        }
    } catch {
        ("[{0}] Install-Language 失败：{1}" -f (Get-Date).ToString('s'), $_.Exception.Message) |
            Out-File -LiteralPath $lpLog -Append -Encoding utf8
        try {
            Add-WindowsCapability -Online -Name ("Language.Basic~~~{0}~0.0.1.0" -f $loc) -ErrorAction Stop | Out-Null
            $res = 'OK-CAPABILITY'
        } catch {
            ("[{0}] Add-WindowsCapability 也失败：{1}" -f (Get-Date).ToString('s'), $_.Exception.Message) |
                Out-File -LiteralPath $lpLog -Append -Encoding utf8
            $res = 'FAILED'
        }
    }
    ("[{0}] 语言包安装结束：{1}" -f (Get-Date).ToString('s'), $res) |
        Out-File -LiteralPath $lpLog -Append -Encoding utf8
    try { $res | Out-File -LiteralPath $lpDone -Encoding ascii -Force } catch { }
    Write-Host ("[chinese] 后台语言包安装结束：$res")
    exit 0
}

# ---------------------------------------------------------------- 收尾核对模式
# 不装包、不写注册表：只把「后台到底装完没」查清楚并透出。step 12b / keepalive 用。
if ($CheckOnly) {
    $hiveState = if ($env:CHINESE_USERHIVE) { [string]$env:CHINESE_USERHIVE } else { 'UNKNOWN' }
    $sysState  = if ($env:CHINESE_SYSTEMLOCALE) { [string]$env:CHINESE_SYSTEMLOCALE } else { 'UNKNOWN' }
    $lpState   = if ($env:CHINESE_LANGPACK) { [string]$env:CHINESE_LANGPACK } else { 'PENDING' }

    # ① 计划任务写的完成标记
    if (Test-Path -LiteralPath $lpDone) {
        $v = (Get-Content -LiteralPath $lpDone -Raw -Encoding ascii).Trim()
        if (-not [string]::IsNullOrWhiteSpace($v)) { $lpState = $v }
    }
    # ② 最强信号：直接问系统装没装（不依赖任何标记文件）
    try {
        $langs = @(Get-InstalledLanguage -ErrorAction SilentlyContinue | ForEach-Object { $_.LanguageId })
        if ($langs -contains $loc) { $lpState = 'PRESENT' }
    } catch { }
    if ($lpState -eq 'FAILED') { $problems.Add('langpack') }

    $overall = Write-ChineseState -LangState $lpState -SysState $sysState -HiveState $hiveState -Phase 'check'
    Say ("===== 中文环境收尾核对：{0}（语言包 {1} / 系统 {2} / 用户 {3}）=====" -f $overall, $lpState, $sysState, $hiveState)
    # 装完了就把计划任务清掉（幂等；一次性 VM 上不清也无害）
    if (@('OK', 'OK-CAPABILITY', 'PRESENT') -contains $lpState) {
        try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue } catch { }
    }
    exit 0
}

# ================================================================
# 主流程：先挂后台安装 → 再做快设置 → 最后才同步等一会儿
# ================================================================

# ---------------------------------------------------------------- 1. 挂后台安装（不等待）
# 本次不管语言包时（-UserHiveOnly / -SkipLanguagePack）**沿用上一步已透出的状态**，
# 别把它抹成 SKIPPED —— 否则第 8b 步一跑，ENV READY 里「语言包」就变成 SKIPPED，
# 看起来像「没装」，而实际是「正在后台装」。
$lpState = 'SKIPPED'
if (-not $wantLp) {
    $prevLp = [string]$env:CHINESE_LANGPACK
    if (-not [string]::IsNullOrWhiteSpace($prevLp)) {
        $lpState = $prevLp
        Say "本次不处理语言包，沿用上一步状态：$lpState"
    }
}
# 同理：本次不动机器级 locale 时（-UserHiveOnly）也沿用上一步状态，别抹成 SKIPPED。
# 放在这里（而不是第 2 段里）是为了让「第一次落盘」就已经是自洽的。
$sysState = 'SKIPPED'
if (-not $wantSys) {
    $prevSys = [string]$env:CHINESE_SYSTEMLOCALE
    if (-not [string]::IsNullOrWhiteSpace($prevSys)) { $sysState = $prevSys }
}
if ($wantLp) {
    $installed = $false
    try {
        $langs = @(Get-InstalledLanguage -ErrorAction SilentlyContinue | ForEach-Object { $_.LanguageId })
        if ($langs -contains $loc) { $installed = $true }
    } catch { }

    if ($installed) {
        $lpState = 'PRESENT'
        Say "语言包已存在：$loc"
    } elseif ($DryRun) {
        $lpState = 'DRYRUN'
        Say ("[DryRun] 将把语言包 {0} 挂到后台安装（计划任务 {1}）" -f $loc, $taskName)
    } else {
        # 先清掉上一轮遗留的完成标记，避免误判
        try { Remove-Item -LiteralPath $lpDone -Force -ErrorAction SilentlyContinue } catch { }
        $lpState = Start-LangPackBackground
        if ($lpState -eq 'PENDING') {
            Say ("语言包 {0} 已交给后台安装（联网下载约 30~43 分钟，不阻塞开机；装完新开一个会话即生效）" -f $loc)
        } else {
            $problems.Add('langpack')
        }
    }
}
Write-ChineseState -LangState $lpState -SysState $sysState -HiveState 'SKIPPED' -Phase 'langpack-spawned' | Out-Null

# ---------------------------------------------------------------- 2. 机器级：系统 locale / 显示语言
if ($wantSys -and -not $DryRun) {
    try {
        Set-WinSystemLocale -SystemLocale 'zh-CN' -ErrorAction Stop
        Say '系统 locale -> zh-CN（注册表已写入；完全生效需重启）'
        $sysState = 'OK'
    } catch { Warn "Set-WinSystemLocale 失败：$_"; $sysState = 'FAILED'; $problems.Add('systemlocale') }

    try { Set-WinUILanguageOverride -Language $loc -ErrorAction Stop; Say "显示语言覆盖 -> $loc" }
    catch { Warn "Set-WinUILanguageOverride 失败：$_" }

    try { Set-WinDefaultInputMethodOverride -InputTip $PinyinTip -ErrorAction Stop; Say '系统默认输入法 -> 微软拼音' }
    catch { Warn "Set-WinDefaultInputMethodOverride 失败：$_" }

    try { Set-Culture -CultureInfo 'zh-CN' -ErrorAction Stop } catch { }
    try { Set-WinHomeLocation -GeoId 45 -ErrorAction Stop; Say '家位置 -> 中国' } catch { }
} elseif ($DryRun) {
    Say '[DryRun] 将设置系统 locale / 显示语言 / 默认输入法'
} else {
    Say "本次不处理机器级 locale（沿用上一步状态 $sysState）"
}
Write-ChineseState -LangState $lpState -SysState $sysState -HiveState 'SKIPPED' -Phase 'systemlocale' | Out-Null

# ---------------------------------------------------------------- 3. 用户级：写用户 a 的 HKCU
# 关键：必须在用户登录前写好，否则登录后没有中文输入法。
$hiveState = 'SKIPPED'
if (-not $SkipUserHive -and -not $DryRun) {
    $userHome = Join-Path 'C:\Users' $RdpUser
    $ntuser   = Join-Path $userHome 'NTUSER.DAT'
    try {
        # ① 确保用户配置文件存在（首次运行 / 预还原未跑时）
        #    走共享库：内部用 Start-Process -Credential **-LoadUserProfile** 真正创建 profile，
        #    并在失败时退化为「手工登记 ProfileList」。旧的内联写法缺 -LoadUserProfile，
        #    进程起得来却不创建 profile → 这一轮语言键全部落空（真机事故根因）。
        if (-not (Test-Path -LiteralPath $ntuser)) {
            Say "用户配置文件不存在，先创建：$userHome"
            if ($script:HasUserProfileLib -and (Get-Command Initialize-RdpUserProfile -ErrorAction SilentlyContinue)) {
                $prof = Initialize-RdpUserProfile -RdpUser $RdpUser -Log { param($m) Note ('  ' + $m) }
                Say ("  用户配置文件：{0}（方式 {1}）" -f $(if ($prof.ok) { '就绪' } else { '未就绪' }), $prof.method)
                if (-not $prof.ok) { Warn ('  预创建用户配置文件未成功：' + $prof.note) }
            } elseif (-not [string]::IsNullOrWhiteSpace($env:RDP_PASSWORD)) {
                $ssPw = New-Object System.Security.SecureString
                foreach ($ch in $env:RDP_PASSWORD.ToCharArray()) { $ssPw.AppendChar($ch) }
                $ssPw.MakeReadOnly()
                $credU = New-Object System.Management.Automation.PSCredential($RdpUser, $ssPw)
                Invoke-AsUser -Cred $credU -FilePath 'cmd.exe' -Arguments @('/c', 'exit') -TimeoutSec 90 -What '预创建用户配置文件' | Out-Null
                Start-Sleep -Seconds 2
            } else {
                Warn '缺少 RDP_PASSWORD，无法预创建用户配置文件'
            }
        }

        # ② 写语言键
        #    两种情况（「连接信息提前打印」之后，用户常常已经登录）：
        #      a) hive 已被 Windows 加载 → 直接写 HKU\<SID>，**不 load / 绝不 unload**
        #         （unload 用户正在用的 hive 会让他的会话直接崩）
        #      b) hive 未加载 → reg load 成 HKU\_LangCfg，写完 unload
        if (Test-Path -LiteralPath $ntuser) {
            $hiveTarget = $null       # 目标 hive 根
            $hiveLoaded = $false      # $true = 用户自己的 hive，用完不能 unload

            if ($script:HasUserHiveLib -and (Get-Command Get-UserHiveRoot -ErrorAction SilentlyContinue)) {
                $hr = Get-UserHiveRoot -RdpUser $RdpUser
                if ($hr.loaded) {
                    $hiveTarget = [string]$hr.root
                    $hiveLoaded = $true
                    Say ("用户已登录，直接写其 hive：{0}" -f $hiveTarget)
                }
            }

            if (-not $hiveLoaded) {
                [gc]::Collect(); [gc]::WaitForPendingFinalizers()
                & reg.exe load 'HKU\_LangCfg' "$ntuser" 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { $hiveTarget = 'HKU\_LangCfg' }
            }

            if ($hiveTarget) {
                $res = Write-ChineseUserHive -Hive $hiveTarget -Locale $loc -SecLocale $sec -Tip $PinyinTip
                # 回读校验
                $chk = (& reg.exe query ("$hiveTarget\Keyboard Layout\Preload") /v 1 2>&1 | Out-String)
                if (-not $hiveLoaded) {
                    [gc]::Collect(); [gc]::WaitForPendingFinalizers()
                    & reg.exe unload 'HKU\_LangCfg' 2>&1 | Out-Null
                }
                if ($res.fail -eq 0 -and $chk -match $PreloadMap[$loc]) {
                    $hiveState = 'OK'
                    Say ("  用户语言设置已写入：{0} 项成功（{1}）" -f $res.ok, $(if ($hiveLoaded) { '写入已加载 hive' } else { '临时 load/unload' }))
                } else {
                    $hiveState = 'PARTIAL'
                    Warn ("  用户语言设置：成功 {0} / 失败 {1}" -f $res.ok, $res.fail)
                    $problems.Add('userhive')
                }
            } else {
                $hiveState = 'LOADFAIL'
                Warn 'NTUSER.DAT 加载失败（用户登录任务会兜底）'
                $problems.Add('userhive')
            }
        } else {
            $hiveState = 'NOPROFILE'
            Warn '用户配置文件未创建成功（用户登录任务会兜底）'
            $problems.Add('userhive')
        }
    } catch {
        Warn "写用户语言设置失败：$_"
        $hiveState = 'FAILED'
        $problems.Add('userhive')
    }
} elseif ($DryRun) {
    Say '[DryRun] 将写入用户语言列表 / 微软拼音 / 键盘布局'
}
Write-ChineseState -LangState $lpState -SysState $sysState -HiveState $hiveState -Phase 'userhive' | Out-Null

# ---------------------------------------------------------------- 4. 增强：在该用户会话里跑 Set-WinUserLanguageList
# 直接写注册表已足够；这一步是「用官方 API 再确认一次」，失败不影响。
# 放宽条件：hive 写失败（LOADFAIL/PARTIAL）但用户**已登录**时也跑 ——
# 此时在他的会话里跑 Set-WinUserLanguageList 正是最有效的补救（用的是他自己的 HKCU）。
$enhState = 'SKIPPED'
$userLoggedIn = $false
if ($script:HasUserHiveLib -and (Get-Command Get-UserHiveRoot -ErrorAction SilentlyContinue)) {
    try { $userLoggedIn = [bool](Get-UserHiveRoot -RdpUser $RdpUser).loaded } catch { $userLoggedIn = $false }
}
$enhanceGate = ($hiveState -eq 'OK') -or (($hiveState -eq 'LOADFAIL' -or $hiveState -eq 'PARTIAL') -and $userLoggedIn)
if (-not $DryRun -and $enhanceGate -and -not [string]::IsNullOrWhiteSpace($env:RDP_PASSWORD)) {
    try {
        $ssPw2 = New-Object System.Security.SecureString
        foreach ($ch in $env:RDP_PASSWORD.ToCharArray()) { $ssPw2.AppendChar($ch) }
        $ssPw2.MakeReadOnly()
        $cred2 = New-Object System.Management.Automation.PSCredential($RdpUser, $ssPw2)
        $inner = "try { Set-WinUserLanguageList -LanguageList '$loc','$sec' -Force -ErrorAction Stop; 'SETOK' } catch { 'SETFAIL:' + \$_.Exception.Message }"
        $tmpOut = Join-Path $env:TEMP 'crdp-lang-out.txt'
        Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue
        Invoke-AsUser -Cred $cred2 -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
                         "$inner | Out-File -LiteralPath '$tmpOut' -Encoding utf8") `
            -TimeoutSec 90 -What 'Set-WinUserLanguageList 增强' | Out-Null
        if (Test-Path -LiteralPath $tmpOut) {
            $r = (Get-Content -LiteralPath $tmpOut -Raw -Encoding UTF8).Trim()
            if ($r -match 'SETOK') { $enhState = 'OK'; Say '  已在该用户会话用 Set-WinUserLanguageList 确认' }
            else { $enhState = 'SKIP'; Note ("  Set-WinUserLanguageList 未确认（不影响注册表设置）：" + $r) }
        } else {
            $enhState = 'NOCONFIRM'
        }
    } catch { $enhState = 'SKIP'; Note "  Set-WinUserLanguageList 增强步骤跳过：$_" }
}
Write-ChineseState -LangState $lpState -SysState $sysState -HiveState $hiveState -Phase 'enhance' -EnhState $enhState | Out-Null

# ---------------------------------------------------------------- 5. 最后：同步等一会儿后台安装
# 挪到最后的理由：同步等待是整条流程里唯一「不可控时长」的一段。放最后，
# 即使被 step 超时杀掉，前面所有设置与状态都已经落盘 —— 不会再出现「全盘皆输」。
if ($lpState -eq 'PENDING' -and $LangPackWaitSec -gt 0) {
    Say ("同步等后台语言包最多 {0} 秒（装不完也没关系，计划任务会继续装）..." -f $LangPackWaitSec)
    $waited = 0
    while ($waited -lt $LangPackWaitSec) {
        if (Test-Path -LiteralPath $lpDone) { break }
        Start-Sleep -Seconds 5
        $waited += 5
    }
    if (Test-Path -LiteralPath $lpDone) {
        $v = (Get-Content -LiteralPath $lpDone -Raw -Encoding ascii).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { $v = 'OK' }
        $lpState = $v
        Say ("语言包安装完成：{0}（同步等了 {1} 秒）" -f $lpState, $waited)
    } else {
        $lpState = 'TIMEOUT_BACKGROUND'
        Say ("语言包仍在后台安装（已等 {0} 秒）—— 计划任务会继续，装完新开一个会话即生效" -f $waited)
    }
    if ($lpState -eq 'FAILED') { $problems.Add('langpack') }
}

# ---------------------------------------------------------------- 6. 最终状态
$overall = Write-ChineseState -LangState $lpState -SysState $sysState -HiveState $hiveState -Phase 'done' -EnhState $enhState
Say ("===== 中文环境设置完成：{0}（语言包 {1} / 系统 {2} / 用户 {3}）=====" -f $overall, $lpState, $sysState, $hiveState)
exit 0
