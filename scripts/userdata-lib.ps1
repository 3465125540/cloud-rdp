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
    · restore-snapshot.ps1  —— 还原后取证（写 EDGE_RESTORE / WBAI_RESTORE / UU_RESTORE / USERDATA_RESTORE）
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
        required = @('Local State', 'Default\Bookmarks', 'Default\History', 'Default\Login Data', 'Default\Preferences', 'Default\Web Data', 'Default\Cookies', 'Default\Local Storage', 'Default\Session Storage')
    },
    [pscustomobject]@{ name = 'WorkBuddy 用户数据';           path = '%RDPUSERPROFILE%\.workbuddy';                       required = @() },
    [pscustomobject]@{ name = 'WorkBuddy 用户数据（旧路径）'; path = '%RDPUSERPROFILE%\.workbuddy-ai';                    required = @() },
    [pscustomobject]@{ name = 'WorkBuddy 安装目录';           path = '%RDPUSERPROFILE%\AppData\Local\Programs\WorkBuddy'; required = @() },
    [pscustomobject]@{ name = 'WorkBuddy 运行数据';           path = '%RDPUSERPROFILE%\AppData\Local\WorkBuddy';          required = @() },
    [pscustomobject]@{ name = 'WorkBuddy 配置';               path = '%RDPUSERPROFILE%\AppData\Roaming\WorkBuddy';        required = @() },
    # UU远程（网易 GameViewer）：设备身份分机器级 + 用户级两处，缺一处就会被当成新设备、
    # 反复要求「登录 / 创建账号 / 重新绑定」。机器级那份在 C:\ProgramData 下（不是 %RDPUSERPROFILE%），
    # 历史上从未进过清单 —— 这就是「UU远程 每次都当新机」的根因。
    [pscustomobject]@{ name = 'UU远程（机器级）'; path = 'C:\ProgramData\Netease\GameViewer';                     required = @('user_info.ini', 'config.ini', 'remote_assist_code.ini') },
    [pscustomobject]@{ name = 'UU远程（用户级）'; path = '%RDPUSERPROFILE%\AppData\Local\GameViewer';              required = @('setting.ini', 'setting_guest_anonymous_id.ini') }
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

# ---------------------------------------------------------------- Edge 加密密钥（DPAPI）能力探测
# 为什么必须单独探测（用户最痛的点）：
#   Edge 的「已保存密码」在 Default\Login Data 里、「Cookie」在 Default\Cookies 里，
#   两者都用 Local State 里的 os_crypt.encrypted_key 加密，而该 key 由
#   Windows DPAPI（CryptProtectData，CurrentUser 作用域）保护 —— 密钥派生自
#   「旧机器 + 旧用户」。换机器后 DPAPI 解不开 → Edge 把这些密文当损坏数据丢弃
#   → 用户看到的就是「所有网页账号数据丢失」。
#   这件事在文件层面完全看不出来（文件在、字节也在，就是解不开），
#   所以必须真去解一次：以 RDP 用户身份（-LoadUserProfile）调 ProtectedData.Unprotect。
#   解不开 = BROKEN（跨机必然如此，属预期）；解开 = OK（同机 / 同 profile 复跑）。
#
# ⚠️ 时序要求：探测必须在 Edge 启动之前做（还原阶段），否则 Edge 会重建 Local State，
#    探到的是新机器的 key（假 OK）。restore-snapshot.ps1 的 4d 段正好满足。
function Get-UDEdgeUserDataDir {
    param([string]$RdpUser, [string]$ConfigPath)
    $targets = Get-UserDataTargets -ConfigPath $ConfigPath
    foreach ($t in $targets) {
        if ([string]$t.name -like 'Edge*') { return (Expand-UDPath -Path ([string]$t.path) -RdpUser $RdpUser) }
    }
    return (Expand-UDPath -Path '%RDPUSERPROFILE%\AppData\Local\Microsoft\Edge\User Data' -RdpUser $RdpUser)
}

function Format-UDCryptGuidance {
    return ('Edge 已保存的密码 / Cookie 跨机解不开（Windows DPAPI 把密钥绑在旧机器+旧用户上）。' +
            '已恢复：历史 / 收藏夹 / 偏好设置 / 自动填充(Web Data) / 站点本地存储(Local Storage、IndexedDB、Service Worker)。' +
            '要恢复登录态：在 Edge 登录 Microsoft 或 Google 账号并开启「同步」（设置 → 个人资料 → 同步）。')
}

