<#
  session-lib.ps1 —— 会话归属诊断 + 「把 a 交给控制台」交接任务/快捷方式安装。

  ── 背景（真机事实，与 README §16 对应）────────────────────────────────────
  * UU远程（网易 GameViewer）是屏幕镜像型工具，连的是机器的**控制台会话**
    （console session，即"物理显示器"上那个会话），而不是像 RDP 那样新建会话。
  * GitHub-hosted Windows 镜像把 runneradmin 放在控制台上（runner 本体就在那跑），
    AutoAdminLogon=runneradmin —— 所以开机后直接开 UU远程，看到的是
    **runneradmin 的桌面**，不是 a（这就是「账户不一致」）。
  * 把控制台交给 a 的唯一安全手段是 Windows 自带的 tscon（只「断开 / 重定向」，
    绝不 logoff，会话里的程序继续跑）。

  ── 2026-09-29 真机实测结论（决定了本库的实现方式）──────────────────────────
  * `tscon <a> /dest:console` 以 a 的普通令牌运行 → **Error 5 / Access is denied**
    （需要 SeTcbPrivilege）。所以「双击快捷方式直接 tscon」这条路走不通。
  * 以 SYSTEM 运行 `tscon <a> /dest:console` → 只把 a 断开，控制台仍是 runneradmin
    （**顶不掉已被占用的控制台**）。
  * 以 SYSTEM 运行 **`tsdiscon <控制台会话ID>` → `tscon <a会话ID> /dest:console`**
    → **成功**：控制台变成 a，runneradmin 变成 Disc。
  * 交接后 GameViewerServer / GameViewerHealthd 会自动在新控制台会话里重生
    （PID 会变），Runner.Listener / Runner.Worker 不受影响 —— **对 UU远程 与 runner 都安全**。

  ── 因此本库采用「三层」设计 ──────────────────────────────────────────────
    ① SYSTEM 计划任务 CloudRDP-UUHandover（按需触发、无触发器）：真正执行
       tsdiscon + tscon（需要 SYSTEM 令牌）。
    ② 公共桌面快捷方式「切到 UU远程」：普通令牌双击，**只负责触发 ①**
       （所以不会撞 Error 5）。
    ③ SYSTEM 计划任务 CloudRDP-UUAuto（开机 + 每 60s 无限重复）：**无感**地把控制台
       交给 a —— 见下。

  ── ③ 为什么能「无感」，又为什么必须加闸（2026-09-29 真机事实）──────────────
  * 触发条件（Get-RdpHandoverPlan -Auto）：控制台不是 a、**且 a 的会话处于 Disc（已断开）**。
    Disc 意味着没有 RDP 客户端挂在 a 上 —— 这正是「用户已登录过 a、现在只想用 UU远程」的状态：
    把 Disc 会话 tscon 到控制台，RDP 本来就没人连着，**不会踢掉任何人**，UU远程 立刻看到 a。
  * **绝不能**在 a 的会话是 Active（rdp-tcp#N，有 mstsc 连着）时自动切：tscon 会把那次 RDP 踢断，
    而用户若重连（Windows 会把控制台会话"接管"回 RDP），任务下一轮又会切回来 —— **来回抢控制台**。
    所以自动闸只认 Disc；Active 的情况留给桌面快捷方式（用户自己决定何时切）。
  * 幂等：控制台已经是 a → 直接退出（不做事、不刷日志）。
  * a 还没有会话（全新开机、用户还没登录过 a）→ 什么都不做（日志里说明）。
  * 关掉自动：设环境变量 `CLOUDRDP_UU_AUTO=0`（安装时跳过）；运行时删掉
    `D:\cloudrdp-sys\_state\uu-auto-off` 同名开关文件亦可停摆（见 session-handover.ps1 -Auto）。

  ── ④ 为什么要「自动给 a 造会话」（2026-10-03 瑀子：「直接登录账号 a」）──────────
  * 事实：Windows **没有**「以编程方式创建会话」的公开 API —— 会话由 smss 在**登录**时创建
    （RDP / 控制台登录都算）。所以 a 必须先被「登录」一次，③ 才有东西可交接。
  * 不能改 `AutoAdminLogon=a`：runner 依赖 runneradmin 的交互式控制台会话
    （`HostedComputeAgent`: `LogonType=InteractiveToken`）—— 改了会打死 runner（README §16 已记）。
  * 能走的路：**RDP 回环** —— 用 mstsc 以 a 连本机 `127.0.0.1`，让系统为 a 建一个会话，
    再断开 mstsc（会话转 Disc），交给 ③ 自动交接。`New-RdpUserSession` 就是干这个的。
  * 关掉：仓库里设 `CLOUDRDP_UU_AUTOLOGIN=0`。

  ── 导出 ──────────────────────────────────────────────────────────────────
    Get-RdpSessionReport                 [-RdpUser a]          会话布局报告（对象）
    Format-RdpSessionReport              [-RdpUser a]          一行文字
    Get-RdpHandoverPlan                  [-RdpUser a] [-Report] [-Auto] 纯函数：该不该切、怎么切
    Invoke-RdpSessionHandover            [-RdpUser a] [-DryRun] [-Auto] 执行交接（**需要 SYSTEM**）
    Install-RdpSessionHandoverTask       [-RdpUser a] [-ScriptPath] [-TaskName] 装 ① + ② + ③
    Install-RdpSessionHandoverShortcut   [-RdpUser a] [-ScriptPath] 只装桌面快捷方式（触发 ①）
    Install-RdpSessionAutoHandoverTask   [-RdpUser a] [-ScriptPath] [-TaskName] 只装 ③（无感自动交接）
    New-RdpUserSession                   [-RdpUser a] [-Password] [-WaitSeconds] [-DryRun] ④ 自动给 a 造会话（RDP 回环）
