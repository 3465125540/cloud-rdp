<#
.SYNOPSIS
  长任务「保命」共享库：把 runner 掉线从「看不见」变成「看得见 + 能自愈」。

.DESCRIPTION
  本 job 要跑 4~6 小时，其中 step 7 / step 8 的 rclone 拉取要 2~3 小时（≈1.8 万个小文件）。
  实测 3 次 job 失败（35813312970 / 35820523536 / 36124079866）**全部死在拉取期间**：
  job 日志在拉取中途戛然而止、通篇零 `##[error]`，46 分钟后 GitHub 才判死 ——
  报「The hosted runner lost communication with the server」。

  官方口径（GitHub 文档 + actions/runner issue tracker）只有三种可能，且从服务端**长得一模一样**：
    ① 进程被终结   ② CPU / 内存饥饿   ③ 网络被掐断
  心跳是 GitHub 唯一看得见的东西；进程被饿死、被杀、被断网，在那头都是「失联」。
  本库针对 ②③ 给出三个动作：

    1. Enable-RdpAvExclusions —— 重 IO 之前把 Defender 排除项加好（默认关实时扫描）。
       否则 Defender 会逐字节扫描 1.8 万个刚落地的小文件，把 4 vCPU 的 runner 饿死
       —— 心跳发不出去，从 GitHub 那侧看就是「失联」。这是官方点名的头号成因。

    2. Get-RdpRcloneNetArgs —— 拉取方向改用**有限**超时 + 更多低层重试。
       历史遗留的 `--timeout 0 --contimeout 0`（当年为 139 上传大文件加的）用在下载上，
       会让一条僵死连接吊到天亮：rclone 不报错、step 不结束，最后撞 6 小时硬上限被判 cancelled。
       上传方向保留无限超时（139 WebDAV 大文件确有其事），只加 tpslimit 兜底。

    3. Start-RdpConnWatchdog / Stop-RdpConnWatchdog —— 后台看门狗（独立子进程）：
       每分钟往 job 日志打一行 `gh=ok|fail + 空闲内存 + C:/D: 剩余`，连续 N 次不通就告警 + 轻量自愈
       （清 DNS 缓存 → 重连 Tailscale）。下次再掉线，日志里直接能看出「是网络断了，还是内存被吃光」。

.NOTES
  纯函数库：不 exit、不抛致命错，可被任意脚本 `. .\scripts\watchdog-lib.ps1` 引入。
  导出函数：
    Test-RdpGithubReachable   DNS + TCP443 双判，返回结构化结果（不依赖 ICMP，Azure 屏蔽 ping）
    Get-RdpHostVitals         空闲内存 / 内存占用率 / C: D: 剩余 / Top3 内存进程（诊断用）
    Enable-RdpAvExclusions    Defender 排除项（+ 可选关实时扫描/脚本扫描/下载扫描），fail-soft
    Get-RdpRcloneNetArgs      pull / push 两套 rclone 网络参数
    Invoke-RdpNetSelfHeal     轻量网络自愈（分级，绝不碰网卡本身）
    Repair-RdpProcessEnvDupes 去掉 Path/PATH/path 这类大小写重复键（Start-Process 的 5.1 老坑）
    Start-RdpConnWatchdog     拉起子进程看门狗，返回句柄
    Stop-RdpConnWatchdog      停看门狗并回读它最后一次状态

  两个开关（本地联调 / 单测用，生产不用）：
    CLOUDRDP_AV_SKIP=1        跳过 Defender 调整（别动本机杀软配置）
    CLOUDRDP_WATCHDOG_SKIP=1  跳过看门狗子进程
    CLOUDRDP_AV_KEEP_REALTIME=1  只加排除项、不关实时扫描（生产可用）
#>

Set-StrictMode -Off

# ------------------------------------------------------------------ 日志
function Write-WdgMsg  { param([string]$Tag = 'watchdog', [string]$M = '')  Write-Host   ("[{0}] {1}" -f $Tag, $M) }
function Write-WdgWarn { param([string]$Tag = 'watchdog', [string]$M = '')  Write-Warning ("[{0}] {1}" -f $Tag, $M) }

