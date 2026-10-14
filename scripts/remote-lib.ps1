<#
.SYNOPSIS
  139 云盘（AList/WebDAV）远端可达性判定 + rclone 退出码分类的共享库。

.DESCRIPTION
  ── 为什么需要它（一次真实事故）──
  139 的 DNS 抖动了几秒（`lookup personal-kd-njs.yun.139.com: no such host`），
  AList 于是对 WebDAV 的 PROPFIND 回 404，rclone 把 404 归类成「目录不存在」→ 退出码 3。
  旧脚本一见 3/4 就写 RESTORE_STATUS=EMPTY，等于把「网络抖了一下」记成「远端本来就是空的」：
  开机日志照样报成功，实际一个文件都没拉回来；紧接着 sync-up 又把空目录推回 139，假状态被坐实。

  ── 本库的做法 ──
  把判定从「rclone 退出码」升级成「先探根、再逐级探」：
    1. 先列 AList 挂载根（默认 alist:/cloudrdp，即 139 云盘根）—— 能列出来 = 网络 + 鉴权都正常；
    2. 再逐级往下列，缺哪一级就报哪一级；
    3. 只有「根可列 + 父级可列 + 子级确实不在」时才敢判 EMPTY；根都列不出来 → TRANSIENT。
  换句话说：**绝不把「探不动」当成「不存在」**。

  判定结果（四态）：
    OK        远端可列，目标子目录存在
    EMPTY     远端可列，目标子目录确实不存在（首次运行正常）
    TRANSIENT 网络/后端瞬时故障（DNS、超时、5xx、连接重置）—— 应重试，**绝不写远端**
    AUTH      鉴权失败（401/403/Authorization 过期）—— 需要换 token

.NOTES
  纯函数库：不 exit、不抛致命错，可被任意脚本 `. .\scripts\remote-lib.ps1` 引入。
  导出函数：
    Get-RcloneErrorKind        rclone 退出码 → OK/EMPTY/TRANSIENT（纯映射，仅作粗判）
    Get-RemoteRoot             求 139 侧「根」路径（AList 挂载点）
    Get-RemoteLevels           求目标相对根的层级
    Invoke-RcloneList          单次 lsf（带超时，返回结构化结果）
    Get-RemoteProbe            逐级探测 → 四态判定对象
    Resolve-RemoteVerdict      带重试的探测（TRANSIENT 才重试）
    Test-AlistRemoteReachable  带重试的「根是否可列」布尔判定
    Set-RestoreStatus          统一写状态：GITHUB_ENV + _state/restore-status.json + 标记文件
#>

# ------------------------------------------------------------------ 退出码粗判
function Get-RcloneErrorKind {
    <#
      rclone 退出码 → 粗分类。**仅供日志参考，不要拿它判 EMPTY**：
      139 的 DNS 故障会经 AList 404 变成 rclone 码 3，与「真的没有」完全同码。
      要下结论请用 Get-RemoteProbe / Resolve-RemoteVerdict。
    #>
    param([int]$Code)
    if ($Code -eq 0) { return 'OK' }
    if ($Code -eq 3 -or $Code -eq 4) { return 'EMPTY' }
    return 'TRANSIENT'
}

# ------------------------------------------------------------------ 路径推导
function Get-RemoteRoot {
    <#
      139 侧的「根」= AList 存储挂载点（健康时必定可列）。
      优先级：显式 -Root > 环境变量 CLOUDRDP_REMOTE_ROOT > 由 CLOUDRDP_REMOTE_BASE 取前两段 > alist:/cloudrdp
      alist:/cloudrdp/AI文件库 -> alist:/cloudrdp
    #>
    param([string]$Remote = "", [string]$Root = "")
    if (-not [string]::IsNullOrWhiteSpace($Root)) { return $Root.TrimEnd('/') }
    if (-not [string]::IsNullOrWhiteSpace($env:CLOUDRDP_REMOTE_ROOT)) {
        return $env:CLOUDRDP_REMOTE_ROOT.TrimEnd('/')
    }
    $base = [string]$env:CLOUDRDP_REMOTE_BASE
    if (-not [string]::IsNullOrWhiteSpace($base)) {
        $parts = @($base.TrimEnd('/').Split('/') | Where-Object { $_ -ne '' })
        if ($parts.Count -ge 2) { return ($parts[0] + '/' + $parts[1]) }
    }
    if (-not [string]::IsNullOrWhiteSpace($Remote)) {
        $parts = @($Remote.TrimEnd('/').Split('/') | Where-Object { $_ -ne '' })
        if ($parts.Count -ge 2) { return ($parts[0] + '/' + $parts[1]) }
    }
    return 'alist:/cloudrdp'
}

