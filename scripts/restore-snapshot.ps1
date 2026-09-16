<#
.SYNOPSIS
  从 139 云盘还原「整机状态快照」。

.DESCRIPTION
  为什么分两个作用域？—— 这是 Windows 跨机还原的核心难点：
    · runner 进程以 runneradmin 身份运行，而 RDP 用户是 NvdAdmin；
    · NvdAdmin 的 HKCU 注册表与用户配置文件（Desktop/Documents…）在
      该用户首次登录前并不存在，以 runneradmin 身份写入会被 Windows
      当成「异常 profile」而在登录时重建，导致还原失效。

  因此：
    -Scope machine  开机时以 runneradmin 执行：拉取快照、还原机器级文件、
                    导入机器注册表、恢复系统设置（时区/电源）、还原公共桌面，
                    并注册一个「首次登录时触发」的计划任务。
    -Scope user     用户首次登录时以 NvdAdmin 身份执行：还原个人目录文件、
                    导入 HKCU 注册表、还原个人快捷方式与壁纸，然后自注销任务。

.PARAMETER Scope   machine | user
.PARAMETER Pull    执行前先从远端拉取快照（仅 machine 作用域需要）

.NOTES
  本脚本永不返回非 0。结果透出 SNAPSHOT_STATUS / SNAPSHOT_RESTORED_*。