#>

function Get-RdpSessionReport {
    [CmdletBinding()]
    param([string]$RdpUser = 'a', [string[]]$RawLines)

    $qw = Join-Path $env:SystemRoot 'System32\qwinsta.exe'
    $states = @('Conn', 'Disc', 'Listen', 'Active', 'Idle', '已断开', '活动', '侦听')
    $sessions = @()
    $lines = @()
    if ($RawLines) { $lines = $RawLines }
    elseif (Test-Path -LiteralPath $qw) { try { $lines = @(& $qw 2>$null) } catch { $lines = @() } }
    if ($lines.Count -gt 0) {
        try {
            foreach ($ln in $lines) {
                $raw = [string]$ln
                if ([string]::IsNullOrWhiteSpace($raw)) { continue }
                $isCur = $raw.TrimStart().StartsWith('>')
                $t = ($raw -replace '^[> ]+', '').Trim() -split '\s+'
                if ($t.Count -lt 2) { continue }
                if ($t[0].ToLower() -in @('sessionname', '会话名')) { continue }   # 表头
                # 从右往左锚定 STATE（固定词表）：它左边是 ID，再左边依次是 USERNAME / SESSIONNAME。
                # 这样即使 SESSIONNAME 为空（断开中的会话会把该列挤没）也能正确解析 —— 旧版按
                # 「第 2 个 token 是用户名」解析，遇到 `<空名> a 1 Disc` 会把 a 当成会话名，漏掉用户。
                $si = -1
                for ($i = 0; $i -lt $t.Count; $i++) { if ($t[$i] -in $states) { $si = $i; break } }
                if ($si -lt 1) { continue }
                $id = if ($t[$si - 1] -match '^\d+$') { $t[$si - 1] } else { $null }
                $before = @()
                if ($si -ge 2) { $before = @($t[0..($si - 2)]) }
                $name = ''; $user = ''
                if ($before.Count -ge 2) {
                    $name = $before[0]; $user = $before[1]
                } elseif ($before.Count -eq 1) {
                    # 只有一个字段：像会话名（console/services/rdp-tcp#N/16+ 位十六进制监听名）就是 SESSIONNAME，否则是 USERNAME
                    if ($before[0] -match '^(console|services|rdp-tcp(#\d+)?|[0-9a-fA-F]{16,})$') { $name = $before[0] }
                    else { $user = $before[0] }
                }
                $sessions += [pscustomobject]@{ name = $name; user = $user; id = $id; state = $t[$si]; current = $isCur }
            }
        } catch { }
    }

    $console = $sessions | Where-Object { $_.name.ToLower() -eq 'console' } | Select-Object -First 1
    $a = $sessions | Where-Object { $_.user -eq $RdpUser } | Select-Object -First 1

    $consoleOwner = '?'
    if ($console) { $consoleOwner = if ($console.user) { $console.user } else { '(登录界面)' } }

    [pscustomobject]@{
        ok           = ($consoleOwner -eq $RdpUser)
        rdpUser      = $RdpUser
        consoleOwner = $consoleOwner
        consoleId    = if ($console) { $console.id } else { $null }
        aSessionId   = if ($a) { $a.id } else { $null }
        aState       = if ($a) { $a.state } else { '(无会话)' }
        aSessionName = if ($a) { $a.name } else { '' }
        # 有 RDP 客户端挂在 a 上吗？（qwinsta 里会话名 rdp-tcp#N 才代表「有人正连着」；
        # 断开中的会话这一列是空的，所以 Disc 会话 aSessionName='' → $false）
        aAttachedRdp = [bool]($a -and ($a.name -like 'rdp-tcp*'))
        sessions     = $sessions
    }
}

