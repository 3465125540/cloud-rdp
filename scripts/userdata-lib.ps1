<#
.SYNOPSIS
  用户数据完整性：取证（校验到位没有）+ 补漏（从快照补写）。

.DESCRIPTION
  为什么单独抽一个库：
    · 第 8 步（pre-restore）负责「全量还原」，但它对「到底漏没漏」是弱感知 —— 日志里
      只有一句「个人文件预还原：N 个目录」，N 个目录里有没有 Edge 的 Login Data（已存密码）、
      有没有 WorkBuddy 的 .workbuddy（用户数据/缓存），从日志里根本看不出来。
    · 用户最在意的恰恰是这两块。真机踩过的坑：清单里写的是 .workbuddy-ai，
      而这台机器上根本不存在该目录 → WorkBuddy 数据一直是「静默零还原」，
      且因为目录不存在，连告警都没有。

  本库被两处共用，保证「校验口径」只有一个：
    · restore-snapshot.ps1  —— 还原后取证（写 EDGE_RESTORE / WBAI_RESTORE / USERDATA_RESTORE）
    · reinstall-apps.ps1    —— 第 10 步（后台重装软件）收尾时兜底校验 + 补漏

  目标清单来自 snapshot-config.json 的 restore.userDataTargets；配置缺失时用内置默认值。

  补漏是「只补不删」（robocopy 不带 /PURGE）：不动用户在机器上新增的文件，
  缺什么补什么，因此重复执行安全（幂等）。

.NOTES
  所有函数 fail-soft，永不抛异常；返回值为可序列化对象，便于写进 apps-status.json。
#>

# 内置兜底目标（配置缺失时用）
$script:UD_DefaultTargets = @(
    [pscustomobject]@{
        name     = 'Edge 浏览器'
        path     = '%RDPUSERPROFILE%\AppData\Local\Microsoft\Edge\User Data'
        required = @('Local State', 'Default\Bookmarks', 'Default\History', 'Default\Login Data', 'Default\Preferences', 'Default\Web Data')
    },
    [pscustomobject]@{ name = 'WorkBuddy 用户数据';           path = '%RDPUSERPROFILE%\.workbuddy';                       required = @() },
    [pscustomobject]@{ name = 'WorkBuddy 用户数据（旧路径）'; path = '%RDPUSERPROFILE%\.workbuddy-ai';                    required = @() },
    [pscustomobject]@{ name = 'WorkBuddy 安装目录';           path = '%RDPUSERPROFILE%\AppData\Local\Programs\WorkBuddy'; required = @() },
    [pscustomobject]@{ name = 'WorkBuddy 运行数据';           path = '%RDPUSERPROFILE%\AppData\Local\WorkBuddy';          required = @() },
    [pscustomobject]@{ name = 'WorkBuddy 配置';               path = '%RDPUSERPROFILE%\AppData\Roaming\WorkBuddy';        required = @() }
)

function Write-UDMsg {
    param([string]$Message, [scriptblock]$Log)
    if ($null -ne $Log) { try { & $Log $Message; return } catch { } }
    Write-Host "[userdata] $Message"
}

function Get-UDCfg {
    param($Obj, [string]$Name, $Fallback)
    if ($null -eq $Obj) { return $Fallback }
    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($Name) -and $null -ne $Obj[$Name]) { return $Obj[$Name] }
        return $Fallback
    }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Fallback }
    return $p.Value
}

function Expand-UDPath {
    param([string]$Path, [string]$RdpUser)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    $sep = [IO.Path]::DirectorySeparatorChar
    $r = $Path
    $r = $r -replace '%RDPUSERPROFILE%', ('C:' + $sep + 'Users' + $sep + $RdpUser)
    $r = $r -replace '%RDPUSER%', $RdpUser
    $r = [System.Environment]::ExpandEnvironmentVariables($r)
    return $r
}

# C:\Users\a\.workbuddy  ->  C\Users\a\.workbuddy   （去掉盘符冒号）
function Get-UDMirrorRel {
    param([string]$Abs)
    if ([string]::IsNullOrWhiteSpace($Abs)) { return '' }
    $a = $Abs.TrimEnd([IO.Path]::DirectorySeparatorChar)
    $a = $a -replace '^([A-Za-z]):', '$1'
    $a = $a -replace '^[\\/]+', ''
    return $a
}

