<#
.SYNOPSIS
  RDP 用户注册表 hive 的定位与「是否已加载」判定 —— 共享函数库。

.DESCRIPTION
  被 restore-snapshot.ps1 与 setup-chinese.ps1 以 dot-source 方式加载，本身不执行动作。

  为什么需要它：
    这两个脚本原先都靠 `reg load <NTUSER.DAT>` 把 RDP 用户的 hive 挂进来改，改完 `reg unload`。
    但**用户已经登录**时，Windows 早已加载了该 hive —— 此时 `reg load` 必然失败
    （错误：另一个程序正在使用此文件 / 已加载），于是个人 HKCU 设置与中文输入法这一轮全部落空。

    既然 hive 已经在 HKU 里，直接写它就对了：既不 load 也不 unload
    （**绝不能 unload 用户正在用的 hive**，那会让他的会话直接崩掉）。

  判定方式：直接查 HKEY_USERS 下有没有该 SID 的子键
    （`[Microsoft.Win32.Registry]::Users.OpenSubKey($sid)`，reg.exe 兜底）。
    比 `quser` / `Win32_LoggedOnUser` 更直接 —— 那两个在「已登录但会话已断开」时有歧义，
    而我们要判断的恰恰是「hive 有没有被加载」这件事本身。

.NOTES
  函数前缀 Get-RdpUser / Test-UserHive，避免与其它库的同名工具函数冲突。
  与 backup-snapshot.ps1 里的 Get-RdpUserSid 保持同款实现（那边是导出侧，本库是还原侧）。
#>

# 该用户的 SID（S-1-5-21-...）；取不到返回 $null
function Get-RdpUserSid {
    param([string]$RdpUser)
    if ([string]::IsNullOrWhiteSpace($RdpUser)) { return $null }
    try { return (Get-LocalUser -Name $RdpUser -ErrorAction Stop).SID.Value } catch { return $null }
}

# 该 SID 的 hive 是否已加载（= 用户已登录，或别人已经 reg load 进来了）
#
# ⚠️ 不能用 Test-Path 'HKU:\<SID>' —— PowerShell 默认**只建了 HKLM: 与 HKCU: 两个注册表驱动器**，
#    HKU: 并不存在（实测 Test-Path 'HKU:' = False），这么写会恒返回 $false，
#    导致「已登录」分支永远不触发。改用下面两种方式。
function Test-UserHiveLoaded {
    param([string]$Sid)
    if ([string]::IsNullOrWhiteSpace($Sid)) { return $false }

    # 方式①：.NET 直查 HKEY_USERS（无重定向问题，最快）
    try {
        $k = [Microsoft.Win32.Registry]::Users.OpenSubKey($Sid)
        if ($k) { $k.Close(); return $true }
        return $false
    } catch { }

    # 方式②：reg.exe 兜底（与项目其它脚本一致的调用方式）
    & reg.exe query ("HKU\" + $Sid) 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# 定位该用户 hive 的注册表根
#   已加载 → @{ sid; loaded = $true; root = 'HKU\<SID>'; regRoot = 'HKEY_USERS\<SID>' }
#            ← 直接写，不 load / 不 unload
#   未加载 → @{ sid; loaded = $false; root = $null; regRoot = $null }
#            ← 调用方自行 reg load NTUSER.DAT
#
# ⚠️ 两个字段别混用：
#   · root    （'HKU\<SID>'）      —— 给**命令行**用：reg.exe add / query / delete
#   · regRoot （'HKEY_USERS\<SID>'）—— 给 **.reg 文件正文**用：reg.exe import **不认 'HKU\' 前缀**
#                                     （实测：HKU\ 前缀 exit=1 键没写进去，HKEY_USERS\ 才 exit=0）
function Get-UserHiveRoot {
    param([string]$RdpUser)

    $sid = Get-RdpUserSid -RdpUser $RdpUser
    if (-not $sid) {
        return [pscustomobject]@{ sid = $null; loaded = $false; root = $null; regRoot = $null }
    }

    if (Test-UserHiveLoaded -Sid $sid) {
        return [pscustomobject]@{
            sid     = $sid
            loaded  = $true
            root    = ("HKU\" + $sid)
            regRoot = ("HKEY_USERS\" + $sid)
        }
    }
    return [pscustomobject]@{ sid = $sid; loaded = $false; root = $null; regRoot = $null }
}

# 把该用户的 hive 变成「可扫描/可写」的状态，返回统一的根
#   已加载（用户已登录）→ 直接用 HKU\<SID>，**不 load 也不 unload**
#   未加载             → reg load HKU\<LoadName> C:\Users\<user>\NTUSER.DAT，用后必须 Dismount
#
# 为什么需要（真机实测的坑）：
#   备份跑在 runneradmin 身份下，`HKCU:` 是 runneradmin 的 hive —— **看不到 RDP 用户的
#   卸载项**，于是「用户级安装」（程序体在 %LOCALAPPDATA%\<厂商>、卸载项在用户 HKCU）
#   整类程序都不会被备份。还原后就只剩桌面图标、点开报「找不到目标」。
#
# .OUTPUTS
#   [pscustomobject]@{ ok; root; regRoot; loaded; mountedByUs; sid; note }
#     root    = 'HKU\<SID>' 或 'HKU\<LoadName>'   —— 给 reg.exe / PowerShell 注册表路径用
#     regRoot = 'HKEY_USERS\<SID>' 或 'HKEY_USERS\<LoadName>' —— 给 .reg 文件正文用
function Mount-RdpUserHive {
    param(
        [string]$RdpUser,
        [string]$LoadName = '__CRDP_USR'
    )

    $sid = Get-RdpUserSid -RdpUser $RdpUser
    $res = [pscustomobject]@{
        ok = $false; root = $null; regRoot = $null
        loaded = $false; mountedByUs = $false; sid = $sid; note = ''
    }
    if (-not $sid) { $res.note = '取不到该用户的 SID'; return $res }

    if (Test-UserHiveLoaded -Sid $sid) {
        $res.ok = $true
        $res.loaded = $true
        $res.root = ('HKU\' + $sid)
        $res.regRoot = ('HKEY_USERS\' + $sid)
        $res.note = 'hive 已加载（用户已登录）—— 直接读，不 load/unload'
        return $res
    }

    $dat = 'C:\Users\' + $RdpUser + '\NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $dat)) { $res.note = ('找不到 ' + $dat); return $res }

    & reg.exe load ('HKU\' + $LoadName) "$dat" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { $res.note = ('reg load 失败（码 ' + $LASTEXITCODE + '）'); return $res }

    $res.ok = $true
    $res.loaded = $false
    $res.mountedByUs = $true
    $res.root = ('HKU\' + $LoadName)
    $res.regRoot = ('HKEY_USERS\' + $LoadName)
    $res.note = ('已 reg load ' + $dat)
    return $res
}

# 卸载「我们自己 load 的」hive
# ⚠️ 用户自己的 hive（mountedByUs=$false）**绝不能 unload** —— 那会让他的会话直接崩掉。
function Dismount-RdpUserHive {
    param(
        $Mount,
        [string]$LoadName = '__CRDP_USR'
    )
    if ($null -eq $Mount) { return }
    if (-not $Mount.mountedByUs) { return }
    try {
        # reg unload 在有未释放句柄时会失败（错误 5）—— 先逼 GC 释放 .NET 侧句柄
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
        & reg.exe unload ('HKU\' + $LoadName) 2>&1 | Out-Null
    } catch { }
}
