<#
.SYNOPSIS
  开机时（用户登录前）把系统语言配成「简体中文 + 微软拼音输入法」。

.DESCRIPTION
  为什么需要：GitHub runner 的 Windows Server 镜像默认 en-US，
  RDP 用户 NvdAdmin 首次登录是纯英文界面，且没有中文输入法。

  两层设置：
    A. 机器级（HKLM）—— 安装 zh-Hans-CN 语言包 + 系统 locale / 显示语言覆盖。
       注册表立即写入；locale 类设置要重启才完全生效（对一次性 VM 意义有限，
       但用户登录后的大部分 UI 由 HKCU 决定，见 B）。
    B. 用户级（NvdAdmin 的 HKCU）—— 直接写「语言列表 + 微软拼音 + 键盘布局」。
       必须在用户登录前写好，登录后才会带中文输入法。

  用户级为什么直接写注册表，而不是 Set-WinUserLanguageList？
    该 cmdlet 只作用于「当前用户」，而本脚本以 runneradmin 身份运行。
    因此先 reg load NvdAdmin 的 NTUSER.DAT 到 HKU\_LangCfg，再按 Windows
    真实结构写入（结构照抄一台中文 Windows 的
    HKCU\Control Panel\International\User Profile）。
    随后再尝试用 Start-Process -Credential 在该用户会话里跑一次
    Set-WinUserLanguageList 作为增强（失败不影响已写入的注册表）。

  本脚本永不返回非 0（失败只告警，不影响开机）。结果透出：
    CHINESE_STATUS / CHINESE_LANGPACK / CHINESE_SYSTEMLOCALE / CHINESE_USERHIVE
#>
[CmdletBinding()]
param(
    [string]$RdpUser         = $(if ($env:RDP_USERNAME) { $env:RDP_USERNAME } else { 'NvdAdmin' }),
    [string]$PrimaryLocale   = 'zh-Hans-CN',
    [string]$SecondaryLocale = 'en-US',
    [string]$ConfigPath      = '',
    [switch]$SkipLanguagePack,
    [switch]$SkipUserHive,
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
$loc = [string](Get-Cfg $chCfg 'primaryLocale'   $PrimaryLocale)
$sec = [string](Get-Cfg $chCfg 'secondaryLocale' $SecondaryLocale)

# 命令行/环境变量覆盖（workflow_dispatch 输入）
if (-not [string]::IsNullOrWhiteSpace($env:INPUT_CHINESE)) {
    $ov = $env:INPUT_CHINESE.Trim().ToLower()
    if ($ov -eq 'off' -or $ov -eq 'false' -or $ov -eq '0') { $enabled = $false }
    elseif ($ov -eq 'on' -or $ov -eq 'true' -or $ov -eq '1') { $enabled = $true }
}

Say '===== 中文环境设置开始 ====='

if (-not $enabled) {
    Say '已关闭（chinese.enabled=false），跳过'
    Set-GhEnv 'CHINESE_STATUS=SKIPPED'
    exit 0
}

$problems = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------- 1. 安装语言包
$lpState = 'SKIPPED'
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
        Say "[DryRun] 将安装语言包 $loc"
    } else {
        try {
            Say "安装语言包 $loc（联网下载，约 1-3 分钟）..."
            if (Get-Command Install-Language -ErrorAction SilentlyContinue) {
                Install-Language -Language $loc -ErrorAction Stop
                $lpState = 'OK'
            } else {
                throw 'Install-Language 不可用'
            }
        } catch {
            Warn "Install-Language 失败：$_"
            try {
                Add-WindowsCapability -Online -Name "Language.Basic~~~$loc~0.0.1.0" -ErrorAction Stop | Out-Null
                $lpState = 'OK-CAPABILITY'
            } catch {
                Warn "Add-WindowsCapability 也失败：$_"
                $lpState = 'FAILED'
                $problems.Add('langpack')
            }
        }
    }
}

# ---------------------------------------------------------------- 2. 机器级：系统 locale / 显示语言
$sysState = 'SKIPPED'
if (-not $DryRun) {
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
} else {
    Say '[DryRun] 将设置系统 locale / 显示语言 / 默认输入法'
}

# ---------------------------------------------------------------- 3. 用户级：写 NvdAdmin 的 HKCU
# 关键：必须在用户登录前写好，否则登录后没有中文输入法。
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

$hiveState = 'SKIPPED'
if (-not $SkipUserHive -and -not $DryRun) {
    $userHome = Join-Path 'C:\Users' $RdpUser
    $ntuser   = Join-Path $userHome 'NTUSER.DAT'
    try {
        # ① 确保用户配置文件存在（首次运行 / 预还原未跑时）
        if (-not (Test-Path -LiteralPath $ntuser)) {
            Say "用户配置文件不存在，先创建：$userHome"
            if (-not [string]::IsNullOrWhiteSpace($env:RDP_PASSWORD)) {
                $ssPw = New-Object System.Security.SecureString
                foreach ($ch in $env:RDP_PASSWORD.ToCharArray()) { $ssPw.AppendChar($ch) }
                $ssPw.MakeReadOnly()
                $credU = New-Object System.Management.Automation.PSCredential($RdpUser, $ssPw)
                Start-Process -FilePath 'cmd.exe' -ArgumentList '/c exit' -Credential $credU `
                    -Wait -WindowStyle Hidden -ErrorAction Stop
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

# ---------------------------------------------------------------- 4. 增强：在该用户会话里跑 Set-WinUserLanguageList
# 直接写注册表已足够；这一步是「用官方 API 再确认一次」，失败不影响。
# 放宽条件：hive 写失败（LOADFAIL/PARTIAL）但用户**已登录**时也跑 ——
# 此时在他的会话里跑 Set-WinUserLanguageList 正是最有效的补救（用的是他自己的 HKCU）。
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
        Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
                            "$inner | Out-File -LiteralPath '$tmpOut' -Encoding utf8") `
            -Credential $cred2 -Wait -WindowStyle Hidden -ErrorAction Stop
        if (Test-Path -LiteralPath $tmpOut) {
            $r = (Get-Content -LiteralPath $tmpOut -Raw -Encoding UTF8).Trim()
            if ($r -match 'SETOK') { Say '  已在该用户会话用 Set-WinUserLanguageList 确认' }
            else { Note ("  Set-WinUserLanguageList 未确认（不影响注册表设置）：" + $r) }
        }
    } catch { Note "  Set-WinUserLanguageList 增强步骤跳过：$_" }
}

# ---------------------------------------------------------------- 5. 透出状态
$status = if ($problems.Count -eq 0) { 'OK' } elseif ($lpState -eq 'FAILED' -and $hiveState -ne 'OK') { 'FAILED' } else { 'PARTIAL' }
Set-GhEnv "CHINESE_STATUS=$status"
Set-GhEnv "CHINESE_LANGPACK=$lpState"
Set-GhEnv "CHINESE_SYSTEMLOCALE=$sysState"
Set-GhEnv "CHINESE_USERHIVE=$hiveState"
Set-GhEnv "CHINESE_LOCALE=$loc"

Say ("===== 中文环境设置完成：{0}（语言包 {1} / 系统 {2} / 用户 {3}）=====" -f $status, $lpState, $sysState, $hiveState)
exit 0