function Format-RdpSessionReport {
    [CmdletBinding()]
    param([string]$RdpUser = 'a')
    $r = Get-RdpSessionReport -RdpUser $RdpUser
    if ($r.ok) {
        return "控制台会话 = $RdpUser（UU远程 看到的就是 $RdpUser）"
    }
    if (-not $r.aSessionId) {
        return "控制台会话 = $($r.consoleOwner)（不是 $RdpUser）；$RdpUser 还没登录（无会话）—— 先用 mstsc 以 $RdpUser 登录一次，之后自动交接会把它交给控制台"
    }
    $aPart = "$RdpUser 在会话 $($r.aSessionId)（$($r.aState)）"
    if ($r.aAttachedRdp) {
        "控制台会话 = $($r.consoleOwner)（不是 $RdpUser）；$aPart —— $RdpUser 正被 RDP 连着（自动交接刻意不抢），断开 RDP 后 ≤1 分钟自动交接，或双击「切到 UU远程」立刻切"
    } else {
        "控制台会话 = $($r.consoleOwner)（不是 $RdpUser）；$aPart —— 自动交接会在 ≤1 分钟内把控制台交给 $RdpUser（也可双击「切到 UU远程」立刻切）"
    }
}

function Get-RdpHandoverPlan {
    [CmdletBinding()]
    param(
        [string]$RdpUser = 'a',
        [object]$Report,
        [switch]$Auto
    )
    if (-not $Report) { $Report = Get-RdpSessionReport -RdpUser $RdpUser }
    $consoleOwner = [string]$Report.consoleOwner
    $consoleId    = $Report.consoleId
    $userSid      = $Report.aSessionId

    if ($consoleOwner -eq $RdpUser) {
        return [pscustomobject]@{
            action = 'none'; rdpUser = $RdpUser; consoleOwner = $consoleOwner
            consoleId = $consoleId; userSessionId = $userSid
            reason = "控制台已经是 $RdpUser，无需切换"
        }
    }
    if (-not $userSid) {
        return [pscustomobject]@{
            action = 'no-user'; rdpUser = $RdpUser; consoleOwner = $consoleOwner
            consoleId = $consoleId; userSessionId = $null
            reason = "$RdpUser 还没有会话 —— 先用 mstsc 以 $RdpUser 登录一次，再触发切换"
        }
    }
    # 自动模式（③）多一道闸：只在 a 的会话「没被 RDP 客户端连着」时才切。
    # 理由：Active（rdp-tcp#N）说明用户正用 mstsc 连着 —— 切了会踢断他，他重连又会把控制台
    # 「接管」回 RDP，下一轮再切 → 来回抢控制台。Disc 才代表「用户已登录过 a、现在只想用 UU远程」。
    if ($Auto -and $Report.aAttachedRdp) {
        return [pscustomobject]@{
            action = 'skip-active'; rdpUser = $RdpUser; consoleOwner = $consoleOwner
            consoleId = $consoleId; userSessionId = $userSid
            reason = "$RdpUser 的会话正被 RDP 连着（$($Report.aSessionName)）—— 自动交接刻意不抢；断开 RDP 后会自动切，或双击「切到 UU远程」立刻切"
        }
    }
    [pscustomobject]@{
        action = 'handover'; rdpUser = $RdpUser; consoleOwner = $consoleOwner
        consoleId = $consoleId; userSessionId = $userSid
        reason = "先断开当前控制台（$consoleOwner / 会话 $consoleId），再把 $RdpUser 的会话 $userSid 接到控制台"
    }
}