# ------------------------------------------------------------------ 连通性探测
function Test-RdpGithubReachable {
    <#
      GitHub 控制面可达性。**不用 ping**：Azure 屏蔽所有入站 ICMP，ping 通不通说明不了任何事。
      改成 DNS 解析 + TCP:443 握手两步，5 秒封顶（看门狗每分钟跑一次，不能自己把 CPU 占住）。
      返回：@{ ok; dns; tcp; ms; note }
    #>
    param([int]$TimeoutMs = 5000, [string]$HostName = 'api.github.com')

    $dns = $false
    $tcp = $false
    $note = ''
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $ips = [System.Net.Dns]::GetHostAddresses($HostName)
        $dns = (@($ips).Count -gt 0)
    } catch { $dns = $false }

    if ($dns) {
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $iar = $client.BeginConnect($HostName, 443, $null, $null)
            $signalled = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
            if ($signalled) {
                $client.EndConnect($iar)
                $tcp = $true
            }
            $client.Close()
        } catch { $tcp = $false }
    }
    $sw.Stop()

    if ($dns -and $tcp)      { $note = ('dns=ok tcp=ok {0}ms' -f $sw.ElapsedMilliseconds) }
    elseif (-not $dns)       { $note = 'DNS 解析失败（解析器/网络被改）' }
    else                     { $note = ('DNS ok 但 TCP:443 连不上（{0}ms 超时）' -f $TimeoutMs) }

    return [pscustomobject]@{ ok = ($dns -and $tcp); dns = $dns; tcp = $tcp; ms = [int]$sw.ElapsedMilliseconds; note = $note }
}

# ------------------------------------------------------------------ 主机体征
function Get-RdpHostVitals {
    <#
      一分钟一次的主机体征快照：空闲内存 / 内存占用率 / C: D: 剩余 / Top3 内存进程。
      目的：把「runner 失联」的两种成因（CPU 饥饿 vs 网络断开）在日志里彻底分开。
      任何一项取不到就留 -1，绝不抛。
    #>
    $v = [pscustomobject]@{ freeMemMB = -1; memUsedPct = -1; cFreeGB = -1; dFreeGB = -1; top = '' }
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $v.freeMemMB = [int]($os.FreePhysicalMemory / 1024)
        $totMB = [int]($os.TotalVisibleMemorySize / 1024)
        if ($totMB -gt 0) { $v.memUsedPct = [int](100 * ($totMB - $v.freeMemMB) / $totMB) }
    } catch { }

    foreach ($d in @('C', 'D')) {
        try {
            $drv = Get-PSDrive -Name $d -ErrorAction Stop
            $gb = [math]::Round(($drv.Free / 1GB), 1)
            if ($d -eq 'C') { $v.cFreeGB = $gb } else { $v.dFreeGB = $gb }
        } catch { }
    }

    try {
        $top3 = @(Get-Process -ErrorAction SilentlyContinue |
                    Sort-Object -Property WorkingSet64 -Descending |
                    Select-Object -First 3)
        $v.top = (@($top3 | ForEach-Object { '{0}:{1}M' -f $_.ProcessName, [int]($_.WorkingSet64 / 1MB) }) -join ' ')
    } catch { }

    return $v
}

