<#
  session-handover.ps1 —— 把「a 的会话」交给物理控制台（console），让 UU远程 落到 a。

  ── 为什么需要它（真机事实）────────────────────────────────────────────────
  UU远程（网易 GameViewer）是「屏幕镜像」型远程工具：它连的是机器的
  **控制台会话**（console session，即"物理显示器"上那个会话），
  而不是像 RDP 那样新建一个会话。

  GitHub-hosted Windows 镜像把 runneradmin 放在控制台上（runner 本体就在那跑），
  所以直接开 UU远程，看到的是 **runneradmin 的桌面** —— 不是 a。

  Windows 自带 tscon.exe 能把某个会话「重定向」到控制台：
      tscon <sessionId> /dest:console
  执行后：a 的会话成为控制台会话；当前 RDP 连接断开，但**会话不注销、程序不退出**。
  此后 UU远程 连上看到的就是 a 的桌面。

  ── 为什么需要「两层」（2026-09-29 真机实测）────────────────────────────────
  * 以 a 的普通令牌直接 `tscon /dest:console` → **Error 5 / Access is denied**
    （需要 SeTcbPrivilege）。
  * 以 SYSTEM 直接 `tscon a /dest:console` → 只断开 a，**顶不掉**已被占用的控制台。
  * 以 SYSTEM `tsdiscon <控制台会话ID>` → `tscon <a会话ID> /dest:console` → **成功**。
  所以：
    - **-System**（由 SYSTEM 计划任务 CloudRDP-UUHandover 调用）：真正执行
      tsdiscon + tscon 交接。
    - **-Apply**（用户双击桌面快捷方式调用，普通令牌）：只**触发**那个 SYSTEM 任务，
      再轮询结果；不会自己去 tscon（因此不会撞 Error 5）。

  ── 安全性（为什么用 tscon 而不是 logoff）──────────────────────────────────
  * 只「断开 / 重定向」，绝不 logoff —— 会话里的程序继续跑。
  * 顶掉控制台上的 runneradmin，只是把它「断开」（detached），
    runner agent 进程不受影响 —— 这正是它能安全用的原因。
  * 全程 fail-soft：失败只报错，不抛异常。

  ── 用法 ──────────────────────────────────────────────────────────────────
  * 用户：以 a 通过 mstsc 登录后，双击公共桌面「切到 UU远程」即可（= -Apply）。
  * 任务：session-handover.ps1 -System -User a（由 CloudRDP-UUHandover 调用）。
  * 诊断：-DryRun 只打印计划，不做任何改动。

  退出码：0=成功或无需切换；非 0=失败（窗口会停留，按回车关闭）。
#>
[CmdletBinding()]
param(
    [string]$User = $env:USERNAME,
    [switch]$Apply,
    [switch]$System,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

function Write-Note([string]$m) { Write-Host ('[handover] ' + $m) }

$libPath = Join-Path $PSScriptRoot 'session-lib.ps1'
$haveLib = Test-Path -LiteralPath $libPath
if ($haveLib) { . $libPath }

$taskName = 'CloudRDP-UUHandover'

# ── 模式 1：SYSTEM 任务入口 —— 真正执行交接 ──────────────────────────────────
if ($System) {
    if (-not $haveLib) { Write-Note '缺少 session-lib.ps1，无法执行 SYSTEM 交接'; exit 1 }
    Write-Note "以 SYSTEM 执行交接（目标用户 $User）"
    $r = Invoke-RdpSessionHandover -RdpUser $User
    Write-Note ("action=$($r.action)  ok=$($r.ok)  :: $($r.note)")
    foreach ($s in $r.steps) { Write-Note ('  ' + $s) }
    if ($r.ok) { exit 0 } else { exit 1 }
}

# ── 模式 2：DryRun —— 只打印计划 ─────────────────────────────────────────────
if ($DryRun) {
    if ($haveLib) {
        $p = Get-RdpHandoverPlan -RdpUser $User
        Write-Note ("[DryRun] action=$($p.action) :: $($p.reason)")
    } else {
        Write-Note '[DryRun] 缺少 session-lib.ps1，无法给出计划'
    }
    exit 0
}

# ── 模式 3：用户上下文（默认 / -Apply）—— 触发 SYSTEM 任务 ────────────────────
$sessName = [string]$env:SESSIONNAME
$sid = $null
try { $sid = (Get-Process -Id $PID -ErrorAction Stop).SessionId } catch { }
Write-Note "用户=$User  会话名=$sessName  会话ID=$sid"

if ($haveLib) {
    Write-Note (Format-RdpSessionReport -RdpUser $User)
    $rep = Get-RdpSessionReport -RdpUser $User
    if ($rep.ok) {
        Write-Note "当前控制台已经是 $User —— 无需切换；UU远程 现在看到的就是 $User"
        exit 0
    }
    $plan = Get-RdpHandoverPlan -RdpUser $User -Report $rep
    if ($plan.action -eq 'no-user') {
        Write-Note $plan.reason
        Read-Host '按回车关闭'
        exit 1
    }
}

# 触发 SYSTEM 计划任务（普通令牌下 tscon /dest:console 会 Access denied）
$triggered = $false
$hasTask = $false
if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
    $t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($t) {
        $hasTask = $true
        try { Start-ScheduledTask -TaskName $taskName -ErrorAction Stop; $triggered = $true }
        catch { Write-Note ('启动计划任务失败：' + $_.Exception.Message) }
    }
} else {
    & schtasks /query /tn $taskName >$null 2>&1
    if ($LASTEXITCODE -eq 0) {
        $hasTask = $true
        & schtasks /run /tn $taskName 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $triggered = $true }
    }
}