# ---------------------------------------------------------------- UU远程（网易 GameViewer）
# 为什么单列：UU远程 用「本机设备身份」而不是账号来决定「你是不是新设备」。
#   机器级  C:\ProgramData\Netease\GameViewer\user_info.ini  → deviceId（明文，设备指纹）
#           C:\ProgramData\Netease\GameViewer\config.ini     → uuid
#           C:\ProgramData\Netease\GameViewer\remote_assist_code.ini → 远程协助码（DPAPI 密文）
#   用户级  %LOCALAPPDATA%\GameViewer\setting.ini + setting_guest_anonymous_id.ini
# 历史上两处都不在快照清单里（ProgramData 是机器级路径，不是 %RDPUSERPROFILE% 系）
# → 每轮新机器都被当成全新设备 → 反复要求登录 / 创建账号 / 重新绑定设备。
# 实测（本机 + 云机对照）：登录态字段 token / userId 为空是**正常**的 —— UU远程 免登录也能用
#   远程协助，靠的就是 deviceId + 协助码。所以「创建新账户」提示 = 设备身份丢了，不是账号丢了。
function Format-UDUUGuidance {
    return ('UU远程（GameViewer）的设备身份没带全 —— 机器级 C:\ProgramData\Netease\GameViewer（deviceId / uuid / 协助码）' +
            '与用户级 %LOCALAPPDATA%\GameViewer（setting.ini）已纳入快照。' +
            '若仍提示「新设备 / 请登录 / 创建账号」：remote_assist_code.ini 里的 code / customize_code 是 DPAPI 密文，' +
            '跨机解不开（与 Edge 的 os_crypt 同一类问题）→ 协助码会被 UU远程 重新生成，这是预期内的。' +
            '要彻底免掉新设备提示：在 UU远程 里登录 UU 账号（账号级设备绑定存在服务端；user_info.ini 的 token 是明文，会随快照一起还原）。')
}

# 以 RDP 用户身份解一次 Local State 里的 os_crypt.encrypted_key
# 返回 [pscustomobject]@{ state='OK'|'BROKEN'|'UNKNOWN'; note='' }
function Test-EdgeCryptState {
    param(
        [string]$RdpUser,
        [string]$EdgeUserDataDir,
        [scriptblock]$Log,
        [int]$TimeoutSec = 60
    )

    $res = [pscustomobject]@{ state = 'UNKNOWN'; note = '' }
    if ([string]::IsNullOrWhiteSpace($EdgeUserDataDir)) { $res.note = '未指定 Edge User Data 目录'; return $res }
    $ls = Join-Path $EdgeUserDataDir 'Local State'
    if (-not (Test-Path -LiteralPath $ls)) { $res.note = '没有 Local State（Edge 数据未还原，或该机从未用过 Edge）'; return $res }
    if (-not (Get-Command Invoke-AsRdpUser -ErrorAction SilentlyContinue)) {
        $res.note = '未加载 userprofile-lib.ps1，无法以用户身份探测'
        return $res
    }

    # 探测脚本 + 结果文件都放用户自己的 Temp（该用户可读写；-Credential 不支持输出重定向）
    $tmpDir = Join-Path (Join-Path 'C:\Users' $RdpUser) 'AppData\Local\Temp'
    try { New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null } catch { }
    $tag     = [guid]::NewGuid().ToString('N')
    $probe   = Join-Path $tmpDir ("crdp-edge-crypt-" + $tag + ".ps1")
    $outFile = Join-Path $tmpDir ("crdp-edge-crypt-" + $tag + ".out")
    try { if (Test-Path -LiteralPath $outFile) { Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue } } catch { }

    # 正文刻意保持纯 ASCII：-File 启动的 UTF-8 无 BOM 脚本会被当成 ANSI，含中文会乱码。
    $body = @'
$ErrorActionPreference = 'Stop'
function Emit([string]$s) { try { $s | Out-File -LiteralPath '<OUT>' -Encoding ascii -Force } catch { } }
try {
    $ls = Get-Content -LiteralPath '<LS>' -Raw -Encoding UTF8 | ConvertFrom-Json
    $b64 = [string]$ls.os_crypt.encrypted_key
    if ([string]::IsNullOrWhiteSpace($b64)) { Emit 'UNKNOWN:no-key'; exit 0 }
    $raw = [Convert]::FromBase64String($b64)
    if ($raw.Length -le 5) { Emit 'UNKNOWN:short-blob'; exit 0 }
    # 前 5 字节固定是 'DPAPI' 标记
    $blob = New-Object byte[] ($raw.Length - 5)
    [Array]::Copy($raw, 5, $blob, 0, $blob.Length)
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    $null = [System.Security.Cryptography.ProtectedData]::Unprotect($blob, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    Emit 'OK'
} catch {
    Emit ('BROKEN:' + $_.Exception.GetType().Name)
}
'@
    $body = $body.Replace('<LS>', $ls).Replace('<OUT>', $outFile)
    try { [System.IO.File]::WriteAllText($probe, $body, (New-Object System.Text.UTF8Encoding $false)) }
    catch { $res.note = ('写探测脚本失败：' + $_.Exception.Message); return $res }

    $pwshExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = 'powershell.exe' }
    $r = Invoke-AsRdpUser -RdpUser $RdpUser -FilePath $pwshExe `
            -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $probe) `
            -Log $Log -TimeoutSec $TimeoutSec -What 'Edge DPAPI 探测'

    $txt = ''
    try { if (Test-Path -LiteralPath $outFile) { $txt = (Get-Content -LiteralPath $outFile -Raw -ErrorAction Stop).Trim() } } catch { }
    foreach ($f in @($probe, $outFile)) { try { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } catch { } }

    if ($txt -eq 'OK')        { $res.state = 'OK';      $res.note = '密钥可解（同机 / 同 profile）'; return $res }
    if ($txt -like 'BROKEN*') { $res.state = 'BROKEN';  $res.note = $txt; return $res }
    $res.note = $(if ($txt) { $txt } else { '探测无结果' }) + $(if ($r.note) { '（' + $r.note + '）' } else { '' })
    return $res
}