# ------------------------------------------------------------------ Defender 排除
function Enable-RdpAvExclusions {
    <#
      重 IO 之前把 Defender 排除项加好 —— 这是「runner 被 CPU 饿死」的头号解药。

      为什么默认还要关实时扫描：这台机器是一次性的 RDP 桌面（活 4~6 小时就销毁），
      而 step 7/8 要落地 ≈1.8 万个小文件。Defender 的实时扫描会逐字节过一遍，
      在 4 vCPU 的 hosted runner 上足以让心跳发不出去。关掉它省的是 CPU，不是安全 ——
      快照里本来就带着用户自己的 Defender 排除项，restore 阶段会再加回来。
      想保留实时扫描：设环境变量 CLOUDRDP_AV_KEEP_REALTIME=1。

      返回：@{ ok; added; rtState; note }   rtState ∈ off | keep | fail | dryrun | n/a
      -DryRun 只打印「将要排除哪些路径」，不真的改 Defender（本地联调 / 单测用）。
    #>
    param(
        [string[]]$Paths = @(),
        [string[]]$Processes = @(),
        [switch]$NoDisableRealtime,
        [switch]$DryRun,
        [string]$Tag = 'av'
    )

    $added = 0
    $rtState = 'n/a'
    $note = ''

    # 本地联调 / 单测开关：不想让测试去动本机 Defender
    if ($env:CLOUDRDP_AV_SKIP -eq '1') {
        Write-WdgMsg -Tag $Tag -M 'CLOUDRDP_AV_SKIP=1 —— 跳过 Defender 排除项设置'
        return [pscustomobject]@{ ok = $true; added = 0; rtState = 'skip'; note = 'CLOUDRDP_AV_SKIP=1' }
    }

    if (-not (Get-Command Add-MpPreference -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ ok = $false; added = 0; rtState = 'n/a'; note = 'Add-MpPreference 不可用（非 Windows Defender 或已被接管）' }
    }

    # ---- 排除路径：本项目真正会疯狂读写的几处 ----
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($env:CLOUDRDP_SYS_DIR, $env:CLOUDRDP_DATA_DIR, $env:CLOUDRDP_PORTABLE_DIR)) {
        if (-not [string]::IsNullOrWhiteSpace($p)) { $list.Add($p) }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:RDP_USERNAME)) { $list.Add(('C:\Users\{0}' -f $env:RDP_USERNAME)) }
    foreach ($p in @(
        ('{0}\cloudrdp-sys' -f $env:SystemDrive), 'D:\cloudrdp-sys',
        ('{0}\a' -f $env:SystemDrive), 'D:\a',
        ('{0}\Temp' -f $env:SystemRoot), $env:TEMP
    )) {
        if (-not [string]::IsNullOrWhiteSpace($p)) { $list.Add($p) }
    }
    foreach ($p in $Paths) { if (-not [string]::IsNullOrWhiteSpace($p)) { $list.Add($p) } }

    $uniq = @($list | Select-Object -Unique)

    if ($DryRun) {
        Write-WdgMsg -Tag $Tag -M ('（dry-run）将排除 {0} 条路径：{1}' -f $uniq.Count, ($uniq -join ' ; '))
        return [pscustomobject]@{ ok = $true; added = $uniq.Count; rtState = 'dryrun'; note = '' }
    }

    foreach ($p in $uniq) {
        try { Add-MpPreference -ExclusionPath $p -ErrorAction Stop; $added++ } catch { }
    }

    # ---- 排除进程：真正在搬文件的那几个 ----
    foreach ($pr in @(@('rclone.exe', 'alist.exe', 'pwsh.exe', '7z.exe', 'robocopy.exe') + $Processes | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($pr)) { continue }
        try { Add-MpPreference -ExclusionProcess $pr -ErrorAction SilentlyContinue } catch { }
    }

    # ---- 关掉三类最耗 CPU 的扫描（各自 try，互不影响）----
    $wantOff = (-not $NoDisableRealtime) -and ($env:CLOUDRDP_AV_KEEP_REALTIME -ne '1')
    if (-not $wantOff) {
        $rtState = 'keep'
    } else {
        $off = $false
        try { Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop; $off = $true } catch { }
        try { Set-MpPreference -DisableScriptScanning     $true -ErrorAction SilentlyContinue } catch { }
        try { Set-MpPreference -DisableIOAVProtection     $true -ErrorAction SilentlyContinue } catch { }
        if ($off) { $rtState = 'off' } else { $rtState = 'fail'; $note = 'DisableRealtimeMonitoring 被拒（可能被篡改防护接管），仅靠排除项兜底' }
    }

    Write-WdgMsg -Tag $Tag -M ('Defender：排除路径 {0} 条 / 进程已加；实时扫描={1}{2}' -f $added, $rtState, $(if ($note) { ' —— ' + $note } else { '' }))
    return [pscustomobject]@{ ok = $true; added = $added; rtState = $rtState; note = $note }
}