if ($triggered) {
    Write-Note "已触发 SYSTEM 任务 $taskName，正在把 $User 交给控制台（本 RDP 会断开，会话与程序保留）…"
    if ($haveLib) {
        for ($i = 0; $i -lt 12; $i++) {
            Start-Sleep -Milliseconds 800
            $r2 = Get-RdpSessionReport -RdpUser $User
            if ($r2.consoleOwner -eq $User) {
                Write-Note "已切换：控制台 = $User —— 打开/重连 UU远程 即可看到 $User 的桌面。"
                Write-Note "→ 想切回 RDP：再用 mstsc 以 $User 登录即可。"
                exit 0
            }
        }
    }
    Write-Note "任务已触发，但暂未看到控制台切换；UU远程 若仍显示旧画面，断开重连一次即可。"
    exit 0
}

# ── 兜底：没有 SYSTEM 任务 → 直接尝试 tscon（普通令牌多半 Error 5）────────────
if ($hasTask) {
    Write-Note "SYSTEM 任务 $taskName 存在但触发失败 —— 请右键快捷方式「以管理员身份运行」，或检查任务是否被禁用。"
    Read-Host '按回车关闭'
    exit 1
}

Write-Note "未找到 SYSTEM 任务 $taskName（可能尚未安装）—— 尝试直接 tscon（普通权限多半失败）"
$tscon = Join-Path $env:SystemRoot 'System32\tscon.exe'
if (-not (Test-Path -LiteralPath $tscon)) { Write-Note '找不到 tscon.exe，无法切换'; Read-Host '按回车关闭'; exit 1 }

if ($sessName -eq 'Console') {
    Write-Note "当前会话（$env:USERNAME）已经是控制台会话 —— 无需切换"
    exit 0
}
if ($sessName -eq 'Services' -or "$sid" -eq '0') {
    Write-Note "当前在服务会话（session 0）里运行 —— 请在 $User 的桌面上双击本快捷方式"
    Read-Host '按回车关闭'
    exit 1
}
if (-not $sid) {
    Write-Note '无法确定当前会话 ID，放弃（不影响其它功能）'
    Read-Host '按回车关闭'
    exit 1
}

Write-Note "把会话 $sid 交给控制台：tscon $sid /dest:console（本 RDP 会断开，会话与程序保留）"
$out = & $tscon $sid /dest:console 2>&1
$rc = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 1 }

if ($rc -eq 0) {
    Write-Note "已切换：RDP 已断开，$User 现在占用控制台。"
    Write-Note "→ 打开/重连 UU远程，看到的就是 $User 的桌面（若仍显示旧画面，断开重连一次即可）。"
    exit 0
}

Write-Note "tscon 返回码 $rc ：$out"
Write-Note '→ 多半是权限不足（需要 SeTcbPrivilege）：请用 SYSTEM 任务（CloudRDP-UUHandover）执行交接。'
Read-Host '按回车关闭窗口'
exit $rc