function Get-UserDataTargets {
    param([string]$ConfigPath)
    $out = New-Object System.Collections.Generic.List[object]
    $cfg = $null
    if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath)) {
        try { $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    $raw = @()
    if ($cfg) { $raw = @(Get-UDCfg (Get-UDCfg $cfg 'restore' $null) 'userDataTargets' @()) }
    foreach ($t in $raw) {
        if ($null -eq $t) { continue }
        $p = [string](Get-UDCfg $t 'path' '')
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $out.Add([pscustomobject]@{
            name     = [string](Get-UDCfg $t 'name' $p)
            path     = $p
            required = @(Get-UDCfg $t 'required' @())
        })
    }
    if ($out.Count -eq 0) { return $script:UD_DefaultTargets }
    return $out.ToArray()
}

# 找快照里对应的目录。用户名可能已迁移（pre-restore 的 rdpuser-migrate），
# 所以精确路径找不到时，按「C:\Users\<任意>\<尾部>」再找一次。
function Find-UDSnapshotDir {
    param([string]$Stage, [string]$Abs)
    if ([string]::IsNullOrWhiteSpace($Stage)) { return '' }
    if (-not (Test-Path -LiteralPath $Stage)) { return '' }
    $mir = Get-UDMirrorRel -Abs $Abs
    if ([string]::IsNullOrWhiteSpace($mir)) { return '' }
    $p1 = Join-Path (Join-Path $Stage 'files') $mir
    if (Test-Path -LiteralPath $p1) { return $p1 }

    $tail = ''
    if ($mir -match '(?i)^C\\Users\\[^\\]+\\+(.+)$') { $tail = $Matches[1] }
    if ([string]::IsNullOrWhiteSpace($tail)) { return '' }
    $usersRoot = Join-Path (Join-Path (Join-Path $Stage 'files') 'C') 'Users'
    if (-not (Test-Path -LiteralPath $usersRoot)) { return '' }
    foreach ($d in @(Get-ChildItem -LiteralPath $usersRoot -Directory -Force -ErrorAction SilentlyContinue)) {
        $cand = Join-Path $d.FullName $tail
        if (Test-Path -LiteralPath $cand) { return $cand }
    }
    return ''
}

function Get-UserDataEvidence {
    param([string]$RdpUser, [string]$ConfigPath, [string]$Stage)
    $targets = Get-UserDataTargets -ConfigPath $ConfigPath
    $res = New-Object System.Collections.Generic.List[object]
    foreach ($t in $targets) {
        $abs  = Expand-UDPath -Path ([string]$t.path) -RdpUser $RdpUser
        $req  = @($t.required)
        $snap = Find-UDSnapshotDir -Stage $Stage -Abs $abs
        $snapHas = -not [string]::IsNullOrWhiteSpace($snap)
        $exists  = Test-Path -LiteralPath $abs

        $missing = New-Object System.Collections.Generic.List[string]
        $found = 0
        foreach ($r in $req) {
            $p = Join-Path $abs $r
            $okF = $false
            try { $okF = (Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p -Force).Length -gt 0) } catch { }
            if ($okF) { $found++ } else { $missing.Add($r) }
        }

        $state = 'MISSING'
        if (-not $exists -and -not $snapHas) { $state = 'ABSENT' }
        elseif (-not $exists)                { $state = 'MISSING' }
        elseif (-not $snapHas)               { $state = 'NO-SNAP' }
        elseif ($req.Count -eq 0)            { $state = 'OK' }
        elseif ($found -eq $req.Count)       { $state = 'OK' }
        elseif ($found -gt 0)                { $state = 'PARTIAL' }
        else                                 { $state = 'MISSING' }

        $detail = if ($req.Count -gt 0) { ('{0}/{1}' -f $found, $req.Count) } else { '目录' }
        $res.Add([pscustomobject]@{
            name     = [string]$t.name
            path     = $abs
            snapshot = $snap
            state    = $state
            detail   = $detail
            found    = $found
            total    = $req.Count
            missing  = $missing.ToArray()
        })
    }
    return $res.ToArray()
}