# ------------------------------------------------------------------ rclone 网络参数
function Get-RdpRcloneNetArgs {
    <#
      拉取 / 推送两套网络参数。**方向不同，超时策略必须不同**：

      pull（下载）：--timeout 5m --contimeout 60s —— 僵死连接必须能被掐掉并重试。
        历史事故：拉取用 `--timeout 0`，一条卡住的连接能吊几小时，rclone 不报错、step 不结束。

      push（上传）：保留 `--timeout 0 --contimeout 0` —— 139 WebDAV 上传大文件超过 5 分钟会被
        服务端断开，这条是当年真机踩出来的，不能动。只加 --tpslimit 限速兜底。

      两个方向都加 --tpslimit：避免几千个小文件把本地 AList / 139 打到限流，
      间接减少 TCP 连接churn（TIME_WAIT 堆积会连累 runner 自己的出站连接）。
    #>
    param(
        [ValidateSet('pull', 'push')][string]$Mode = 'pull',
        [int]$Transfers = 4,
        [int]$Checkers = 8,
        [int]$TpsLimit = 20,
        [int]$Retries = 5,
        [int]$LowLevelRetries = 10
    )

    $common = @(
        '--transfers', "$Transfers",
        '--checkers',  "$Checkers",
        '--retries',   "$Retries",
        '--low-level-retries', "$LowLevelRetries",
        '--tpslimit',  "$TpsLimit",
        '--stats', '60s',
        '--stats-one-line', '-v'
    )

    if ($Mode -eq 'pull') {
        return @('--timeout', '5m', '--contimeout', '60s') + $common
    }
    return @('--timeout', '0', '--contimeout', '0') + $common
}

# ------------------------------------------------------------------ 轻量网络自愈
function Invoke-RdpNetSelfHeal {
    <#
      分级自愈，**绝不碰网卡本身**（重启网卡会掐断 RDP 会话，比失联更糟）：
        L1：清 DNS 缓存
        L2：+ 重连 Tailscale（VPN 是这台机器最可能「把整机 DNS/路由搞没」的组件）
        L3：+ 清 ARP 缓存（只在显式要求时做）
      返回做过的事（字符串），失败也照样返回，绝不抛。
    #>
    param([int]$Level = 2, [string]$Tag = 'watchdog')

    $done = New-Object System.Collections.Generic.List[string]

    if ($Level -ge 1) {
        try { Clear-DnsClientCache -ErrorAction Stop; $done.Add('清DNS缓存') } catch { }
    }

    if ($Level -ge 2) {
        try {
            $svc = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running') {
                Restart-Service -Name 'Tailscale' -Force -ErrorAction Stop
                $done.Add('重连Tailscale')
            }
        } catch { }
    }

    if ($Level -ge 3) {
        try { & netsh.exe interface ip delete arpcache 2>&1 | Out-Null; $done.Add('清ARP') } catch { }
    }

    $txt = if ($done.Count -gt 0) { ($done -join ' + ') } else { '无可执行的自愈动作' }
    Write-WdgWarn -Tag $Tag -M ('自愈 L{0}：{1}' -f $Level, $txt)
    return $txt
}

# ------------------------------------------------------------------ 环境去重（Start-Process 的坑）
function Repair-RdpProcessEnvDupes {
    <#
      PowerShell 5.1 的 Start-Process 会把当前进程环境逐项塞进一个**大小写不敏感**的字典；
      一旦环境里同时存在 `Path` / `PATH` / `path`（凡是从 Git Bash / MSYS 启动的进程链都很常见，
      因为 bash 导出的是大写 PATH，而 Windows 原生是 Path），就会抛：
        「已添加项。字典中的关键字:"Path"所添加的关键字:"PATH"」
      —— 注意 `-UseNewEnvironment` 也救不了（它同样走这条字典）。

      这里把重复的大小写变体去掉、只留第一个。三个变体的值在 Windows 上是同一个变量，
      去掉冗余项不影响任何 PATH 查找（GitHub runner 由服务拉起，本来就没有这个重复）。
      返回被去掉的键名数组。
    #>
    $removed = New-Object System.Collections.Generic.List[string]
    try {
        $seen = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($k in @([Environment]::GetEnvironmentVariables('Process').Keys)) {
            if (-not $seen.Add($k.ToUpperInvariant())) {
                try { [Environment]::SetEnvironmentVariable($k, $null, 'Process'); $removed.Add($k) } catch { }
            }
        }
    } catch { }
    return $removed
}

