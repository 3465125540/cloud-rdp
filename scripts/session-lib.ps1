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

  ── 因此本库采用「两层」设计 ──────────────────────────────────────────────
    ① SYSTEM 计划任务 CloudRDP-UUHandover（按需触发、无触发器）：真正执行
       tsdiscon + tscon（需要 SYSTEM 令牌）。
    ② 公共桌面快捷方式「切到 UU远程」：普通令牌双击，**只负责触发 ①**
       （所以不会撞 Error 5）。
  本库仍**不自动切换** —— 切换会让那次 RDP 断开，交给用户按需触发（桌面快捷方式），
  这是 瑀子 2026-09-28 选定的方式。

  ── 导出 ──────────────────────────────────────────────────────────────────
    Get-RdpSessionReport                 [-RdpUser a]          会话布局报告（对象）
    Format-RdpSessionReport              [-RdpUser a]          一行文字
    Get-RdpHandoverPlan                  [-RdpUser a] [-Report] 纯函数：该不该切、怎么切
    Invoke-RdpSessionHandover            [-RdpUser a] [-DryRun] 执行交接（**需要 SYSTEM**）
    Install-RdpSessionHandoverTask       [-RdpUser a] [-ScriptPath] [-TaskName] 装 SYSTEM 任务 + 快捷方式
    Install-RdpSessionHandoverShortcut   [-RdpUser a] [-ScriptPath] 只装桌面快捷方式（触发上面的任务）
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
                $sessions += [pscustomobject]@{ name = $name; user = $user; id = $id; current = $isCur }
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
        aState       = if ($a) { $a.name } else { '(无会话)' }
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
    $aPart = if ($r.aSessionId) { "$RdpUser 在会话 $($r.aSessionId)（$($r.aState)）" } else { "$RdpUser 还没登录（无会话）" }
    "控制台会话 = $($r.consoleOwner)（不是 $RdpUser）；$aPart —— 要让 UU远程 看到 $RdpUser，请在 $RdpUser 桌面双击「切到 UU远程」"
}

function Get-RdpHandoverPlan {
    [CmdletBinding()]
    param(
        [string]$RdpUser = 'a',
        [object]$Report
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
        [switch]$DryRun
    )

    $plan = Get-RdpHandoverPlan -RdpUser $RdpUser
    if ($DryRun) {
        return [pscustomobject]@{ ok = $null; action = $plan.action; note = '[DryRun] ' + $plan.reason; plan = $plan; steps = @() }
    }
    if ($plan.action -eq 'none') {
        return [pscustomobject]@{ ok = $true; action = 'none'; note = $plan.reason; plan = $plan; steps = @() }
    }
    if ($plan.action -eq 'no-user') {
        return [pscustomobject]@{ ok = $false; action = 'no-user'; note = $plan.reason; plan = $plan; steps = @() }
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

        $lnkPath = Join-Path $desktop '切到 UU远程.lnk'
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut($lnkPath)
        $lnk.TargetPath       = $ps
        # 双击走 -Apply：普通令牌只触发 SYSTEM 任务（不直接 tscon，避免 Error 5）
        $lnk.Arguments        = '-NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '" -Apply -User "' + $RdpUser + '"'
        $lnk.WorkingDirectory = Split-Path -Parent $ScriptPath
        $lnk.Description      = "把 $RdpUser 的会话交给控制台，让 UU远程 落到 $RdpUser（RDP 会断开，程序保留）"
        $lnk.IconLocation     = "$env:SystemRoot\System32\shell32.dll,137"
        $lnk.Save()

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

    $res = @{ ok = $false; task = $TaskName; script = ''; shortcut = ''; note = '' }
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
        Copy-Item -LiteralPath $ScriptPath -Destination $dstScript -Force
        $libSrc = Join-Path $srcDir 'session-lib.ps1'
        if (Test-Path -LiteralPath $libSrc) { Copy-Item -LiteralPath $libSrc -Destination (Join-Path $dstDir 'session-lib.ps1') -Force }
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
        $res.ok = $true
        $res.note = if ($sc.ok) { '交接任务 + 桌面快捷方式已就绪' } else { '交接任务已就绪；快捷方式未创建：' + $sc.note }
    } catch { $res.note = $_.Exception.Message }
    return $res
}
