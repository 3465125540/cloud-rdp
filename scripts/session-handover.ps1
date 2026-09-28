<#
  session-handover.ps1 —— 把「当前用户的会话」交给物理控制台（console）。

  ── 为什么需要它（真机事实）────────────────────────────────────────────────
  UU远程（网易 GameViewer）是「屏幕镜像」型远程工具：它连的是机器的
  **控制台会话**（console session，即"物理显示器"上那个会话），
  而不是像 RDP 那样新建一个会话。

  GitHub-hosted Windows 镜像把 runneradmin 放在控制台上（runner 本体就在那跑），
  所以直接开 UU远程，看到的是 **runneradmin 的桌面** —— 不是 a。

  Windows 自带 tscon.exe 能把某个会话「重定向」到控制台：
      tscon <sessionId> /dest:console
  执行后：本会话（a）成为控制台会话；当前 RDP 连接断开，但**会话不注销、程序不退出**。
  此后 UU远程 连上看到的就是 a 的桌面。

  ── 安全性（为什么用 tscon 而不是 logoff）──────────────────────────────────
  * 只「断开 / 重定向」，绝不 logoff —— 会话里的程序继续跑。
  * tscon 顶掉控制台上的 runneradmin，只是把它「断开」（detached），
    runner agent 进程不受影响 —— 这正是它能安全用的原因。
  * 全程 fail-soft：失败只报错，不抛异常。

  ── 用法 ──────────────────────────────────────────────────────────────────
  以 a 通过 mstsc 登录后，双击公共桌面「切到 UU远程」即可。
  已经是控制台会话时会直接提示"无需切换"。
  想切回 RDP：再用 mstsc 以 a 登录即可（Windows 会把 a 的会话接回 RDP）。

  退出码：0=成功或无需切换；非 0=失败（窗口会停留，按回车关闭）。
#>
[CmdletBinding()]
param(
    [string]$User = $env:USERNAME,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

function Write-Note([string]$m) { Write-Host ('[handover] ' + $m) }

$tscon = Join-Path $env:SystemRoot 'System32\tscon.exe'
if (-not (Test-Path -LiteralPath $tscon)) { Write-Note '找不到 tscon.exe，无法切换'; Read-Host '按回车关闭'; exit 1 }

# 当前会话名：Console / RDP-Tcp#N / Services —— 语言无关，最可靠的判断依据。
$sessName = [string]$env:SESSIONNAME
$sid = $null
try { $sid = (Get-Process -Id $PID -ErrorAction Stop).SessionId } catch { }
Write-Note "用户=$User  会话名=$sessName  会话ID=$sid"

if ($sessName -eq 'Console') {
    Write-Note "当前会话（$env:USERNAME）已经是控制台会话 —— 无需切换；UU远程 现在看到的就是 $env:USERNAME"
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

if ($DryRun) { Write-Note "[DryRun] 将要执行：tscon $sid /dest:console"; exit 0 }

Write-Note "把会话 $sid 交给控制台：tscon $sid /dest:console（本 RDP 会断开，会话与程序保留）"
$out = & $tscon $sid /dest:console 2>&1
$rc = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 1 }

if ($rc -eq 0) {
    Write-Note "已切换：RDP 已断开，$User 现在占用控制台。"
    Write-Note "→ 打开/重连 UU远程，看到的就是 $User 的桌面（若仍显示旧画面，断开重连一次即可）。"
    Write-Note "→ 想切回 RDP：再用 mstsc 以 $User 登录即可。"
    exit 0
}

Write-Note "tscon 返回码 $rc ：$out"
Write-Note '→ 多半是权限不足：镜像已关 UAC，正常双击即可；若仍失败请右键「以管理员身份运行」。'
Read-Host '按回车关闭窗口'
exit $rc