function Get-RemoteLevels {
    <#
      Remote 相对 Root 的层级。
      alist:/cloudrdp/AI文件库/CloudRDP + root=alist:/cloudrdp -> @('AI文件库','CloudRDP')
    #>
    param([string]$Remote, [string]$Root)
    $r = ([string]$Remote).TrimEnd('/')
    $b = ([string]$Root).TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($r) -or [string]::IsNullOrWhiteSpace($b)) { return @() }
    if (-not $r.ToLowerInvariant().StartsWith($b.ToLowerInvariant())) { return @() }
    $tail = $r.Substring($b.Length).Trim('/')
    if ([string]::IsNullOrWhiteSpace($tail)) { return @() }
    return @($tail.Split('/') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

# ------------------------------------------------------------------ 单次列举
function Invoke-RcloneList {
    <#
      单次 `rclone lsf <Path> --max-depth 1`。返回对象：
        Path / Code / Ok / Names / Text
      永不抛致命错（rclone 不存在 → Code=-1、Ok=$false）。
      注意用短超时（默认 25s）：探测必须能失败，不能把开机流程挂死。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$RcloneExe,
        [Parameter(Mandatory=$true)][string]$Path,
        [int]$TimeoutSec = 25
    )
    $out  = @()
    $code = -1
    if ([string]::IsNullOrWhiteSpace($RcloneExe) -or -not (Test-Path -LiteralPath $RcloneExe)) {
        return [pscustomobject]@{
            Path = $Path; Code = -1; Ok = $false; Names = @()
            Text = "未找到 rclone：$RcloneExe"
        }
    }
    try {
        $out = @(& $RcloneExe lsf $Path --max-depth 1 `
                 --timeout "${TimeoutSec}s" --contimeout "${TimeoutSec}s" `
                 --retries 1 --low-level-retries 1 2>&1)
        $code = $LASTEXITCODE
    } catch {
        $code = -1
        $out  = @("$($_.Exception.Message)")
    }
    $names = @()
    $lines = @()
    foreach ($o in $out) {
        if ($o -is [System.Management.Automation.ErrorRecord]) {
            # rclone 的 stderr 被 2>&1 包成 ErrorRecord；直接 ToString() 会带上
            # 「所在位置 … + CategoryInfo …」的调用栈噪声，日志里没法看。只取第一行消息。
            $m = ''
            try { $m = [string]$o.Exception.Message } catch { $m = '' }
            if ([string]::IsNullOrWhiteSpace($m)) { $m = [string]$o }
            $lines += (($m -split "`r?`n")[0]).Trim()
            continue
        }
        $s = ([string]$o).Trim()
        $lines += $s
        $n = $s.TrimEnd('/')
        if (-not [string]::IsNullOrWhiteSpace($n)) { $names += $n }
    }
    return [pscustomobject]@{
        Path  = $Path
        Code  = $code
        Ok    = ($code -eq 0)
        Names = $names
        Text  = (($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' | ').Trim()
    }
}

# ------------------------------------------------------------------ 逐级探测
function Get-RemoteProbe {
    <#
      逐级探测 Remote 是否存在，给出四态判定。返回对象：
        Remote / Root / Levels / RootOk / RootCode / RootNames
        LeafExists / MissingAt / Verdict / Message

      判定顺序（关键：先证明「能看见」，再说「看不见」）：
        ① 列 Root 失败 → 按 rclone 文本判 AUTH 或 TRANSIENT（**不判 EMPTY**）
        ② Root 可列但父级里没有目标子目录 → EMPTY（父目录看得见，里面确实没有）
        ③ 父级里有目标子目录、却列不出它 → AUTH / TRANSIENT
        ④ 全部可列 → OK
    #>
    param(
        [Parameter(Mandatory=$true)][string]$RcloneExe,
        [Parameter(Mandatory=$true)][string]$Remote,
        [string]$Root = "",
        [int]$TimeoutSec = 25
    )
    $root   = Get-RemoteRoot -Remote $Remote -Root $Root
    $levels = @(Get-RemoteLevels -Remote $Remote -Root $root)

    $res = [ordered]@{
        Remote     = $Remote
        Root       = $root
        Levels     = $levels
        RootOk     = $false
        RootCode   = -1
        RootNames  = @()
        LeafNames  = @()
        LeafExists = $false
        MissingAt  = ''
        Verdict    = 'TRANSIENT'
        Message    = ''
    }

    # ---- ① 探根：能列出来 = 网络 + 鉴权都正常 ----
    $probe = Invoke-RcloneList -RcloneExe $RcloneExe -Path $root -TimeoutSec $TimeoutSec
    $res.RootCode  = $probe.Code
    $res.RootNames = $probe.Names
    if (-not $probe.Ok) {
        $v = Get-RemoteTextVerdict $probe.Text
        if ($v) { $res.Verdict = $v } else { $res.Verdict = 'TRANSIENT' }
        $res.Message = "无法列出 139 根目录 $root（rclone 码 $($probe.Code)）：$($probe.Text)"
        return [pscustomobject]$res
    }
    $res.RootOk = $true

    # ---- ②③④ 逐级往下：缺哪级报哪级 ----
    $cur     = $root
    $curList = $probe
    for ($i = 0; $i -lt $levels.Count; $i++) {
        $leaf = $levels[$i]
        $cur  = $cur.TrimEnd('/') + '/' + $leaf

        if (-not ($curList.Names -contains $leaf)) {
            $res.MissingAt = $cur
            $res.LeafNames = $curList.Names
            $res.Verdict   = 'EMPTY'
            $res.Message   = "远端确实不存在：$cur（父目录 $($curList.Path) 可列，里面没有「$leaf」）"
            return [pscustomobject]$res
        }

        $next = Invoke-RcloneList -RcloneExe $RcloneExe -Path $cur -TimeoutSec $TimeoutSec
        if (-not $next.Ok) {
            $v = Get-RemoteTextVerdict $next.Text
            if ($v) { $res.Verdict = $v } else { $res.Verdict = 'TRANSIENT' }
            $res.MissingAt = $cur
            $res.LeafNames = $curList.Names
            $res.Message   = "父目录里明明有「$leaf」，却列不出 $cur（rclone 码 $($next.Code)）：$($next.Text)"
            return [pscustomobject]$res
        }
        $curList = $next
    }

    $res.LeafExists = $true
    $res.LeafNames  = $curList.Names
    $res.Verdict    = 'OK'
    $res.Message    = "远端可列且目标存在：$Remote（$($curList.Path) 下有 $($curList.Names.Count) 项）"
    return [pscustomobject]$res
}

function Get-RemoteTextVerdict {
    <#
      rclone 报错文本 → AUTH / TRANSIENT（判不出来返回空串，由调用方兜底 TRANSIENT）。
      存在的意义：把「token 过期」与「网络抖」区分开，好让日志给出正确处置建议。
    #>
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $t = $Text.ToLowerInvariant()
    if ($t -match '401|403|unauthorized|forbidden|invalid.?token|token.{0,12}expir|authorization') { return 'AUTH' }
    if ($t -match 'no such host|dial tcp|connection refused|connection reset|i/o timeout|context deadline exceeded|tls handshake|unexpected eof|too many requests|429|50[234]') { return 'TRANSIENT' }
    return ''
}

# ------------------------------------------------------------------ 带重试封装
function Resolve-RemoteVerdict {
    <#
      带重试的探测：只有 TRANSIENT 才重试（EMPTY / OK / AUTH 立即返回，别浪费开机时间）。
      返回最后一次的探测对象（含 .Verdict / .Message）。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$RcloneExe,
        [Parameter(Mandatory=$true)][string]$Remote,
        [string]$Root = "",
        [int]$Attempts = 3,
        [int]$DelaySec = 6,
        [int]$TimeoutSec = 25
    )
    $last = $null
    $n = [Math]::Max(1, $Attempts)
    for ($i = 1; $i -le $n; $i++) {
        $last = Get-RemoteProbe -RcloneExe $RcloneExe -Remote $Remote -Root $Root -TimeoutSec $TimeoutSec
        if ($last.Verdict -ne 'TRANSIENT') { return $last }
        if ($i -lt $n) {
            Write-Warning "[remote] 第 $i/$n 次探测为 TRANSIENT：$($last.Message)"
            Write-Warning "[remote] $DelaySec 秒后重试……"
            Start-Sleep -Seconds $DelaySec
        }
    }
    return $last
}