# 唯一对外入口：校验 → （可选）补漏 → 再校验 → 写 GITHUB_ENV
function Invoke-UserDataVerifyAndRepair {
    param(
        [string]$Stage, [string]$RdpUser, [string]$ConfigPath,
        [scriptblock]$Log,
        [switch]$NoRepair,
        [switch]$Quiesce,
        [switch]$ProbeCrypt,
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

    # UU远程：两个目标（机器级 ProgramData + 用户级 AppData）合并成一个结论 ——
    # 任一缺失都算「设备身份没带全」，也就是用户看到的「每次都当新设备 / 要创建账号」。
    $uu      = @($after | Where-Object { $_.name -like 'UU远程*' })
    $uuJudge = @($uu | Where-Object { $_.state -ne 'ABSENT' })     # 两边都没有 = 没装，不算问题
    $uuBad   = @($uuJudge | Where-Object { $_.state -ne 'OK' })
    $uuOkN   = @($uuJudge | Where-Object { $_.state -eq 'OK' }).Count
    $uuState = 'N/A'
    if ($uu.Count -gt 0 -and $uuJudge.Count -gt 0) {
        if     ($uuBad.Count -eq 0) { $uuState = 'OK' }
        elseif ($uuOkN -gt 0)       { $uuState = 'PARTIAL' }
        else                        { $uuState = 'MISSING' }
    }

    $detail = ('{0}/{1} 目标完整' -f $okCount, $judge.Count)
    if ($repair) { $detail += ('；补漏 {0} 个 / 失败 {1} 个 / 跳过 {2} 个' -f $repair.repaired, $repair.failed, $repair.skipped) }
    if ($uuState -ne 'N/A' -and $uuState -ne 'OK') {
        $detail += ('；UU远程 {0}' -f $uuState)
        Write-UDMsg ('  ⚠ ' + (Format-UDUUGuidance)) -Log $Log
    }

    # Edge 加密能力探测（可选）：文件「在不在」看不出「解不解得开」，
    # 密码/Cookie 跨机必然解不开 —— 这里把它变成一条可见、可行动的结论。
    $cryptState = 'UNKNOWN'
    $cryptNote  = ''
    if ($ProbeCrypt) {
        $edgeDir = Get-UDEdgeUserDataDir -RdpUser $RdpUser -ConfigPath $ConfigPath
        $cr = Test-EdgeCryptState -RdpUser $RdpUser -EdgeUserDataDir $edgeDir -Log $Log
        $cryptState = [string]$cr.state
        $cryptNote  = [string]$cr.note
        Write-UDMsg ('Edge 加密密钥探测：{0}（{1}）' -f $cryptState, $cryptNote) -Log $Log
        if ($cryptState -eq 'BROKEN') { Write-UDMsg ('  ⚠ ' + (Format-UDCryptGuidance)) -Log $Log }
        $detail += ('；Edge 加密密钥 {0}' -f $cryptState)
    }

    if ($env:GITHUB_ENV) {
        try {
            ('USERDATA_RESTORE=' + $state)         | Out-File $env:GITHUB_ENV -Append -Encoding ascii
            ('USERDATA_RESTORE_DETAIL=' + $detail) | Out-File $env:GITHUB_ENV -Append -Encoding ascii
            ('EDGE_RESTORE=' + $edgeState)         | Out-File $env:GITHUB_ENV -Append -Encoding ascii
            ('WBAI_RESTORE=' + $wbState)           | Out-File $env:GITHUB_ENV -Append -Encoding ascii
            ('UU_RESTORE=' + $uuState)             | Out-File $env:GITHUB_ENV -Append -Encoding ascii
            if ($ProbeCrypt) {
                ('EDGE_CRYPT=' + $cryptState)      | Out-File $env:GITHUB_ENV -Append -Encoding ascii
                ('EDGE_CRYPT_NOTE=' + $cryptNote)  | Out-File $env:GITHUB_ENV -Append -Encoding ascii
            }
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
        uu       = $uuState
        crypt    = $cryptState
        cryptNote= $cryptNote
        repaired = $(if ($repair) { $repair.repaired } else { 0 })
        failed   = $(if ($repair) { $repair.failed }   else { 0 })
        skipped  = $(if ($repair) { $repair.skipped }  else { 0 })
        quiesce  = $(if ($repair) { $repair.quiesce }  else { 'none' })
        before   = @($before)
        after    = @($after)
    }
}
