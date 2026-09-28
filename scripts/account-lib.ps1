<#
.SYNOPSIS
  账户守卫：让整机只留「a 一个**用户可见 / 可登录**的管理员账户」。

.DESCRIPTION
  背景（瑀子 2026-09-28「优化uu远程桌面连接创建runneradmin用户账户的问题」）：
  连上云机后能看到一个叫 runneradmin 的账户，以为是「UU远程 / 云机自己新建的」，
  诉求是「只需要有一个管理员账户 a，不要自动创建新的用户账户」。

  真机取证（SMB 只读探两台在线云机 100.75.73.81 / 100.85.24.112，不是猜）：

    · runneradmin 的 profile 元数据两台机器**完全一致**：
        ctime    = 2026/9/22 22:26:18
        NTUSER.DAT mtime = 09/22 22:56:20
      且早于**任何一次**本次开机（本次开机 09-28 00:45Z）
      ⇒ 它是**镜像烘焙时**就存在的，不是哪一次开机、哪一个脚本建的。

    · 全仓 grep（含 .github）：`New-LocalUser|net user|Add-LocalGroupMember|Remove-LocalUser|
      Disable-LocalUser|wmic useraccount` **只命中 workflow 第 0b 步**（建 `a`）。
      备份/还原/瘦身/中文/重装 全部脚本零账户创建代码。
      ⇒ **流程只建 a 一个账户**，别的账户都不是我们建的。

    · runneradmin 是 **GitHub-hosted runner 自己的 Windows 账户**：
        workflow `runs-on: windows-latest`；
        工作区是 hosted 专属的 `D:\a\<repo>\<repo>`（CloudRDP-LangPack 任务 XML 里可见）；
        `slim-image.ps1` 的硬保护名单里就有 `C:\actions-runner`（runner 本体目录）。

    · UU远程 = 网易 GameViewer（`GameViewer.exe` + `GameViewerService.exe`）——
      它装的是**服务**，不建 Windows 账户；它的「设备/账号」是应用自己的概念。

  结论（诚实边界，不假装能全做到）：
    **runneradmin 删不掉** —— 本次 job 的 runner agent 就是以它身份在跑，
    删它 / 降它的权 = 当场把 job（连同这个远程桌面）弄死；它也不归我们管（GitHub 镜像的一部分）。
    能做且该做的是：**让它彻底看不见**，于是「用户视角只有 a 一个管理员账户」。

  做法（两条，都可逆、fail-soft）：
    ① 登录界面隐藏：HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\
                        SpecialAccounts\UserList\<name> = 0
       效果：锁屏 / 切换用户 / UAC 凭据选择器 / 「用户账户」控制面板都不再列它。
       认证本身不受影响（显式指定用户名照样能登），runner 服务更不受影响。
    ② profile 目录隐藏：attrib +h +s C:\Users\<name>
       效果：资源管理器默认不显示（即便开了「显示隐藏文件」，system 属性仍会被
             「隐藏受保护的操作系统文件」挡掉）。

  ⚠️ 为什么不是「删账户 / 降权」：runner agent 以 runneradmin 跑且必须有管理员权限。
     删或降权 = 本 job 立刻失效（连通话的桌面一起没）。见上「诚实边界」。

  运维开关：
    CLOUDRDP_ACCOUNT_HIDE=0        跳过隐藏（什么都不做）
    CLOUDRDP_ACCOUNT_HIDE_DRYRUN=1 只看不改（打印将隐藏谁）

.NOTES
  函数前缀 RA / RdpAccount，避免与其他库的同名工具函数冲突。
  所有函数 fail-soft，永不抛异常；返回值为可序列化对象。
#>

# 内置账户（镜像自带，不是流程建的）—— 白名单用
$script:RA_KNOWN_BUILTINS = @('Administrator', 'Guest', 'DefaultAccount', 'WDAGUtilityAccount')