function Invoke-RdpSessionHandover {
    [CmdletBinding()]
    param(
        [string]$RdpUser = 'a',
        [switch]$DryRun,
        [switch]$Auto
    )

    $plan = Get-RdpHandoverPlan -RdpUser $RdpUser -Auto:$Auto
    if ($DryRun) {
        return [pscustomobject]@{ ok = $null; action = $plan.action; note = '[DryRun] ' + $plan.reason; plan = $plan; steps = @() }
    }
    if ($plan.action -eq 'none') {
        return [pscustomobject]@{ ok = $true; action = 'none'; note = $plan.reason; plan = $plan; steps = @() }
    }
    if ($plan.action -eq 'no-user') {
        return [pscustomobject]@{ ok = $false; action = 'no-user'; note = $plan.reason; plan = $plan; steps = @() }
    }
    if ($plan.action -eq 'skip-active') {
        # 自动模式主动放弃（不是失败）：ok=$true 让 SYSTEM 任务以 0 退出，日志里已写明原因。
        return [pscustomobject]@{ ok = $true; action = 'skip-active'; note = $plan.reason; plan = $plan; steps = @() }
    }

    $tscon    = Join-Path $env:SystemRoot 'System32\tscon.exe'
    $tsdiscon = Join-Path $env:SystemRoot 'System32\tsdiscon.exe'
    $steps = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $tscon)) {
        return [pscustomobject]@{ ok = $false; action = 'handover'; note = '找不到 tscon.exe'; plan = $plan; steps = $steps }
    }

    $sid = [string]$plan.userSessionId

    # 真机实测（2026-09-29，console=runneradmin / a=session 1）：唯一稳定成功的顺序是
    # 「**先 tsdiscon 断开当前控制台**，再 tscon <a会话ID> /dest:console」。反过来先 tscon
    # 会 rc=0 但控制台纹丝不动（实测两次都失败）。
    if ($plan.consoleId -and (Test-Path -LiteralPath $tsdiscon)) {
        $o1 = & $tsdiscon ([string]$plan.consoleId) 2>&1
        $rc1 = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { -1 }
        $steps.Add("tsdiscon $($plan.consoleId) rc=$rc1 :: " + ([string]($o1 -join ' ')).Trim())
        Start-Sleep -Milliseconds 1200
    }

    # 把 RdpUser 的会话接到控制台
    $o = & $tscon $sid /dest:console 2>&1
    $rc = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { -1 }
    $steps.Add("tscon $sid /dest:console rc=$rc :: " + ([string]($o -join ' ')).Trim())
    Start-Sleep -Milliseconds 1500

    $after = Get-RdpSessionReport -RdpUser $RdpUser
    if ($after.consoleOwner -ne $RdpUser) {
        # 兜底：再试一次 tscon（有时第一次会话迁移是异步的）
        $o2 = & $tscon $sid /dest:console 2>&1
        $rc2 = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { -1 }
        $steps.Add("tscon $sid /dest:console (retry) rc=$rc2 :: " + ([string]($o2 -join ' ')).Trim())
        Start-Sleep -Milliseconds 1500
        $after = Get-RdpSessionReport -RdpUser $RdpUser
    }

    $ok = ($after.consoleOwner -eq $RdpUser)
    [pscustomobject]@{
        ok     = $ok
        action = 'handover'
        note   = if ($ok) { "已切换：控制台 = $($after.consoleOwner)" } else { "切换后控制台仍是 $($after.consoleOwner)" }
        plan   = $plan
        after  = $after
        steps  = $steps
    }
}

# ── 复制脚本到持久目录 —— ⚠️ 源 == 目标时必须跳过 ─────────────────────────────
# 真机 2026-10-05（run #82/#84）：0b2 / connmail 调 Install-RdpSessionHandoverTask 时，
# ① 先把脚本拷进 D:\cloudrdp-sys\scripts，再把**已部署的那个路径**传给 ③；
# ③ 于是 Copy-Item 源=目标 → PS7 报「Cannot overwrite the item … with itself.」→ **③ 永远装不上**。
# 修法：源和目标解析成绝对路径后相等就直接返回（幂等，不报错）。
function Copy-RdpFileIfDifferent {
    [CmdletBinding()]
    param([string]$Src, [string]$Dst)
    try {
        if ([string]::IsNullOrWhiteSpace($Src) -or [string]::IsNullOrWhiteSpace($Dst)) { return $false }
        if (-not (Test-Path -LiteralPath $Src)) { return $false }
        if ([System.IO.Path]::GetFullPath($Src) -ieq [System.IO.Path]::GetFullPath($Dst)) { return $false }
        Copy-Item -LiteralPath $Src -Destination $Dst -Force
        return $true
    } catch { return $false }
}

