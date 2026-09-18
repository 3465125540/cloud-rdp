# ============================================================================
#  快照 / 还原前「临时关闭占用程序」
# ============================================================================
#
#  .SYNOPSIS
#    在抓取或还原文件之前，优雅关闭正在运行的占用程序，保证数据落盘一致。
#
#  .DESCRIPTION
#    为什么需要（真机实测）：
#      · Edge 的 User Data 用 SQLite(WAL) 存 History / Web Data / Cookies。
#        Edge 运行时这些库被持有 → robocopy 复制会返回码 9（8 = 有文件没复制成），
#        且 History 与 History-wal 会在不同瞬间被复制 → 还原后历史记录可能缺失或过期。
#      · .workbuddy-ai 下有 workbuddy.db（实测 -wal 未 checkpoint 达 3.1 MB），同理。
#
#    策略：优雅 → 强杀
#      ① CloseMainWindow()（能正常退出，浏览器会自己保存会话/checkpoint WAL）
#      ② 等 gracefulSec 秒
#      ③ 仍在 → Stop-Process -Force
#
#  .NOTES
#    · 纯函数、fail-soft：任何异常都只记录，绝不抛出、绝不返回非 0。
#    · 只关闭「配置里显式列出」的进程名，不做任何通配扫描。
#    · 调用方决定时机：本项目只在「非 -Quick 的全量快照」和「还原文件之前」调用，
#      避免每 60 分钟的快速快照打断用户正在用的会话。
# ============================================================================

<#
.SYNOPSIS
  读取配置里的 files.quiesce 清单。
.PARAMETER ConfigPath
  snapshot-config.json 路径。
.OUTPUTS
  对象数组，每项 @{ name; gracefulSec; note }。配置缺失/解析失败时返回空数组。
#>
function Get-QuiesceSpecs {
    param([string]$ConfigPath)

    $specs = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($ConfigPath) -or -not (Test-Path -LiteralPath $ConfigPath)) { return @() }
    try {
        $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch { return @() }

    $filesCfg = $null
    try { $filesCfg = $cfg.files } catch { }
    if ($null -eq $filesCfg) { return @() }

    $list = $null
    try { $list = $filesCfg.quiesce } catch { }
    if ($null -eq $list) { return @() }

    foreach ($it in @($list)) {
        if ($null -eq $it) { continue }
        $nm = ''
        $gs = 15
        $nt = ''
        try { $nm = [string]$it.name } catch { }
        try { if ($null -ne $it.gracefulSec) { $gs = [int]$it.gracefulSec } } catch { }
        try { $nt = [string]$it.note } catch { }
        if ([string]::IsNullOrWhiteSpace($nm)) { continue }
        if ($gs -lt 1) { $gs = 1 }
        if ($gs -gt 120) { $gs = 120 }
        $specs.Add([pscustomobject]@{ name = $nm.Trim(); gracefulSec = $gs; note = $nt })
    }
    return $specs.ToArray()
}

<#
.SYNOPSIS
  按进程名（支持 * 通配）取进程对象；取不到返回空数组。
.PARAMETER Name
  进程名，如 msedge、WorkBuddy*。
#>
function Get-QuiesceProcesses {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return @() }
    try {
        return @(Get-Process -Name $Name -ErrorAction SilentlyContinue)
    } catch {
        return @()
    }
}

<#
.SYNOPSIS
  判断某个进程名当前是否有实例在跑。
.PARAMETER Name
  进程名，支持 * 通配。
.OUTPUTS
  [bool]
#>
function Test-AppRunning {
    param([string]$Name)
    return (@(Get-QuiesceProcesses -Name $Name).Count -gt 0)
}

<#
.SYNOPSIS
  关闭一组占用程序（优雅 → 强杀）。
.PARAMETER Specs
  Get-QuiesceSpecs 的返回值。
.PARAMETER Log
  可选的日志回调（scriptblock，接收一个字符串）。
.PARAMETER LogPath
  可选的日志文件；与 Log 可同时使用。
.OUTPUTS
  [pscustomobject]@{ closed; notRunning; failed; elapsedSec; detail }
    closed     = @('msedge(3)')   实际关掉的（名(进程数)）
    notRunning = @('WorkBuddy')   本来就没跑
    failed     = @('xxx')         关不掉的
.NOTES
  永不抛出。
#>
function Stop-AppForSnapshot {
    param(
        [object[]]$Specs = @(),
        [scriptblock]$Log = $null,
        [string]$LogPath = ''
    )

    $closed     = New-Object System.Collections.Generic.List[string]
    $notRunning = New-Object System.Collections.Generic.List[string]
    $failed     = New-Object System.Collections.Generic.List[string]
    $t0 = Get-Date

    function Write-QLine([string]$m) {
        if ($Log) { try { & $Log $m } catch { } }
        if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
            try {
                ("[{0}] {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $m) |
                    Out-File -LiteralPath $LogPath -Append -Encoding utf8
            } catch { }
        }
    }

    foreach ($sp in @($Specs)) {
        if ($null -eq $sp) { continue }
        $nm = ''
        $gs = 15
        try { $nm = [string]$sp.name } catch { }
        try { $gs = [int]$sp.gracefulSec } catch { }
        if ([string]::IsNullOrWhiteSpace($nm)) { continue }

        try {
            $procs = @(Get-QuiesceProcesses -Name $nm)
            if ($procs.Count -eq 0) {
                $notRunning.Add($nm)
                continue
            }

            # ① 优雅关闭：只对「有主窗口」的进程有效
            foreach ($p in $procs) {
                try { [void]$p.CloseMainWindow() } catch { }
            }

            # ② 等待自行退出
            $deadline = (Get-Date).AddSeconds($gs)
            while ((Get-Date) -lt $deadline) {
                if (@(Get-QuiesceProcesses -Name $nm).Count -eq 0) { break }
                Start-Sleep -Milliseconds 500
            }

            # ③ 仍在 → 强杀
            $left = @(Get-QuiesceProcesses -Name $nm)
            if ($left.Count -gt 0) {
                foreach ($p in $left) {
                    try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
                }
                Start-Sleep -Milliseconds 800
            }

            $after = @(Get-QuiesceProcesses -Name $nm)
            if ($after.Count -eq 0) {
                $closed.Add(("{0}({1})" -f $nm, $procs.Count))
                Write-QLine ("[quiesce] 已关闭 {0}（{1} 个进程）" -f $nm, $procs.Count)
            } else {
                $failed.Add($nm)
                Write-QLine ("[quiesce] 关不掉 {0}（仍有 {1} 个进程）" -f $nm, $after.Count)
            }
        } catch {
            $failed.Add($nm)
            Write-QLine ("[quiesce] 处理 {0} 出错：{1}" -f $nm, $_.Exception.Message)
        }
    }

    $elapsed = [int]((Get-Date) - $t0).TotalSeconds
    $detail = 'closed=' + $(if ($closed.Count) { $closed -join ',' } else { '-' }) +
              '; notRunning=' + $(if ($notRunning.Count) { $notRunning -join ',' } else { '-' }) +
              '; failed=' + $(if ($failed.Count) { $failed -join ',' } else { '-' })
    return [pscustomobject]@{
        closed     = $closed.ToArray()
        notRunning = $notRunning.ToArray()
        failed     = $failed.ToArray()
        elapsedSec = $elapsed
        detail     = $detail
    }
}