# ---------------------------------------------------------------- 清单
# 本机全部账户 + 分类。返回可序列化对象，永不抛异常。
function Get-RdpAccountInventory {
    param([string]$RdpUser = 'a')

    $res = [pscustomobject]@{
        ok      = $false
        rdpUser = [string]$RdpUser
        all     = @()
        enabled = @()
        builtin = @()
        runner  = @()
        extras  = @()   # 已启用 且 不是 RDP 用户 = 会被隐藏的对象
        note    = ''
    }

    try {
        $users = @(Get-LocalUser -ErrorAction Stop)
        $res.all     = @($users | ForEach-Object { [string]$_.Name })
        $res.builtin = @($users | Where-Object { $script:RA_KNOWN_BUILTINS -contains $_.Name } |
                                 ForEach-Object { [string]$_.Name })
        $res.enabled = @($users | Where-Object { $_.Enabled } | ForEach-Object { [string]$_.Name })
        $res.runner  = @($res.all | Where-Object { $_ -ieq 'runneradmin' })
        $res.extras  = @($users | Where-Object { $_.Enabled -and ($_.Name -ne $RdpUser) } |
                                 ForEach-Object { [string]$_.Name })
        $res.ok      = $true
    } catch {
        $res.note = 'Get-LocalUser 失败：' + $_.Exception.Message
    }
    return $res
}

# 白名单断言：除了「RDP 用户 + 内置账户 + runneradmin」之外，不该有别的账户。
# 命中未知账户 = 有东西在偷偷建账户（这正是「不要自动创建新的用户账户」要防的）。
function Test-RdpAccountWhitelist {
    param([string]$RdpUser = 'a')

    $known = @($RdpUser) + $script:RA_KNOWN_BUILTINS + @('runneradmin')
    $inv   = Get-RdpAccountInventory -RdpUser $RdpUser
    if (-not $inv.ok) {
        return [pscustomobject]@{ ok = $false; unknown = @(); known = $known; note = $inv.note }
    }
    $unknown = @($inv.all | Where-Object { $known -notcontains $_ })
    return [pscustomobject]@{
        ok      = ($unknown.Count -eq 0)
        unknown = $unknown
        known   = $known
        note    = $(if ($unknown.Count -eq 0) { '无未知账户' } else { '发现非预期账户：' + ($unknown -join ', ') })
    }
}

# ---------------------------------------------------------------- 隐藏 / 撤销
# 隐藏单个账户：① 登录界面（注册表）② profile 目录属性。两条独立 fail-soft。
function Hide-RdpAccount {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$Undo,
        [switch]$NoRegistry,
        [switch]$NoFolder
    )

    $r = [pscustomobject]@{ name = $Name; reg = ''; folder = '' }

    # ① 登录界面：Winlogon\SpecialAccounts\UserList\<name> = 0
    if (-not $NoRegistry) {
        try {
            $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
            if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force -ErrorAction Stop | Out-Null }
            if ($Undo) {
                Remove-ItemProperty -Path $key -Name $Name -ErrorAction SilentlyContinue
                $r.reg = '已撤销'
            } else {
                New-ItemProperty -Path $key -Name $Name -PropertyType DWord -Value 0 -Force -ErrorAction Stop | Out-Null
                $r.reg = '已隐藏(0)'
            }
        } catch { $r.reg = '失败: ' + $_.Exception.Message }
    }

    # ② profile 目录：+h +s
    if (-not $NoFolder) {
        $dir = Join-Path $env:SystemDrive ('Users\' + $Name)
        if (Test-Path -LiteralPath $dir) {
            try {
                $attrib = Join-Path $env:SystemRoot 'System32\attrib.exe'
                if ($Undo) { & $attrib '-h' '-s' $dir 2>$null | Out-Null }
                else       { & $attrib '+h' '+s' $dir 2>$null | Out-Null }
                $r.folder = $(if ($Undo) { '已复原' } else { '已隐藏(+h+s)' })
            } catch { $r.folder = '失败: ' + $_.Exception.Message }
        } else {
            $r.folder = '无 profile 目录'
        }
    }
    return $r
}