function Install-RdpSessionHandoverShortcut {
    [CmdletBinding()]
    param([string]$RdpUser = 'a', [string]$ScriptPath)

    $res = @{ ok = $false; path = ''; note = '' }
    try {
        if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
            $base = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { (Get-Location).Path }
            $ScriptPath = Join-Path $base 'scripts\session-handover.ps1'
        }
        if (-not (Test-Path -LiteralPath $ScriptPath)) { $res.note = "找不到 $ScriptPath"; return $res }

        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $desktop = Join-Path $env:PUBLIC 'Desktop'
        if (-not (Test-Path -LiteralPath $desktop)) { $desktop = [Environment]::GetFolderPath('CommonDesktopDirectory') }
        New-Item -ItemType Directory -Force -Path $desktop | Out-Null

        $lnkName = '切到 UU远程.lnk'
        $lnkPath = Join-Path $desktop $lnkName
        # ⚠️ WScript.Shell.CreateShortcut 内部走 ANSI 代码页：在 en-US 运行器（ACP=1252）上，
        #    中文文件名会被吞成 "?" → COM 报 "Unable to save shortcut"（实测 #62/#63/#65/#66 全挂，
        #    快捷方式从来没建出来过）。zh-CN 机器（ACP=936）则正常。
        #    对策：先用纯 ASCII 名把 .lnk 建好，再用 Unicode 的 File.Move 改成中文名 —— 与运行器区域无关。
        $tmpLnk = Join-Path $desktop ('cloudrdp-uu-' + [guid]::NewGuid().ToString('N') + '.lnk')
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut($tmpLnk)
        $lnk.TargetPath       = $ps
        # 双击走 -Apply：普通令牌只触发 SYSTEM 任务（不直接 tscon，避免 Error 5）
        $lnk.Arguments        = '-NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '" -Apply -User "' + $RdpUser + '"'
        $lnk.WorkingDirectory = Split-Path -Parent $ScriptPath
        $lnk.Description      = "把 $RdpUser 的会话交给控制台，让 UU远程 落到 $RdpUser（RDP 会断开，程序保留）"
        $lnk.IconLocation     = "$env:SystemRoot\System32\shell32.dll,137"
        $lnk.Save()

        if (Test-Path -LiteralPath $lnkPath) { Remove-Item -LiteralPath $lnkPath -Force -ErrorAction SilentlyContinue }
        [System.IO.File]::Move($tmpLnk, $lnkPath)

        $res.ok = $true
        $res.path = $lnkPath
    } catch { $res.note = $_.Exception.Message }
    return $res
}