#>
[CmdletBinding()]
param(
    [ValidateSet("machine", "user")]
    [string]$Scope      = "machine",
    [string]$Stage      = $(if ($env:CLOUDRDP_SNAPSHOT_STAGE) { $env:CLOUDRDP_SNAPSHOT_STAGE } elseif (Test-Path 'D:\') { "D:\cloudrdp-sys\_snapshot" } else { "C:\_snapshot" }),
    [string]$Remote     = $(if ($env:CLOUDRDP_REMOTE_BASE) { $env:CLOUDRDP_REMOTE_BASE + "/_snapshot" } else { "alist:/cloudrdp/AI文件库/_snapshot" }),
    [string]$ConfigPath = (Join-Path $PSScriptRoot "snapshot-config.json"),
    [string]$RdpUser    = $(if ($env:RDP_USERNAME) { $env:RDP_USERNAME } else { "NvdAdmin" }),
    [switch]$Pull,
    [switch]$NoTask
)

$ErrorActionPreference = "Continue"
$SysDir        = if ($env:CLOUDRDP_SYS_DIR) { $env:CLOUDRDP_SYS_DIR } elseif (Test-Path 'D:\') { "D:\cloudrdp-sys" } else { "C:\cloudrdp-sys" }
$RcloneExe     = Join-Path $SysDir "rclone\rclone.exe"
$UserHiveToken = "__RDPUSER__"
$TaskName      = "CloudRDP-RestoreUser"
$PortableDir   = $(if ($env:CLOUDRDP_PORTABLE_DIR) { $env:CLOUDRDP_PORTABLE_DIR } else { "D:\a\cloud-rdp\_portable" })

# 可移动程序共享库（识别 / 搬运 / 还原）
$portableLib = Join-Path $PSScriptRoot "portable-lib.ps1"
if (Test-Path -LiteralPath $portableLib) { . $portableLib }
else { Write-Warning "[restore] 未找到 portable-lib.ps1，可移动程序还原不可用" }

# 安装型程序共享库（识别 / 备份 / 还原）
$programsLib = Join-Path $PSScriptRoot "programs-lib.ps1"
if (Test-Path -LiteralPath $programsLib) { . $programsLib }
else { Write-Warning "[restore] 未找到 programs-lib.ps1，安装型程序还原不可用" }

# 用户注册表 hive 共享库（定位 / 判断是否已加载）
# 用途：用户**已经登录**时（本次「连接信息提前打印」后很常见），hive 已被 Windows 加载，
#       此时不能再 reg load，否则必然失败；直接写 HKU\<SID> 才对。
$userHiveLib = Join-Path $PSScriptRoot "userhive-lib.ps1"
$script:HasUserHiveLib = $false
if (Test-Path -LiteralPath $userHiveLib) { . $userHiveLib; $script:HasUserHiveLib = $true }
else { Write-Warning "[restore] 未找到 userhive-lib.ps1，用户 hive 已加载时的兜底不可用" }

function Set-GhEnv([string]$kv) {
    if ($env:GITHUB_ENV) { $kv | Out-File $env:GITHUB_ENV -Append -Encoding ascii }
}
function Say([string]$m)  { Write-Host "[restore] $m" }
function Warn([string]$m) { Write-Warning "[restore] $m" }

function Get-Cfg($obj, $name, $fallback) {
    if ($null -eq $obj) { return $fallback }
    if ($obj -is [System.Collections.IDictionary]) {
        if ($obj.Contains($name) -and $null -ne $obj[$name]) { return $obj[$name] }
        return $fallback
    }
    $p = $obj.PSObject.Properties[$name]
    if ($null -eq $p -or $null -eq $p.Value) { return $fallback }
    return $p.Value
}

# ---------- 首次真正加载 snapshot-config.json，按开关决定还原哪些类别 ----------
$cfg = $null
if (Test-Path -LiteralPath $ConfigPath) {
    try { $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Warn "配置解析失败（$ConfigPath）：$_，全部按默认开启处理" }
} else {
    Warn "未找到配置 $ConfigPath，全部按默认开启处理"
}
$restoreCfg  = Get-Cfg $cfg 'restore' $null
$doFiles     = [bool](Get-Cfg $restoreCfg 'files'     $true)
$doRegistry  = [bool](Get-Cfg $restoreCfg 'registry'  $true)
$doSystem    = [bool](Get-Cfg $restoreCfg 'system'    $true)
$doShortcuts = [bool](Get-Cfg $restoreCfg 'shortcuts' $true)

# 安装型程序：还原开关 + 还原根（C 盘紧张时程序实体落 D 盘，原路径建 junction）
$programsCfg    = Get-Cfg $cfg 'programs' $null
$doPrograms     = [bool](Get-Cfg $programsCfg 'enabled' $true)
$preferJunction = [bool](Get-Cfg $programsCfg 'preferJunction' $true)
# 永不还原的程序目录（前缀匹配）：即使旧快照里含它，也不放回来
$programsExclude = [object[]](Get-Cfg $programsCfg 'excludePaths' @())
$ProgramsRoot   = $(if ($env:CLOUDRDP_PROGRAMS_DIR) { $env:CLOUDRDP_PROGRAMS_DIR } else { (Join-Path $SysDir "programs") })

function Get-SnapshotPrograms {
    param([string]$Stage)
    $f = Join-Path $Stage "programs\programs.json"
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    try { return @((Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json).programs) } catch { return @() }
}

function Get-AbsFromMirror {
    param([string]$Rel)
    $parts = $Rel -split '[\\/]'
    if ($parts.Count -lt 2) { return ($parts[0] + ":\") }
    return ("{0}:\{1}" -f $parts[0], ($parts[1..($parts.Count - 1)] -join '\'))
}

function Invoke-RobocopyRestore {
    param([string]$Src, [string]$Dst)
    if (-not (Test-Path -LiteralPath $Src)) { return -1 }
    New-Item -ItemType Directory -Force -Path $Dst | Out-Null
    # 注意：不加 /PURGE —— 只补回快照里的文件，不删除机器上新增的文件
    & robocopy $Src $Dst /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP /XJ 2>&1 | Out-Null
    return $LASTEXITCODE
}

# ================================================================ 通用：拉取快照

function Invoke-PullSnapshot {
    param([string]$Remote, [string]$Stage, [int]$MaxAttempts = 3, [int]$RetryDelaySec = 8)

    if (-not (Test-Path -LiteralPath $RcloneExe)) { Warn "未找到 rclone，无法拉取快照"; return "NO_RCLONE" }

    New-Item -ItemType Directory -Force -Path $Stage | Out-Null
    Say "拉取快照: $Remote  ->  $Stage"

    $code = 0
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        & $RcloneExe copy $Remote $Stage `
            --update --transfers 4 --checkers 8 `
            --timeout 0 --contimeout 0 `
            --retries 3 --low-level-retries 5 `
            --stats-one-line -v
        $code = $LASTEXITCODE
        if ($code -eq 0) { return "OK" }
        if ($code -eq 3 -or $code -eq 4) { return "EMPTY" }   # 远端尚无快照（首次运行）
        if ($i -lt $MaxAttempts) {
            Warn "第 $i/$MaxAttempts 次拉取失败（rclone 码 $code），$RetryDelaySec 秒后重试..."
            Start-Sleep -Seconds $RetryDelaySec
        }
    }
    return "FAILED"
}

# ================================================================ machine 作用域

function Invoke-MachineRestore {
    param([string]$Stage, [string]$RdpUser, [string]$ConfigPath, [switch]$NoTask)

    $manifestPath = Join-Path $Stage "manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        Say "未发现 manifest.json —— 视为首次运行，无历史快照可还原"
        Set-GhEnv "SNAPSHOT_STATUS=EMPTY"
        return
    }

    $mf = $null
    try { $mf = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Warn "manifest.json 解析失败：$_"; Set-GhEnv "SNAPSHOT_STATUS=FAILED"; return }

    if ($mf.rdpUser) { $RdpUser = $mf.rdpUser }     # 以快照记录的用户名为准
    Say ("快照时间: {0} | 主机: {1} | 用户: {2} | 文件 {3} 个" -f $mf.createdLocal, $mf.hostname, $RdpUser, $mf.files.totalFiles)

    $problems = New-Object System.Collections.Generic.List[string]
    $restored = 0

    # ---------- 1. 机器级文件（排除 C:\Users\<RdpUser>\... ，那部分交给登录任务） ----------
    $userPrefix = ("C\Users\" + $RdpUser).ToLower()
    if ($doFiles) {
        foreach ($e in @($mf.files.entries)) {
            $rel = [string]$e.mirror
            if ([string]::IsNullOrWhiteSpace($rel)) { continue }
            if ($rel.ToLower().StartsWith($userPrefix)) { continue }   # 个人目录 → 留给 user 作用域

            $src = Join-Path (Join-Path $Stage "files") $rel
            $dst = Get-AbsFromMirror -Rel $rel
            $code = Invoke-RobocopyRestore -Src $src -Dst $dst
            if ($code -ge 8) { $problems.Add("file:$rel"); Warn "还原失败（robocopy $code）：$rel" }
            else { $restored++; Say "  还原 $rel  ->  $dst" }
        }
    } else { Say "  文件还原已关闭（restore.files=false）" }

    # ---------- 2. 机器级注册表 ----------
    if ($doRegistry) {
        $regDir = Join-Path $Stage "registry\machine"
        if (Test-Path -LiteralPath $regDir) {
            foreach ($f in @(Get-ChildItem -LiteralPath $regDir -Filter *.reg -File -ErrorAction SilentlyContinue)) {
                & reg.exe import "$($f.FullName)" 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { Say "  导入注册表 $($f.Name)" }
                else { Warn "注册表导入失败：$($f.Name)"; $problems.Add("reg:$($f.Name)") }
            }
        }
    } else { Say "  注册表还原已关闭（restore.registry=false）" }

    # ---------- 3. 系统设置（时区 / 电源 / 防火墙 / Defender 排除） ----------
    if ($doSystem) {
        $sysFile = Join-Path $Stage "system\system.json"
        if (Test-Path -LiteralPath $sysFile) {
            $sys = $null
            try { $sys = Get-Content -LiteralPath $sysFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }

            if ($sys -and $sys.timezoneId) {
                try { Set-TimeZone -Id $sys.timezoneId -ErrorAction Stop; Say "  时区 -> $($sys.timezoneId)" }
                catch { Warn "时区设置失败：$($sys.timezoneId)（$_）"; $problems.Add("timezone") }
            }
            if ($sys -and $sys.powerPlan) {
                $g = [regex]::Match([string]$sys.powerPlan, '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
                if ($g.Success) {
                    & powercfg.exe /setactive $g.Groups[1].Value 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) { Say "  电源方案 -> $($g.Groups[1].Value)" }
                    else { Warn "电源方案设置失败（该方案可能在全新镜像中不存在）" }
                }
            }
            # 防火墙规则（快照里导出的是 .wfw）
            if ($sys -and $sys.firewallExport) {
                $fwFile = Join-Path $Stage (([string]$sys.firewallExport) -replace '/', '\')
                if (Test-Path -LiteralPath $fwFile) {
                    & netsh.exe advfirewall import "$fwFile" 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) { Say "  防火墙规则已导入" }
                    else { Warn "防火墙规则导入失败（可忽略）"; $problems.Add("firewall") }
                }
            }
            # Defender 排除项
            if ($sys -and $sys.defenderExclusionPath) {
                try {
                    $exPaths = @($sys.defenderExclusionPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                    if ($exPaths.Count -gt 0) {
                        Add-MpPreference -ExclusionPath $exPaths -ErrorAction SilentlyContinue
                        Say ("  Defender 排除路径已恢复：{0} 个" -f $exPaths.Count)
                    }
                    $exProcs = @($sys.defenderExclusionProcess) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                    if ($exProcs.Count -gt 0) { Add-MpPreference -ExclusionProcess $exProcs -ErrorAction SilentlyContinue }
                } catch { Warn "Defender 排除项恢复失败（可忽略）：$_" }
            }
        }
    } else { Say "  系统设置还原已关闭（restore.system=false）" }

    # ---------- 3b. 关闭 Windows 防火墙（本项目要求）----------
    # 注意顺序：快照里的 system/firewall.wfw 若被导入，会**整策略覆盖**把防火墙改回开启，
    # 所以这里在系统设置还原之后**无条件**再关一次（即使有人把 system.firewall 改回 true 也安全）。
    try {
        Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled False -ErrorAction Stop
        Say "  防火墙已关闭（Domain / Private / Public）"
    } catch { Warn "关闭防火墙失败（可忽略）：$_" }

    # ---------- 4. 公共桌面快捷方式 ----------
    if ($doShortcuts) {
        $pubSc = Join-Path $Stage "shortcuts\public-desktop"
        if (Test-Path -LiteralPath $pubSc) {
            $code = Invoke-RobocopyRestore -Src $pubSc -Dst "$env:PUBLIC\Desktop"
            if ($code -lt 8) { Say "  公共桌面快捷方式已还原" }
        }
    } else { Say "  快捷方式还原已关闭（restore.shortcuts=false）" }

    # ---------- 4b. 可移动程序（机器级：只还原「不在用户目录下」的） ----------
    $pmPath = Join-Path $Stage "apps\portable.json"
    if (Test-Path -LiteralPath $pmPath) {
        if (Get-Command Restore-PortableApps -ErrorAction SilentlyContinue) {
            $pr = Restore-PortableApps -ManifestPath $pmPath -UserPrefix ("C:\Users\" + $RdpUser) -InvertScope
            if ($pr.skipped) {
                Say "  可移动程序清单不可用，跳过"
            } else {
                Say ("  可移动程序（机器级）已还原：{0} 个" -f $pr.restored)
                foreach ($pb in @($pr.problems)) { $problems.Add("portable:$pb") }
            }
        } else { Warn "未加载 portable-lib.ps1，跳可移动程序还原" }
    }

    # ---------- 4c. 安装型程序（机器级：只还原「不在用户目录下」的） ----------
    if ($doPrograms) {
        if (Get-Command Restore-Programs -ErrorAction SilentlyContinue) {
            $pgEntries = @(Get-SnapshotPrograms -Stage $Stage)
            if ($pgEntries.Count -gt 0) {
                $pgRes = Restore-Programs -Entries $pgEntries -Stage $Stage -ProgramsRoot $ProgramsRoot `
                            -PreferJunction:$preferJunction -UserPrefix ("C:\Users\" + $RdpUser) -InvertScope `
                            -ExcludePaths $programsExclude
                Say ("  安装型程序（机器级）已还原：{0} 个（{1} 个 junction 指向 D 盘）" -f $pgRes.restored, $pgRes.junctioned)
                foreach ($pb in @($pgRes.problems)) { $problems.Add("program:$pb") }
            }
        } else { Warn "未加载 programs-lib.ps1，跳过安装型程序还原" }
    } else { Say "  安装型程序还原已关闭（programs.enabled=false）" }

    # ---------- 4d. 个人配置预还原（开机即还原，不依赖首次登录任务）----------
    # 做法：先用 Start-Process -Credential 强制 Windows 创建并注册该用户的配置文件
    # （.NET 会带 LOGON_WITH_PROFILE，即 LoadUserProfile），再 reg load 它的 NTUSER.DAT
    # 导入 HKCU，最后 robocopy 个人文件（无 /PURGE）。失败则交给登录任务兜底。
    $userHome    = ("C:\Users\" + $RdpUser)
    $userPreOk   = $false
    if ($doFiles -or $doRegistry) {
        try {
            if (-not [string]::IsNullOrWhiteSpace($env:RDP_PASSWORD)) {
                $ssPw = New-Object System.Security.SecureString
                foreach ($ch in $env:RDP_PASSWORD.ToCharArray()) { $ssPw.AppendChar($ch) }
                $ssPw.MakeReadOnly()
                $credU = New-Object System.Management.Automation.PSCredential($RdpUser, $ssPw)
                Start-Process -FilePath "cmd.exe" -ArgumentList "/c exit" -Credential $credU `
                    -Wait -WindowStyle Hidden -ErrorAction Stop
                Start-Sleep -Seconds 2
            } else { Warn "  缺少 RDP_PASSWORD，无法预创建用户配置文件" }

            $ntuser = Join-Path $userHome "NTUSER.DAT"
            if (Test-Path -LiteralPath $ntuser) {
                Say "  用户配置文件已创建并注册：$userHome"

                # ① 导入 HKCU
                #    分两种情况（「连接信息提前打印」之后，用户常常已经登录了）：
                #      a) hive 已被 Windows 加载（用户已登录）→ 直接写它的 hive，**绝不 load / 绝不 unload**
                #         （unload 用户正在用的 hive 会让他的会话直接崩）
                #      b) hive 未加载 → 走原路径：reg load 成 HKU\_Restore，写完 unload
                #
                #    ⚠️ 两个形式别混用（实测教训）：
                #      · $hiveRoot    'HKU\...'         → 命令行 reg.exe add/query/delete
                #      · $hiveRegRoot 'HKEY_USERS\...'  → **.reg 文件正文**；
                #        reg import 不认 'HKU\' 前缀（exit=1 且键根本没写进去），必须用全名
                if ($doRegistry) {
                    $regDirU = Join-Path $Stage "registry\user"

                    $hiveRoot    = $null
                    $hiveRegRoot = $null
                    $hiveLoaded  = $false       # $true = 用户自己的 hive，用完不能 unload
                    if ($script:HasUserHiveLib -and (Get-Command Get-UserHiveRoot -ErrorAction SilentlyContinue)) {
                        $hr = Get-UserHiveRoot -RdpUser $RdpUser
                        if ($hr.loaded) {
                            $hiveRoot    = [string]$hr.root
                            $hiveRegRoot = [string]$hr.regRoot
                            $hiveLoaded  = $true
                            Say ("  用户已登录，直接写其 hive：{0}" -f $hiveRoot)
                        }
                    }

                    if (-not $hiveLoaded) {
                        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
                        & reg.exe load "HKU\_Restore" "$ntuser" 2>&1 | Out-Null
                        if ($LASTEXITCODE -eq 0) {
                            $hiveRoot    = "HKU\_Restore"
                            $hiveRegRoot = "HKEY_USERS\_Restore"
                        } else { Warn "  NTUSER.DAT 加载失败（将交给登录任务）" }
                    }

                    if ($hiveRoot -and $hiveRegRoot) {
                        $nU = 0; $nUFail = 0
                        foreach ($f in @(Get-ChildItem -LiteralPath $regDirU -Filter *.reg -File -ErrorAction SilentlyContinue)) {
                            try {
                                $txt = Get-Content -LiteralPath $f.FullName -Raw -Encoding Unicode
                                $txt = $txt.Replace(("HKEY_USERS\" + $UserHiveToken), $hiveRegRoot)
                                $tmpR = Join-Path $env:TEMP ("ureg_" + [guid]::NewGuid().ToString('N') + ".reg")
                                $txt | Out-File -LiteralPath $tmpR -Encoding Unicode -Force
                                & reg.exe import "$tmpR" 2>&1 | Out-Null
                                if ($LASTEXITCODE -eq 0) { $nU++ } else { $nUFail++ }
                                Remove-Item -LiteralPath $tmpR -Force -ErrorAction SilentlyContinue
                            } catch { $nUFail++ }
                        }
                        if (-not $hiveLoaded) {
                            [gc]::Collect(); [gc]::WaitForPendingFinalizers()
                            & reg.exe unload "HKU\_Restore" 2>&1 | Out-Null
                        }
                        Say ("  个人 HKCU 已导入：{0} 个键文件（{1}）" -f $nU, $(if ($hiveLoaded) { "写入已加载 hive" } else { "临时 load/unload" }))
                        # 不再静默：导入失败必须可见（曾因前缀写错导致整批静默失败）
                        if ($nUFail -gt 0) {
                            Warn ("  个人 HKCU 有 {0} 个键文件导入失败（检查 .reg 前缀是否 HKEY_USERS\ 全名）" -f $nUFail)
                            $problems.Add("user-hkcu-import")
                        }
                    }
                }

                # ② 还原个人文件（无 /PURGE）+ 个人快捷方式
                if ($doFiles) {
                    $uPrefixMirror = ("C\Users\" + $RdpUser).ToLower()
                    $nF = 0
                    foreach ($e in @($mf.files.entries)) {
                        $relU = [string]$e.mirror
                        if ([string]::IsNullOrWhiteSpace($relU)) { continue }
                        if (-not $relU.ToLower().StartsWith($uPrefixMirror)) { continue }
                        $srcU = Join-Path (Join-Path $Stage "files") $relU
                        if (-not (Test-Path -LiteralPath $srcU)) { continue }
                        $dstU = Get-AbsFromMirror -Rel $relU
                        $codeU = Invoke-RobocopyRestore -Src $srcU -Dst $dstU
                        if ($codeU -ge 8) { $problems.Add("user-pre:$relU"); Warn "  预还原失败：$relU" }
                        else { $nF++; Say "  预还原 $relU" }
                    }
                    foreach ($pairU in @(
                        @{ src = "shortcuts\user-desktop";   dst = (Join-Path $userHome "Desktop") },
                        @{ src = "shortcuts\user-startmenu"; dst = (Join-Path $userHome "AppData\Roaming\Microsoft\Windows\Start Menu") }
                    )) {
                        $sU = Join-Path $Stage $pairU.src
                        if (Test-Path -LiteralPath $sU) {
                            $codeU2 = Invoke-RobocopyRestore -Src $sU -Dst $pairU.dst
                            if ($codeU2 -lt 8) { Say "  预还原快捷方式 -> $($pairU.dst)" }
                        }
                    }
                    Say ("  个人文件预还原：{0} 个目录" -f $nF)
                }

                # ③ 属主交回该用户
                try {
                    & icacls.exe "$userHome" /setowner "$RdpUser" /T /C /Q 2>&1 | Out-Null
                    & icacls.exe "$userHome" /grant "$($RdpUser):(OI)(CI)F" /T /C /Q 2>&1 | Out-Null
                } catch { }
                $userPreOk = $true
            } else {
                Warn "  用户配置文件未创建成功（将交给登录任务）"
            }
        } catch { Warn "开机预还原个人配置失败（将交给登录任务）：$_" }
    }
    Set-GhEnv ("SNAPSHOT_USER_PRERESTORE=" + $(if ($userPreOk) { "OK" } else { "SKIPPED" }))

    # ---------- 4e. 快捷方式校验与修复（必须在程序还原之后）----------
    # 为什么必须在这里：4b/4c 还原程序时会建 junction 让「原安装路径」重新可用；
    # 若在此之前校验，会把好链误判为死链。修不好的移入「_失效快捷方式」文件夹（非破坏）。
    $scCfg        = Get-Cfg $cfg 'shortcuts' $null
    $doScValidate = [bool](Get-Cfg $scCfg 'validateOnRestore' $true)
    if ($doScValidate) {
        if (Get-Command Repair-Shortcuts -ErrorAction SilentlyContinue) {
            $scParkFolder = [string](Get-Cfg $scCfg 'parkFolder' '_失效快捷方式')
            if ([string]::IsNullOrWhiteSpace($scParkFolder)) { $scParkFolder = '_失效快捷方式' }
            $scParkBroken = [bool](Get-Cfg $scCfg 'parkBroken' $true)
            $scDirsToCheck = New-Object System.Collections.Generic.List[string]
            $scDirsToCheck.Add("$env:PUBLIC\Desktop")
            if ([bool](Get-Cfg $scCfg 'machineStartMenu' $false)) { $scDirsToCheck.Add("$env:ProgramData\Microsoft\Windows\Start Menu") }
            try {
                $scRes = Repair-Shortcuts -Dirs $scDirsToCheck.ToArray() `
                            -ProgramsManifestPath (Join-Path $Stage "programs\programs.json") `
                            -ParkFolder $scParkFolder -ParkBroken:$scParkBroken
                Say ("  快捷方式校验（公共桌面）：检查 {0} / 正常 {1} / 修复 {2} / 移入失效 {3} / 跳过 {4}" -f `
                     $scRes.checked, $scRes.ok, $scRes.repaired, $scRes.parked, $scRes.skipped)
                Set-GhEnv ("SNAPSHOT_SC_CHECKED="  + $scRes.checked)
                Set-GhEnv ("SNAPSHOT_SC_REPAIRED=" + $scRes.repaired)
                Set-GhEnv ("SNAPSHOT_SC_PARKED="   + $scRes.parked)
            } catch { Warn "  快捷方式校验失败（可忽略）：$_" }
        } else { Warn "  未加载 programs-lib.ps1，跳过快捷方式校验" }
    } else { Say "  快捷方式校验已关闭（shortcuts.validateOnRestore=false）" }

    # ---------- 5. 注册「首次登录还原个人配置」计划任务 ----------
    if (-not $NoTask) {
        try {
            $toolsDir  = Join-Path $Stage "_tools"
            $userScript = Join-Path $toolsDir "restore-snapshot.ps1"
            if (-not (Test-Path -LiteralPath $userScript)) {
                # 兜底：把当前脚本自身复制过去
                Copy-Item -LiteralPath $PSCommandPath -Destination $userScript -Force -ErrorAction SilentlyContinue
            }
            $cfgSrc = Join-Path $toolsDir "snapshot-config.json"
            if (-not (Test-Path -LiteralPath $cfgSrc) -and (Test-Path -LiteralPath $ConfigPath)) {
                Copy-Item -LiteralPath $ConfigPath -Destination $cfgSrc -Force -ErrorAction SilentlyContinue
            }
            # 共享库也要在 _tools 里，否则登录任务跑的 user 作用域会因缺库而静默降级
            foreach ($lib in @("programs-lib.ps1", "portable-lib.ps1", "userhive-lib.ps1")) {
                $libDst = Join-Path $toolsDir $lib
                if (-not (Test-Path -LiteralPath $libDst)) {
                    $libSrc = Join-Path $PSScriptRoot $lib
                    if (Test-Path -LiteralPath $libSrc) {
                        Copy-Item -LiteralPath $libSrc -Destination $libDst -Force -ErrorAction SilentlyContinue
                    }
                }
            }

            $psExe = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
            if (-not $psExe) { $psExe = (Get-Command powershell.exe -ErrorAction Stop).Source }

            $argStr = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Scope user -RdpUser "{1}" -Stage "{2}"' -f $userScript, $RdpUser, $Stage
            $action    = New-ScheduledTaskAction -Execute $psExe -Argument $argStr
            $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $RdpUser
            $principal = New-ScheduledTaskPrincipal -UserId $RdpUser -LogonType Interactive -RunLevel Highest
            $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                            -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -StartWhenAvailable
            Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
                -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
            Say "已注册登录还原任务：$TaskName（$RdpUser 首次登录时执行）"

            # 用户**已经登录**时，「登录时触发」不会再发生 —— 立刻手动触发一次。
            # 任务以该用户 Interactive 身份运行，用的是他自己的 HKCU（不需要 reg load），
            # 跑完会 Unregister-ScheduledTask 自注销，所以不会重复执行。
            $alreadyLoggedIn = $false
            if ($script:HasUserHiveLib -and (Get-Command Get-UserHiveRoot -ErrorAction SilentlyContinue)) {
                $hrTask = Get-UserHiveRoot -RdpUser $RdpUser
                $alreadyLoggedIn = [bool]$hrTask.loaded
            }
            if ($alreadyLoggedIn) {
                try {
                    Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
                    Say "  用户已登录 → 已立即触发用户级还原任务（不等下次登录）"
                    Set-GhEnv "SNAPSHOT_USER_TASK_RUN=TRIGGERED"
                } catch {
                    Warn "  用户已登录但触发还原任务失败：$_（个人配置可能不完整）"
                    $problems.Add("logon-task-run")
                    Set-GhEnv "SNAPSHOT_USER_TASK_RUN=FAILED"
                }
            } else {
                Set-GhEnv "SNAPSHOT_USER_TASK_RUN=WAIT_LOGON"
            }
        } catch {
            Warn "注册登录还原任务失败：$_（个人配置将无法自动还原）"
            $problems.Add("logon-task")
        }
    }

    $status = if ($problems.Count -eq 0) { "OK" } else { "PARTIAL" }
    Say ("机器级还原完成：{0} 个目录 | 状态 {1}" -f $restored, $status)
    Set-GhEnv ("SNAPSHOT_STATUS=" + $status)
    Set-GhEnv ("SNAPSHOT_RESTORED_DIRS=" + $restored)
    if ($problems.Count -gt 0) { Set-GhEnv ("SNAPSHOT_PROBLEMS=" + ($problems -join ',')) }
}

# ================================================================ user 作用域

function Import-UserRegFile {
    param([string]$RegFile)
    $txt = Get-Content -LiteralPath $RegFile -Raw -Encoding Unicode
    if (-not $txt) { return $false }
    # 用户已登录：HKCU 即其 hive，把占位符换成 HKEY_CURRENT_USER 直接导入
    $txt = $txt.Replace(("HKEY_USERS\" + $UserHiveToken), "HKEY_CURRENT_USER")
    $tmp = Join-Path $env:TEMP ("snapreg_" + [guid]::NewGuid().ToString("N") + ".reg")
    $txt | Out-File -LiteralPath $tmp -Encoding Unicode -Force
    & reg.exe import "$tmp" 2>&1 | Out-Null
    $ok = ($LASTEXITCODE -eq 0)
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    return $ok
}

function Invoke-UserRestore {
    param([string]$Stage, [string]$RdpUser)

    $manifestPath = Join-Path $Stage "manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) { Say "无快照，跳过个人配置还原"; return }
    try { $mf = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Warn "manifest 解析失败"; return }
    if ($mf.rdpUser) { $RdpUser = $mf.rdpUser }

    Say "以 $env:USERNAME 身份还原个人配置（快照用户 $RdpUser）"
    $problems = New-Object System.Collections.Generic.List[string]
    $restored = 0

    # ---------- 1. 个人目录文件 ----------
    $userPrefix = ("C\Users\" + $RdpUser).ToLower()
    if ($doFiles) {
        foreach ($e in @($mf.files.entries)) {
            $rel = [string]$e.mirror
            if ([string]::IsNullOrWhiteSpace($rel)) { continue }
            if (-not $rel.ToLower().StartsWith($userPrefix)) { continue }

            $src = Join-Path (Join-Path $Stage "files") $rel
            $dst = Get-AbsFromMirror -Rel $rel
            $code = Invoke-RobocopyRestore -Src $src -Dst $dst
            if ($code -ge 8) { $problems.Add("file:$rel"); Warn "还原失败：$rel" }
            else { $restored++; Say "  还原 $rel" }
        }
    } else { Say "  文件还原已关闭（restore.files=false）" }

    # ---------- 2. HKCU 注册表 ----------
    if ($doRegistry) {
        $regDir = Join-Path $Stage "registry\user"
        if (Test-Path -LiteralPath $regDir) {
            foreach ($f in @(Get-ChildItem -LiteralPath $regDir -Filter *.reg -File -ErrorAction SilentlyContinue)) {
                if (Import-UserRegFile -RegFile $f.FullName) { Say "  导入 HKCU 注册表 $($f.Name)" }
                else { Warn "HKCU 导入失败：$($f.Name)"; $problems.Add("reg:$($f.Name)") }
            }
        }
    } else { Say "  HKCU 还原已关闭（restore.registry=false）" }

    # ---------- 3. 个人快捷方式 ----------
    if ($doShortcuts) {
        foreach ($pair in @(
            @{ src = "shortcuts\user-desktop";    dst = (Join-Path $env:USERPROFILE "Desktop") },
            @{ src = "shortcuts\user-startmenu";  dst = (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu") }
        )) {
            $s = Join-Path $Stage $pair.src
            if (Test-Path -LiteralPath $s) {
                $code = Invoke-RobocopyRestore -Src $s -Dst $pair.dst
                if ($code -lt 8) { Say "  快捷方式已还原 -> $($pair.dst)" }
            }
        }
    } else { Say "  快捷方式还原已关闭（restore.shortcuts=false）" }

    # ---------- 3b. 可移动程序（用户级：只还原「在用户目录下」的） ----------
    $pmPath = Join-Path $Stage "apps\portable.json"
    if (Test-Path -LiteralPath $pmPath) {
        if (Get-Command Restore-PortableApps -ErrorAction SilentlyContinue) {
            $pr = Restore-PortableApps -ManifestPath $pmPath -UserPrefix $env:USERPROFILE
            if (-not $pr.skipped) {
                Say ("  可移动程序（用户级）已还原：{0} 个" -f $pr.restored)
                foreach ($pb in @($pr.problems)) { $problems.Add("portable:$pb") }
            }
        }
    }

    # ---------- 3c. 安装型程序（用户级：只还原「在用户目录下」的） ----------
    if ($doPrograms) {
        if (Get-Command Restore-Programs -ErrorAction SilentlyContinue) {
            $pgEntries = @(Get-SnapshotPrograms -Stage $Stage)
            if ($pgEntries.Count -gt 0) {
                $pgRes = Restore-Programs -Entries $pgEntries -Stage $Stage -ProgramsRoot $ProgramsRoot `
                            -PreferJunction:$preferJunction -UserPrefix $env:USERPROFILE `
                            -ExcludePaths $programsExclude
                Say ("  安装型程序（用户级）已还原：{0} 个（{1} 个 junction）" -f $pgRes.restored, $pgRes.junctioned)
                foreach ($pb in @($pgRes.problems)) { $problems.Add("program:$pb") }
            }
        }
    }

    # ---------- 3d. 快捷方式校验与修复（用户级：桌面 + 开始菜单；必须在程序还原之后）----------
    $scCfgU        = Get-Cfg $cfg 'shortcuts' $null
    $doScValidateU = [bool](Get-Cfg $scCfgU 'validateOnRestore' $true)
    if ($doScValidateU) {
        if (Get-Command Repair-Shortcuts -ErrorAction SilentlyContinue) {
            $scParkFolderU = [string](Get-Cfg $scCfgU 'parkFolder' '_失效快捷方式')
            if ([string]::IsNullOrWhiteSpace($scParkFolderU)) { $scParkFolderU = '_失效快捷方式' }
            $scParkBrokenU = [bool](Get-Cfg $scCfgU 'parkBroken' $true)
            $scDirsU = New-Object System.Collections.Generic.List[string]
            $scDirsU.Add((Join-Path $env:USERPROFILE "Desktop"))
            $scDirsU.Add((Join-Path $env:APPDATA "Microsoft\Windows\Start Menu"))
            try {
                $scResU = Repair-Shortcuts -Dirs $scDirsU.ToArray() `
                            -ProgramsManifestPath (Join-Path $Stage "programs\programs.json") `
                            -ParkFolder $scParkFolderU -ParkBroken:$scParkBrokenU `
                            -LogPath (Join-Path $SysDir "_state\user-restore.log")
                Say ("  快捷方式校验（个人）：检查 {0} / 正常 {1} / 修复 {2} / 移入失效 {3} / 跳过 {4}" -f `
                     $scResU.checked, $scResU.ok, $scResU.repaired, $scResU.parked, $scResU.skipped)
            } catch { Warn "  快捷方式校验失败（可忽略）：$_" }
        }
    }

    # ---------- 4. .ssh 私钥权限收紧 ----------
    $sshDir = Join-Path $env:USERPROFILE ".ssh"
    if (Test-Path -LiteralPath $sshDir) {
        try {
            & icacls.exe "$sshDir" /inheritance:r /grant:r "$($env:USERNAME):(OI)(CI)F" 2>&1 | Out-Null
            Say "  .ssh 权限已收紧"
        } catch { Warn ".ssh 权限设置失败（$_）" }
    }

    # ---------- 5. 刷新壁纸/外观 ----------
    try { & rundll32.exe user32.dll,UpdatePerUserSystemParameters 2>&1 | Out-Null } catch { }

    $status = if ($problems.Count -eq 0) { "OK" } else { "PARTIAL" }
    Say ("个人配置还原完成：{0} 个目录 | 状态 {1}" -f $restored, $status)

    # ---------- 5b. 日志落盘（用户会话里看不到控制台，便于事后排查）----------
    try {
        $logDir = Join-Path $SysDir "_state"
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        ("[{0}] status={1} restored={2} problems={3}" -f (Get-Date).ToString('o'), $status, $restored, (($problems | Select-Object -First 20) -join ',')) |
            Out-File -LiteralPath (Join-Path $logDir "user-restore.log") -Append -Encoding utf8
    } catch { }

    # ---------- 6. 只在成功时自注销；失败则保留任务，下次登录自动重试 ----------
    if ($problems.Count -eq 0) {
        try {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
            Say "已注销登录还原任务（仅执行一次）"
        } catch { Warn "注销登录任务失败：$_" }
        try {
            $mkOk = Join-Path $env:PUBLIC "Desktop\_CloudRDP_还原失败.txt"
            if (Test-Path -LiteralPath $mkOk) { Remove-Item -LiteralPath $mkOk -Force -ErrorAction SilentlyContinue }
        } catch { }
    } else {
        Warn ("个人配置还原有 {0} 项问题 —— 保留登录任务，下次登录自动重试" -f $problems.Count)
        try {
            $mkBad = Join-Path $env:PUBLIC "Desktop\_CloudRDP_还原失败.txt"
            $body = "个人配置还原失败`r`n时间: {0}`r`n问题:`r`n{1}`r`n`r`n日志: {2}\_state\user-restore.log`r`n手动重试:`r`n  {2}\_snapshot\_tools\restore-snapshot.ps1 -Scope user" -f `
                (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'),
                (($problems | ForEach-Object { "  - $_" }) -join "`r`n"),
                $SysDir
            $body | Out-File -LiteralPath $mkBad -Encoding UTF8
        } catch { }
    }
}

# ================================================================ 入口

if ($Scope -eq "machine") {
    if ($Pull) {
        $r = Invoke-PullSnapshot -Remote $Remote -Stage $Stage
        if ($r -eq "EMPTY") {
            Say "远端尚无快照（首次运行正常）"
            Set-GhEnv "SNAPSHOT_STATUS=EMPTY"
            exit 0
        }
        if ($r -eq "FAILED" -or $r -eq "NO_RCLONE") {
            Warn "快照拉取失败：$r —— 本次不做整机还原（RDP 仍可用，但环境是全新的）"
            Set-GhEnv "SNAPSHOT_STATUS=FAILED"
            exit 0
        }
    }
    Invoke-MachineRestore -Stage $Stage -RdpUser $RdpUser -ConfigPath $ConfigPath -NoTask:$NoTask
}
else {
    Invoke-UserRestore -Stage $Stage -RdpUser $RdpUser
}

exit 0