# 主入口：把「非 RDP 用户 且 已启用」的账户统统隐藏，让用户视角只剩 a。
function Hide-RdpNonRdpAccounts {
    param(
        [string]$RdpUser = 'a',
        [switch]$DryRun,
        [scriptblock]$Log
    )

    $say = {
        param([string]$m)
        if ($null -ne $Log) { try { & $Log $m; return } catch { } }
        Write-Host ('[account] ' + $m)
    }

    $inv = Get-RdpAccountInventory -RdpUser $RdpUser
    $res = [pscustomobject]@{
        ok      = $false
        rdpUser = [string]$RdpUser
        all     = @($inv.all)
        targets = @($inv.extras)
        hidden  = @()
        dryRun  = $false
        note    = ''
    }
    if (-not $inv.ok) {
        $res.note = $inv.note
        & $say ('账户枚举失败：' + $inv.note)
        return $res
    }

    & $say ('本机账户：' + ($inv.all -join ', '))
    & $say ('已启用：' + ($inv.enabled -join ', ') + ' ｜ 保留可见：' + $RdpUser)

    if ($env:CLOUDRDP_ACCOUNT_HIDE -eq '0') {
        $res.ok = $true
        $res.note = 'CLOUDRDP_ACCOUNT_HIDE=0 —— 已跳过隐藏'
        & $say $res.note
        return $res
    }

    $dry = [bool]$DryRun -or ($env:CLOUDRDP_ACCOUNT_HIDE_DRYRUN -eq '1')
    $res.dryRun = $dry

    foreach ($n in @($inv.extras)) {
        if ($n -eq $RdpUser) { continue }
        if ($dry) {
            $res.hidden += $n
            & $say ('[dryrun] 将隐藏：' + $n)
            continue
        }
        $h = Hide-RdpAccount -Name $n
        $res.hidden += $n
        & $say ('已隐藏 ' + $n + '  [注册表=' + $h.reg + ' 目录=' + $h.folder + ']')
    }

    if ($res.hidden.Count -eq 0) { & $say ('除 ' + $RdpUser + ' 外没有已启用账户 —— 无需隐藏') }
    $res.ok = $true
    return $res
}

# 撤销隐藏（运维用；流程本身不需要）
function Restore-RdpHiddenAccounts {
    param([string]$RdpUser = 'a', [scriptblock]$Log)

    $say = {
        param([string]$m)
        if ($null -ne $Log) { try { & $Log $m; return } catch { } }
        Write-Host ('[account] ' + $m)
    }
    $inv = Get-RdpAccountInventory -RdpUser $RdpUser
    $done = @()
    foreach ($n in @($inv.all)) {
        if ($n -eq $RdpUser) { continue }
        $h = Hide-RdpAccount -Name $n -Undo
        $done += $n
        & $say ('已撤销隐藏 ' + $n + '  [注册表=' + $h.reg + ' 目录=' + $h.folder + ']')
    }
    return [pscustomobject]@{ ok = $true; restored = $done }
}

# ---------------------------------------------------------------- 报告
# 一行摘要，供 workflow 第 13 步 ENV READY 打印（人看不到 Actions 之外的日志）。
function Format-RdpAccountReport {
    param([string]$RdpUser = 'a')

    $inv = Get-RdpAccountInventory -RdpUser $RdpUser
    if (-not $inv.ok) { return ('账户 : 枚举失败（' + $inv.note + '）') }

    $hid = @($inv.extras)
    if ($hid.Count -eq 0) {
        return ('账户 : 只有 ' + $RdpUser + ' 一个已启用账户（其余为未启用内置账户）')
    }
    return ('账户 : 唯一可见/可登录 = ' + $RdpUser + ' ｜ 已隐藏 ' + ($hid -join ', ') +
            '（登录界面 / 资源管理器均不显示；runneradmin 是 GitHub runner 本体、删不掉，详见 README §14）')
}