function Install-RdpSessionHandoverTask {
    [CmdletBinding()]
    param(
        [string]$RdpUser = 'a',
        [string]$ScriptPath,
        [string]$TaskName = 'CloudRDP-UUHandover'
    )

    $res = @{ ok = $false; task = $TaskName; script = ''; shortcut = ''; shortcutOk = $false; shortcutNote = ''; note = '' }
    try {
        if ($env:CLOUDRDP_UU_HANDOVER_SKIP -eq '1') { $res.note = 'CLOUDRDP_UU_HANDOVER_SKIP=1，跳过安装'; return $res }

        $base = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { (Get-Location).Path }
        if ([string]::IsNullOrWhiteSpace($ScriptPath)) { $ScriptPath = Join-Path $base 'scripts\session-handover.ps1' }
        if (-not (Test-Path -LiteralPath $ScriptPath)) { $res.note = "找不到 $ScriptPath"; return $res }

        # 脚本落到持久目录（job 结束会清 workspace，任务目标必须留在盘上）
        $sysDir = if ($env:CLOUDRDP_SYS_DIR) { $env:CLOUDRDP_SYS_DIR } elseif (Test-Path 'D:\') { 'D:\cloudrdp-sys' } else { 'C:\cloudrdp-sys' }
        $dstDir = Join-Path $sysDir 'scripts'
        New-Item -ItemType Directory -Force -Path $dstDir | Out-Null

        $srcDir = Split-Path -Parent $ScriptPath
        $dstScript = Join-Path $dstDir 'session-handover.ps1'
        Copy-RdpFileIfDifferent $ScriptPath $dstScript | Out-Null
        $libSrc = Join-Path $srcDir 'session-lib.ps1'
        Copy-RdpFileIfDifferent $libSrc (Join-Path $dstDir 'session-lib.ps1') | Out-Null
        $res.script = $dstScript

        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $argStr = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $dstScript + '" -System -User "' + $RdpUser + '"'

        if (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue) {
            $act = New-ScheduledTaskAction -Execute $ps -Argument $argStr
            $prn = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                       -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
            Register-ScheduledTask -TaskName $TaskName -Action $act -Principal $prn -Settings $set `
                -Description "CloudRDP: 把 $RdpUser 的会话交给控制台，让 UU远程 落到 $RdpUser（按需触发）" -Force -ErrorAction Stop | Out-Null
        } else {
            $tr = '"' + $ps + '" ' + $argStr
            & schtasks /create /tn $TaskName /tr $tr /sc once /st 23:59 /ru SYSTEM /rl HIGHEST /f 2>&1 | Out-Null
        }

        $sc = Install-RdpSessionHandoverShortcut -RdpUser $RdpUser -ScriptPath $dstScript
        $res.shortcut = $sc.path
        $res.shortcutOk = $sc.ok
        $res.shortcutNote = $sc.note

        # ③ 无感自动交接任务（失败不影响 ①②）
        $auto = Install-RdpSessionAutoHandoverTask -RdpUser $RdpUser -ScriptPath $dstScript
        $res.auto = $auto.task
        $res.autoOk = $auto.ok
        $res.autoNote = $auto.note

        $res.ok = $true
        $bits = New-Object System.Collections.Generic.List[string]
        $bits.Add('交接任务已就绪')
        if ($sc.ok) { $bits.Add('桌面快捷方式已就绪') } else { $bits.Add('快捷方式未创建：' + $sc.note) }
        if ($auto.ok) { $bits.Add('无感自动交接已就绪') } else { $bits.Add('自动交接未装：' + $auto.note) }
        $res.note = ($bits -join '；')
    } catch { $res.note = $_.Exception.Message }
    return $res
}

function Install-RdpSessionAutoHandoverTask {
    [CmdletBinding()]
    param(
        [string]$RdpUser = 'a',
        [string]$ScriptPath,
        [string]$TaskName = 'CloudRDP-UUAuto',
        [int]$IntervalMinutes = 1
    )

    $res = @{ ok = $false; task = $TaskName; script = ''; interval = $IntervalMinutes; note = '' }
    try {
        if ($env:CLOUDRDP_UU_AUTO -eq '0') { $res.note = 'CLOUDRDP_UU_AUTO=0，跳过自动交接任务'; return $res }

        $base = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { (Get-Location).Path }
        if ([string]::IsNullOrWhiteSpace($ScriptPath)) { $ScriptPath = Join-Path $base 'scripts\session-handover.ps1' }
        if (-not (Test-Path -LiteralPath $ScriptPath)) { $res.note = "找不到 $ScriptPath"; return $res }

        # 脚本落到持久目录（job 结束会清 workspace，任务目标必须留在盘上）
        $sysDir = if ($env:CLOUDRDP_SYS_DIR) { $env:CLOUDRDP_SYS_DIR } elseif (Test-Path 'D:\') { 'D:\cloudrdp-sys' } else { 'C:\cloudrdp-sys' }
        $dstDir = Join-Path $sysDir 'scripts'
        New-Item -ItemType Directory -Force -Path $dstDir | Out-Null

        $srcDir = Split-Path -Parent $ScriptPath
        $dstScript = Join-Path $dstDir 'session-handover.ps1'
        Copy-RdpFileIfDifferent $ScriptPath $dstScript | Out-Null
        $libSrc = Join-Path $srcDir 'session-lib.ps1'
        Copy-RdpFileIfDifferent $libSrc (Join-Path $dstDir 'session-lib.ps1') | Out-Null
        $res.script = $dstScript

        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $argStr = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $dstScript + '" -Auto -User "' + $RdpUser + '"'
        $desc = "CloudRDP: 无感把 $RdpUser 的会话交给控制台（让 UU远程 落到 $RdpUser）—— 仅在 $RdpUser 的会话未被 RDP 占用时切"

        $tr = '"' + $ps + '" ' + $argStr
        $registered = $false
        if (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue) {
            try {
                $act = New-ScheduledTaskAction -Execute $ps -Argument $argStr
                $prn = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
                $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                           -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
                # -AtStartup 不支持 Repetition（PS 5.1 实测），所以拆成两个触发器：
                #   · 开机触发（覆盖重启；此时 a 多半还没会话 → 空跑，无害）
                #   · Once + 无限重复（RepetitionDuration 留空 ⇒ Duration 为空 ⇒ 永续，每 IntervalMinutes 一次）
                $tBoot = New-ScheduledTaskTrigger -AtStartup
                $tRep  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
                Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger @($tBoot, $tRep) -Principal $prn -Settings $set `
                    -Description $desc -Force -ErrorAction Stop | Out-Null
                $registered = $true
            } catch {
                # cmdlet 路线失败（运行器令牌可能被 UAC 过滤）→ 退回 schtasks（受限上下文更稳）
                $res.note = "Register-ScheduledTask 失败，改走 schtasks：$($_.Exception.Message)"
            }
        }
        if (-not $registered) {
            & schtasks /create /tn $TaskName /tr $tr /sc minute /mo $IntervalMinutes /ru SYSTEM /rl HIGHEST /f 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "schtasks 创建 $TaskName 失败（exit $LASTEXITCODE）" }
        }

        $res.ok = $true
        $res.note = "自动交接任务已就绪（每 ${IntervalMinutes} 分钟一次，仅切未被 RDP 占用的会话）"
    } catch { $res.note = $_.Exception.Message }
    return $res
}

