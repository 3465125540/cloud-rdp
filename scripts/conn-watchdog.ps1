<#
.SYNOPSIS
  runner 连接看门狗（独立子进程）：每分钟探一次 GitHub，连续 N 次不通就告警 + 轻量自愈。

.DESCRIPTION
  由 watchdog-lib.ps1 的 Start-RdpConnWatchdog 拉起，**只在长任务（step 7/8 的 rclone 拉取）期间跑**。
  为什么必须单独起进程：step 的 pwsh 被 rclone 阻塞着，同一进程里没法一边拉一边探。

  每分钟往 job 日志打一行：
    [watchdog] 14:32:36 gh=ok  空闲内存=9203MB(41%) 磁盘=C:100.7G D:147G top=rclone:412M ...
  连续 N 次 `gh=FAIL` 就：
    L1 清 DNS 缓存 → L2 重连 Tailscale → L3 清 ARP（分级，见 Invoke-RdpNetSelfHeal）
  并在 `##[warning]` 里写明「是网络断了」还是「内存被吃光了」——下次再失联，日志能自己说话。

  父进程（step 的 pwsh）一消失就自行退出，绝不当孤儿进程占着机器。

.NOTES
  输出用 [Console]::Out + Flush，保证实时进 job 日志（Write-Host 在管道场景可能被缓冲）。
#>
[CmdletBinding()]
param(
    [int]$IntervalSec    = 60,
    [int]$FailThreshold  = 3,
    [int]$MaxMinutes     = 360,
    [int]$ParentPid      = 0,
    [string]$StateFile   = ''
)

$ErrorActionPreference = 'Continue'

# ---- 复用同目录共享库（探测 + 体征 + 自愈都在那里，本脚本只负责「节奏」）----
$lib = Join-Path $PSScriptRoot 'watchdog-lib.ps1'
$hasLib = Test-Path -LiteralPath $lib
if ($hasLib) { . $lib }

function Emit([string]$m) {
    $ts = (Get-Date).ToUniversalTime().ToString('HH:mm:ss')
    $line = '[watchdog] {0} {1}' -f $ts, $m
    try { [Console]::Out.WriteLine($line); [Console]::Out.Flush() } catch { Write-Host $line }
}

function Save-State($obj) {
    if ([string]::IsNullOrWhiteSpace($StateFile)) { return }
    try {
        $json = ($obj | ConvertTo-Json -Compress)
        [System.IO.File]::WriteAllText($StateFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

$ticks = 0
$fails = 0
$heals = 0
$lastOk = ''
$deadline = if ($MaxMinutes -gt 0) { (Get-Date).AddMinutes($MaxMinutes) } else { [datetime]::MaxValue }

Emit ('看门狗启动：每 {0}s 探一次，连续 {1} 次不通即自愈；父进程 pid={2}' -f $IntervalSec, $FailThreshold, $ParentPid)
if (-not $hasLib) { Emit '警告：未找到 watchdog-lib.ps1 —— 只打印心跳，不做探测/自愈' }

while ($true) {
    # 父进程没了（step 结束 / job 被杀）→ 立刻收工
    if ($ParentPid -gt 0) {
        $alive = $null
        try { $alive = Get-Process -Id $ParentPid -ErrorAction SilentlyContinue } catch { }
        if (-not $alive) { Emit '父进程已退出，看门狗收工'; break }
    }
    if ((Get-Date) -gt $deadline) { Emit ('到达 MaxMinutes={0}，看门狗收工' -f $MaxMinutes); break }

    $ticks++

    $r = $null
    if (Get-Command Test-RdpGithubReachable -ErrorAction SilentlyContinue) { $r = Test-RdpGithubReachable }
    $v = $null
    if (Get-Command Get-RdpHostVitals -ErrorAction SilentlyContinue) { $v = Get-RdpHostVitals }

    $mem  = if ($v) { '{0}MB({1}%)' -f $v.freeMemMB, $v.memUsedPct } else { '?' }
    $disk = if ($v) { 'C:{0}G D:{1}G' -f $v.cFreeGB, $v.dFreeGB } else { '?' }
    $top  = if ($v) { $v.top } else { '?' }

    if ($r -and $r.ok) {
        $fails = 0
        $lastOk = (Get-Date).ToUniversalTime().ToString('o')
        Emit ('gh=ok 空闲内存={0} 磁盘={1} top={2}' -f $mem, $disk, $top)
    } else {
        $fails++
        $why = if ($r) { $r.note } else { '探测函数不可用' }
        Emit ('gh=FAIL（连续 {0}/{1}）{2} 空闲内存={3} 磁盘={4} top={5}' -f $fails, $FailThreshold, $why, $mem, $disk, $top)

        if ($fails -ge $FailThreshold) {
            $heals++
            $verdict = if ($v -and $v.memUsedPct -ge 92) {
                '内存几乎被吃光 —— 更像「主机被饿死」而不是网络问题'
            } else {
                '内存/磁盘都宽裕 —— 更像「网络被掐断」'
            }
            Write-Warning ('[watchdog] GitHub 连续 {0} 次不可达（第 {1} 次自愈）。判定：{2}' -f $fails, $heals, $verdict)
            if (Get-Command Invoke-RdpNetSelfHeal -ErrorAction SilentlyContinue) {
                $lvl = if ($heals -ge 2) { 3 } else { 2 }
                $null = Invoke-RdpNetSelfHeal -Level $lvl
            }
            $fails = 0   # 自愈后重新计数，别每次都触发
        }
    }

    Save-State ([pscustomobject]@{ ticks = $ticks; fails = $fails; heals = $heals; lastOk = $lastOk; ts = (Get-Date).ToUniversalTime().ToString('o') })
    Start-Sleep -Seconds $IntervalSec
}

Save-State ([pscustomobject]@{ ticks = $ticks; fails = $fails; heals = $heals; lastOk = $lastOk; done = $true; ts = (Get-Date).ToUniversalTime().ToString('o') })
exit 0