# ------------------------------------------------------------------ 看门狗
function Start-RdpConnWatchdog {
    <#
      拉起独立子进程看门狗（-NoNewWindow，输出直接进 job 日志，实时可见）。
      子进程每分钟打一行 `[watchdog] ...`；父进程（step 的 pwsh）一消失，子进程自己退出。
      返回句柄：@{ ok; pid; stateFile; note }
    #>
    param([int]$IntervalSec = 60, [int]$FailThreshold = 3, [int]$MaxMinutes = 360, [string]$Tag = 'watchdog')

    # 本地联调 / 单测开关：不真起子进程
    if ($env:CLOUDRDP_WATCHDOG_SKIP -eq '1') {
        Write-WdgMsg -Tag $Tag -M 'CLOUDRDP_WATCHDOG_SKIP=1 —— 跳过看门狗'
        return [pscustomobject]@{ ok = $false; pid = 0; stateFile = ''; note = 'CLOUDRDP_WATCHDOG_SKIP=1' }
    }

    $child = Join-Path $PSScriptRoot 'conn-watchdog.ps1'
    if (-not (Test-Path -LiteralPath $child)) {
        Write-WdgWarn -Tag $Tag -M "找不到 conn-watchdog.ps1（$child），跳过看门狗"
        return [pscustomobject]@{ ok = $false; pid = 0; stateFile = ''; note = '缺少 conn-watchdog.ps1' }
    }

    $stateFile = Join-Path ([System.IO.Path]::GetTempPath()) ('crdp-watchdog-{0}.json' -f ([guid]::NewGuid().ToString('N')))

    $exe = $null
    try { $exe = (Get-Process -Id $PID).Path } catch { }
    if ([string]::IsNullOrWhiteSpace($exe)) { $exe = 'pwsh.exe' }

    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $child),
        '-IntervalSec', "$IntervalSec",
        '-FailThreshold', "$FailThreshold",
        '-MaxMinutes', "$MaxMinutes",
        '-ParentPid', "$PID",
        '-StateFile', ('"{0}"' -f $stateFile)
    )

    $p = $null
    try {
        $p = Start-Process -FilePath $exe -ArgumentList $argList -NoNewWindow -PassThru -ErrorAction Stop
    } catch {
        $firstErr = $_
        $fixed = @(Repair-RdpProcessEnvDupes)
        if ($fixed.Count -gt 0) {
            Write-WdgMsg -Tag $Tag -M ('Start-Process 撞上环境重复键（{0}），去重后重试' -f ($fixed -join ','))
            try { $p = Start-Process -FilePath $exe -ArgumentList $argList -NoNewWindow -PassThru -ErrorAction Stop } catch { $p = $null }
        }
        if (-not $p) {
            Write-WdgWarn -Tag $Tag -M "拉起看门狗失败：$firstErr"
            return [pscustomobject]@{ ok = $false; pid = 0; stateFile = ''; note = "$firstErr" }
        }
    }

    Write-WdgMsg -Tag $Tag -M ('看门狗已启动 pid={0} 间隔 {1}s 阈值 {2} 次' -f $p.Id, $IntervalSec, $FailThreshold)
    return [pscustomobject]@{ ok = $true; pid = $p.Id; stateFile = $stateFile; note = '' }
}

function Stop-RdpConnWatchdog {
    <#
      停看门狗并回读它最后一次落盘的状态（供 step 收尾时打一行总结）。
      返回 $null 或状态对象；句柄为空 / 状态文件缺失都不算错。
    #>
    param($Handle, [string]$Tag = 'watchdog')

    if (-not $Handle) { return $null }

    if ($Handle.pid -gt 0) {
        try { Stop-Process -Id $Handle.pid -Force -ErrorAction SilentlyContinue } catch { }
    }

    $st = $null
    if (-not [string]::IsNullOrWhiteSpace($Handle.stateFile) -and (Test-Path -LiteralPath $Handle.stateFile)) {
        try { $st = Get-Content -LiteralPath $Handle.stateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        try { Remove-Item -LiteralPath $Handle.stateFile -Force -ErrorAction SilentlyContinue } catch { }
    }

    if ($st) {
        Write-WdgMsg -Tag $Tag -M ('看门狗收尾：探测 {0} 次 / 失败 {1} 次 / 自愈 {2} 次' -f $st.ticks, $st.fails, $st.heals)
    }
    return $st
}