# ── ④ 自动给 a 造会话（RDP 回环）──────────────────────────────────────────────
# 为什么要它：Windows 没有「以编程方式创建会话」的公开 API —— 会话只能由**登录**产生。
# 所以 a 必须先被登录一次，③（自动交接）才有会话可交给控制台。
# 不能改 AutoAdminLogon=a（会打死 runner）—— 所以这里用 **RDP 回环**：
#   cmdkey 存凭据 → 写 .rdp（关认证提示）→ 起 mstsc 连 127.0.0.1 → 等 a 的会话出现 → 断开 mstsc。
# 断开后 a 的会话变 Disc → ③ CloudRDP-UUAuto（≤1 分钟）把它交给控制台 → UU远程 看到 a。
# 全程 fail-soft：任何一步失败都返回 ok=$false，绝不抛（造不出来就退回「手动 mstsc 登录一次」）。
function New-RdpUserSession {
    [CmdletBinding()]
    param(
        [string]$RdpUser = 'a',
        [string]$Password,
        [int]$WaitSeconds = 45,
        [switch]$DryRun
    )
    $steps = New-Object System.Collections.Generic.List[string]
    $out = [ordered]@{ ok = $false; action = ''; sessionId = $null; note = ''; steps = @() }

    # 已经有会话 → 不用造
    $rep = Get-RdpSessionReport -RdpUser $RdpUser
    if ($rep.aSessionId) {
        $out.ok = $true; $out.action = 'exists'; $out.sessionId = $rep.aSessionId
        $out.note = "$RdpUser 已有会话 $($rep.aSessionId)（$($rep.aState)）—— 无需造"
        $out.steps = $steps
        return [pscustomobject]$out
    }
    if ($DryRun) {
        $out.action = 'dryrun'
        $out.note = "[DryRun] 会给 $RdpUser 造一个 RDP 回环会话（127.0.0.1）"
        $out.steps = $steps
        return [pscustomobject]$out
    }
    if ([string]::IsNullOrWhiteSpace($Password)) {
        $out.note = '缺少密码，无法造会话'; $out.steps = $steps; return [pscustomobject]$out
    }
    $mstsc = Join-Path $env:SystemRoot 'System32\mstsc.exe'
    if (-not (Test-Path -LiteralPath $mstsc)) {
        $out.note = '找不到 mstsc.exe'; $out.steps = $steps; return [pscustomobject]$out
    }

    $domUser = if ($RdpUser -match '\\') { $RdpUser } else { "$env:COMPUTERNAME\$RdpUser" }

    # ① 预存凭据（mstsc 免弹密码框）
    try {
        & cmdkey /generic:TERMSRV/127.0.0.1 /user:$domUser /pass:$Password 2>&1 | Out-Null
        $steps.Add("cmdkey TERMSRV/127.0.0.1 -> $domUser (exit=$LASTEXITCODE)")
    } catch { $steps.Add("cmdkey 异常：$($_.Exception.Message)") }

    # ② 写 .rdp（本机回环 + 关认证提示）
    $rdp = Join-Path $env:TEMP 'cloudrdp-loopback.rdp'
    try {
        @(
            'full address:s:127.0.0.1'
            "username:s:$domUser"
            'prompt for credentials:i:0'
            'promptcredentialonce:i:0'
            'authentication level:i:0'
            'enablecredsspsupport:i:1'
            'screen mode id:i:1'
            'desktopwidth:i:1024'
            'desktopheight:i:768'
            'session bpp:i:16'
            'disable wallpaper:i:1'
            'disable full window drag:i:1'
        ) | Set-Content -LiteralPath $rdp -Encoding ascii
        $steps.Add("已写 $rdp")
    } catch {
        $out.note = "写 .rdp 失败：$($_.Exception.Message)"; $out.steps = $steps; return [pscustomobject]$out
    }

    # 诊断：本进程在哪个会话（session 0 = 无交互桌面 → mstsc 起不来 / 连不上）
    try { $steps.Add("本进程会话 ID=$((Get-Process -Id $PID).SessionId) SESSIONNAME=$env:SESSIONNAME") } catch { }

    # ③ 起 mstsc —— 必须在**交互会话**里才有桌面（workflow 步就跑在 runneradmin 的交互会话）
    $proc = $null
    try {
        $proc = Start-Process -FilePath $mstsc -ArgumentList ('"' + $rdp + '"') -PassThru -ErrorAction Stop
        $steps.Add("已起 mstsc pid=$($proc.Id)（.rdp）")
    } catch {
        $out.note = "起 mstsc 失败：$($_.Exception.Message)"; $out.steps = $steps; return [pscustomobject]$out
    }

    # ④ 等 $RdpUser 的会话出现。
    #    若 mstsc 自己退了（说明 .rdp 那一路没连上）→ 换 `mstsc /v:127.0.0.1` 再试一次。
    $sid = $null
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    $retriedCli = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $r2 = Get-RdpSessionReport -RdpUser $RdpUser
        if ($r2.aSessionId) {
            $sid = $r2.aSessionId
            $steps.Add("$RdpUser 会话出现：sid=$sid state=$($r2.aState) name=$($r2.aSessionName)")
            break
        }
        $exited = $false
        try { $exited = [bool]($proc -and $proc.HasExited) } catch { $exited = $true }
        if (-not $retriedCli -and $exited) {
            $ec = ''
            try { $ec = $proc.ExitCode } catch { }
            $steps.Add("mstsc(.rdp) 已退出 exit=$ec 但没建出会话 → 改 /v:127.0.0.1 再试一次")
            try {
                $proc = Start-Process -FilePath $mstsc -ArgumentList '/v:127.0.0.1' -PassThru -ErrorAction Stop
                $steps.Add("已起 mstsc pid=$($proc.Id)（/v:）")
            } catch { $steps.Add("mstsc(/v:) 起不来：$($_.Exception.Message)") }
            $retriedCli = $true
        }
    }

    # 诊断：抄一份当时的会话布局（定位「为什么没建出会话」）
    try {
        $qw = Join-Path $env:SystemRoot 'System32\qwinsta.exe'
        if (Test-Path -LiteralPath $qw) {
            $snap = (& $qw 2>&1 | Out-String).Trim()
            foreach ($l in ($snap -split "`r?`n")) { if ($l.Trim()) { $steps.Add('qwinsta | ' + $l.TrimEnd()) } }
        }
    } catch { }

    # ⑤ 断开 mstsc（会话转 Disc → 交给 ③ 自动交接）
    try {
        Get-Process -Name mstsc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        $steps.Add('已断开 mstsc（会话转 Disc）')
    } catch { }

    if (-not $sid) {
        $out.note = "等 $WaitSeconds 秒仍没看到 $RdpUser 的会话 —— RDP 回环可能被拒（见 steps）"
        $out.steps = $steps
        return [pscustomobject]$out
    }
    $out.ok = $true; $out.action = 'created'; $out.sessionId = $sid
    $out.note = "已给 $RdpUser 造出会话 $sid（mstsc 回环）；已断开 → CloudRDP-UUAuto ≤1 分钟把它交给控制台"
    $out.steps = $steps
    return [pscustomobject]$out
}