function Format-UserDataEvidence {
    param($Evidence)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($e in @($Evidence)) { $parts.Add(('{0} {1}({2})' -f $e.name, $e.state, $e.detail)) }
    return ($parts -join ' | ')
}

# 只补不删。返回 @{ code = robocopy 码; ok = 是否可接受 }
function Invoke-UDCopy {
    param([string]$Src, [string]$Dst, [scriptblock]$Log)
    if ([string]::IsNullOrWhiteSpace($Src) -or -not (Test-Path -LiteralPath $Src)) { return @{ code = -1; ok = $false } }
    New-Item -ItemType Directory -Force -Path $Dst | Out-Null
    # 注意：不加 /PURGE —— 只补回快照里的文件，不删机器上新增的文件
    $rc = @($Src, $Dst, '/E', '/COPY:DAT', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/XJ')
    $out = @(& robocopy @rc 2>&1)
    $code = $LASTEXITCODE
    if ($code -ge 8 -and
        (Get-Command Copy-FileShared      -ErrorAction SilentlyContinue) -and
        (Get-Command Get-RobocopyFailedFile -ErrorAction SilentlyContinue)) {
        $failed = @(Get-RobocopyFailedFile -RobocopyOutput $out)
        $fixed = 0
        foreach ($fp in $failed) {
            $relF = Get-RelPathUnder -Path $fp -Root $Src
            if ([string]::IsNullOrWhiteSpace($relF)) { continue }
            $r = Copy-FileShared -Source $fp -Destination (Join-Path $Dst $relF)
            if ($r.ok) { $fixed++ }
        }
        if ($fixed -gt 0) {
            Write-UDMsg ('  被占用文件补写：{0}/{1}（robocopy 码 {2}）' -f $fixed, $failed.Count, $code) -Log $Log
            if ($fixed -eq $failed.Count) { $code = 0 }
        }
    }
    return @{ code = $code; ok = ($code -lt 8) }
}

# 补漏前关闭占用程序（Edge 的 Login Data / WorkBuddy 的 SQLite 都是独占持有）
function Invoke-UDQuiesce {
    param([string]$ConfigPath, [scriptblock]$Log)
    if (-not (Get-Command Stop-AppForSnapshot -ErrorAction SilentlyContinue)) { return 'no-lib' }
    if (-not (Get-Command Get-QuiesceSpecs   -ErrorAction SilentlyContinue)) { return 'no-lib' }
    $specs = @(Get-QuiesceSpecs -ConfigPath $ConfigPath)
    if ($specs.Count -eq 0) { return 'none' }
    Write-UDMsg ('补漏前关闭占用程序（{0}）' -f (($specs | ForEach-Object { $_.name }) -join ', ')) -Log $Log
    $q = Stop-AppForSnapshot -Specs $specs -Log $Log
    return [string]$q.detail
}

function Invoke-UserDataRepair {
    param([string]$Stage, [string]$RdpUser, [string]$ConfigPath, [scriptblock]$Log, [switch]$Quiesce)
    $ev = @(Get-UserDataEvidence -RdpUser $RdpUser -ConfigPath $ConfigPath -Stage $Stage)
    $todo = @($ev | Where-Object { $_.state -eq 'MISSING' -or $_.state -eq 'PARTIAL' })
    $r = [ordered]@{ repaired = 0; failed = 0; skipped = 0; quiesce = 'none'; results = @() }
    if ($todo.Count -eq 0) {
        Write-UDMsg '无需补漏（所有目标均已到位）' -Log $Log
        return $r
    }
    if ($Quiesce) { $r.quiesce = Invoke-UDQuiesce -ConfigPath $ConfigPath -Log $Log }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($e in $todo) {
        if ([string]::IsNullOrWhiteSpace([string]$e.snapshot)) {
            Write-UDMsg ('  无法补漏（快照里没有）：{0}' -f $e.name) -Log $Log
            $r.skipped++
            $rows.Add([pscustomobject]@{ name = $e.name; action = 'no-snapshot'; ok = $false })
            continue
        }
        Write-UDMsg ('  补漏 {0}：{1} -> {2}' -f $e.name, $e.snapshot, $e.path) -Log $Log
        $c = Invoke-UDCopy -Src $e.snapshot -Dst $e.path -Log $Log
        if ($c.ok) { $r.repaired++ } else { $r.failed++ }
        $rows.Add([pscustomobject]@{ name = $e.name; action = 'copy'; ok = [bool]$c.ok; code = [int]$c.code })
    }
    $r.results = $rows.ToArray()
    return $r
}

# 唯一对外入口：校验 → （可选）补漏 → 再校验 → 写 GITHUB_ENV
function Invoke-UserDataVerifyAndRepair {
    param(
        [string]$Stage, [string]$RdpUser, [string]$ConfigPath,
        [scriptblock]$Log,
        [switch]$NoRepair,
        [switch]$Quiesce,
        [string]$EvidenceLogPath = ''
    )
    $before = @(Get-UserDataEvidence -RdpUser $RdpUser -ConfigPath $ConfigPath -Stage $Stage)
    Write-UDMsg ('校验：' + (Format-UserDataEvidence -Evidence $before)) -Log $Log

    $repair = $null
    if (-not $NoRepair) {
        $repair = Invoke-UserDataRepair -Stage $Stage -RdpUser $RdpUser -ConfigPath $ConfigPath -Log $Log -Quiesce:$Quiesce
    }

    $after = @(Get-UserDataEvidence -RdpUser $RdpUser -ConfigPath $ConfigPath -Stage $Stage)
    if ($repair) { Write-UDMsg ('补漏后：' + (Format-UserDataEvidence -Evidence $after)) -Log $Log }

    # 只把「本该有」的目标计入成败：ABSENT（两边都没有）不算问题
    $judge   = @($after | Where-Object { $_.state -ne 'ABSENT' })
    $bad     = @($judge | Where-Object { $_.state -eq 'MISSING' -or $_.state -eq 'PARTIAL' -or $_.state -eq 'NO-SNAP' })
    $okCount = @($judge | Where-Object { $_.state -eq 'OK' }).Count
    $state   = if ($bad.Count -eq 0) { 'OK' } elseif ($okCount -gt 0) { 'PARTIAL' } else { 'MISSING' }

    $edge = @($after | Where-Object { $_.name -like 'Edge*' })
    $wb   = @($after | Where-Object { $_.name -like 'WorkBuddy*' -and $_.name -notlike '*旧路径*' })
    $edgeState = if ($edge.Count -gt 0) { [string]$edge[0].state } else { 'N/A' }
    $wbState   = if ($wb.Count   -gt 0) { [string]$wb[0].state }   else { 'N/A' }

    $detail = ('{0}/{1} 目标完整' -f $okCount, $judge.Count)
    if ($repair) { $detail += ('；补漏 {0} 个 / 失败 {1} 个 / 跳过 {2} 个' -f $repair.repaired, $repair.failed, $repair.skipped) }

    if ($env:GITHUB_ENV) {
        try {
            ('USERDATA_RESTORE=' + $state)         | Out-File $env:GITHUB_ENV -Append -Encoding ascii
            ('USERDATA_RESTORE_DETAIL=' + $detail) | Out-File $env:GITHUB_ENV -Append -Encoding ascii
            ('EDGE_RESTORE=' + $edgeState)         | Out-File $env:GITHUB_ENV -Append -Encoding ascii
            ('WBAI_RESTORE=' + $wbState)           | Out-File $env:GITHUB_ENV -Append -Encoding ascii
        } catch { }
    }
    if (-not [string]::IsNullOrWhiteSpace($EvidenceLogPath)) {
        try {
            ('[{0}] userdata state={1} detail={2} | {3}' -f (Get-Date).ToString('o'), $state, $detail, (Format-UserDataEvidence -Evidence $after)) |
                Out-File -LiteralPath $EvidenceLogPath -Append -Encoding utf8
        } catch { }
    }

    return [pscustomobject]@{
        state    = $state
        detail   = $detail
        ok       = ($state -eq 'OK')
        edge     = $edgeState
        wb       = $wbState
        repaired = $(if ($repair) { $repair.repaired } else { 0 })
        failed   = $(if ($repair) { $repair.failed }   else { 0 })
        skipped  = $(if ($repair) { $repair.skipped }  else { 0 })
        quiesce  = $(if ($repair) { $repair.quiesce }  else { 'none' })
        before   = @($before)
        after    = @($after)
    }
}