function Test-AlistRemoteReachable {
    <#
      「139 根是否可列」的布尔判定（带重试）。$true = 网络+鉴权都正常。
      用途：sync-up 推数据前的守卫 —— 探不到就绝不 mkdir/copy，避免在 139 上留垃圾。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$RcloneExe,
        [Parameter(Mandatory=$true)][string]$Remote,
        [string]$Root = "",
        [int]$Attempts = 3,
        [int]$DelaySec = 6,
        [int]$TimeoutSec = 25,
        [switch]$Quiet
    )
    $n = [Math]::Max(1, $Attempts)
    for ($i = 1; $i -le $n; $i++) {
        $p = Get-RemoteProbe -RcloneExe $RcloneExe -Remote $Remote -Root $Root -TimeoutSec $TimeoutSec
        if ($p.RootOk) { return $true }
        if (-not $Quiet) { Write-Warning "[remote] 第 $i/$n 次探测不可达（$($p.Verdict)）：$($p.Message)" }
        if ($i -lt $n) { Start-Sleep -Seconds $DelaySec }
    }
    return $false
}

# ------------------------------------------------------------------ 状态读取
function Get-RestoreStatus {
    <#
      读 <SysDir>\_state\restore-status.json（无则 $null）。结构：
        { updated_utc, host, run_id, role, data{status,reason,...}, snapshot{status,reason,...} }
    #>
    param([string]$SysDir = "")
    if ([string]::IsNullOrWhiteSpace($SysDir)) {
        if ($env:CLOUDRDP_SYS_DIR) { $SysDir = $env:CLOUDRDP_SYS_DIR }
        elseif (Test-Path 'D:\') { $SysDir = 'D:\cloudrdp-sys' }
        else { $SysDir = 'C:\cloudrdp-sys' }
    }
    $p = Join-Path $SysDir '_state\restore-status.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Get-RestoreStatusValue {
    <#
      取某作用域的状态串：-Scope snapshot -> 'OK'|'EMPTY'|'TRANSIENT'|'FAILED'|'AUTH'|'PARTIAL'（无记录返回 ''）。
    #>
    param(
        [ValidateSet('data', 'snapshot')][string]$Scope = 'data',
        [string]$SysDir = ""
    )
    $o = Get-RestoreStatus -SysDir $SysDir
    if (-not $o) { return '' }
    $p = $o.PSObject.Properties[$Scope]
    if ($p -and $p.Value) { return [string]$p.Value.status }
    return ''
}

function Get-GhEnvValue {
    <#
      从 GITHUB_ENV 文件里取某个变量的**最后一次**写入值。
      为什么需要：写 GITHUB_ENV 只对**后续步骤**生效，当前进程的 $env: 不会变；
      而 pre-restore 需要在同一进程里读回 restore-snapshot.ps1 刚写的 SNAPSHOT_STATUS。
    #>
    param([Parameter(Mandatory=$true)][string]$Name)
    if (-not $env:GITHUB_ENV) { return '' }
    if (-not (Test-Path -LiteralPath $env:GITHUB_ENV)) { return '' }
    $v = ''
    try {
        $rx = '^' + [regex]::Escape($Name) + '=(.*)$'
        foreach ($line in @(Get-Content -LiteralPath $env:GITHUB_ENV -ErrorAction SilentlyContinue)) {
            $m = [regex]::Match([string]$line, $rx)
            if ($m.Success) { $v = $m.Groups[1].Value }
        }
    } catch { }
    return $v
}

# ------------------------------------------------------------------ 状态落盘
function Set-RestoreStatus {
    <#
      统一写「数据恢复 / 快照拉取」状态。三处落地，缺一不可：
        1) GITHUB_ENV：RESTORE_STATUS / RESTORE_REASON（供后续步骤与保活自愈判断）
        2) <SysDir>\_state\restore-status.json（供工作台经 SMB 读，含 reason / 时间 / 远端路径）
        3) 标记文件（向后兼容 README 里写的 _RESTORE_FAILED.txt）
      绝不做「网络失败也报 OK」这种事：Status 由调用方按 Verdict 传。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Status,
        [string]$Reason = "",
        [ValidateSet('data', 'snapshot')][string]$Scope = 'data',
        [string]$SysDir = "",
        [string]$Remote = "",
        [string]$Local  = "",
        [switch]$KeepLegacyMarker
    )
    $st = ([string]$Status).Trim().ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($st)) { $st = 'UNKNOWN' }

    if ([string]::IsNullOrWhiteSpace($SysDir)) {
        if ($env:CLOUDRDP_SYS_DIR) { $SysDir = $env:CLOUDRDP_SYS_DIR }
        elseif (Test-Path 'D:\') { $SysDir = 'D:\cloudrdp-sys' }
        else { $SysDir = 'C:\cloudrdp-sys' }
    }

    # ---- 1) GITHUB_ENV ----
    try {
        if ($env:GITHUB_ENV) {
            if ($Scope -eq 'snapshot') {
                "SNAPSHOT_STATUS=$st" | Out-File $env:GITHUB_ENV -Append -Encoding ascii
            } else {
                "RESTORE_STATUS=$st" | Out-File $env:GITHUB_ENV -Append -Encoding ascii
            }
            "RESTORE_REASON=$Reason" | Out-File $env:GITHUB_ENV -Append -Encoding ascii
        }
    } catch { Write-Warning "[remote] 写 GITHUB_ENV 失败：$($_.Exception.Message)" }

    # ---- 2) _state\restore-status.json（工作台读这个）----
    # 按 scope 分键合并写：data / snapshot 各占一个键，**互不覆盖**。
    # （踩过的坑：sync-down 与 pre-restore 都写同一个文件，后写的把先写的冲掉，
    #   于是「数据恢复了没」和「快照拉下来了没」只能看到一个。）
    try {
        $stateDir = Join-Path $SysDir '_state'
        New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
        $jsonPath = Join-Path $stateDir 'restore-status.json'

        $obj = [ordered]@{
            updated_utc = (Get-Date).ToUniversalTime().ToString('o')
            host        = $env:COMPUTERNAME
            run_id      = $env:GITHUB_RUN_ID
            role        = if ($env:POOL_ROLE) { $env:POOL_ROLE } else { '' }
        }
        if (Test-Path -LiteralPath $jsonPath) {
            try {
                $old = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($k in @('data', 'snapshot')) {
                    if ($old.PSObject.Properties[$k] -and $old.$k) { $obj[$k] = $old.$k }
                }
                # 兼容更早的单对象结构（顶层 status/reason）：当作 data 读回来
                if (-not $obj.Contains('data') -and $old.PSObject.Properties['status'] -and $old.status) {
                    $obj['data'] = [ordered]@{
                        status = [string]$old.status; reason = [string]$old.reason
                        at_utc = [string]$old.at_utc; scope = 'data'
                    }
                }
            } catch { }
        }
        $obj[$Scope] = [ordered]@{
            status = $st
            reason = $Reason
            scope  = $Scope
            remote = $Remote
            local  = $Local
            at_utc = (Get-Date).ToUniversalTime().ToString('o')
        }
        # 先写临时文件再替换，避免工作台读到写了一半的 JSON
        $tmp = $jsonPath + '.tmp'
        ($obj | ConvertTo-Json -Depth 6) | Out-File -LiteralPath $tmp -Encoding UTF8
        try { if ([System.IO.File]::Exists($jsonPath)) { [System.IO.File]::Delete($jsonPath) } } catch { }
        [System.IO.File]::Move($tmp, $jsonPath)
    } catch { Write-Warning "[remote] 写 restore-status.json 失败：$($_.Exception.Message)" }

    # ---- 3) 标记文件（数据作用域；沿用 README 里的老名字）----
    if ($Scope -eq 'data' -and -not [string]::IsNullOrWhiteSpace($Local)) {
        try {
            $fail  = Join-Path $Local '_RESTORE_FAILED.txt'
            $empty = Join-Path $Local '_RESTORE_EMPTY.txt'
            foreach ($f in @($fail, $empty)) {
                try { if ([System.IO.File]::Exists($f)) { [System.IO.File]::Delete($f) } } catch { }
            }
            if ($st -eq 'EMPTY' -and $KeepLegacyMarker) {
                @(
                  "restore EMPTY at $((Get-Date).ToUniversalTime().ToString('o'))"
                  "reason=$Reason"
                  "remote=$Remote"
                ) | Out-File -LiteralPath $empty -Encoding utf8
            } elseif ($st -in @('TRANSIENT', 'FAILED', 'AUTH') -and $KeepLegacyMarker) {
                @(
                  "restore $st at $((Get-Date).ToUniversalTime().ToString('o'))"
                  "reason=$Reason"
                  "remote=$Remote"
                ) | Out-File -LiteralPath $fail -Encoding utf8
            }
        } catch { Write-Warning "[remote] 写标记文件失败：$($_.Exception.Message)" }
    }
}
