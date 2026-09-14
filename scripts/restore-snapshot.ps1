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
    [string]$Stage      = $(if ($env:CLOUDRDP_SNAPSHOT_STAGE) { $env:CLOUDRDP_SNAPSHOT_STAGE } else { "C:\_snapshot" }),
    [string]$Remote     = $(if ($env:CLOUDRDP_REMOTE_BASE) { $env:CLOUDRDP_REMOTE_BASE + "/_snapshot" } else { "alist:/cloudrdp/AI文件库/_snapshot" }),
    [string]$ConfigPath = (Join-Path $PSScriptRoot "snapshot-config.json"),
    [string]$RdpUser    = $(if ($env:RDP_USERNAME) { $env:RDP_USERNAME } else { "NvdAdmin" }),
    [switch]$Pull,
    [switch]$NoTask
)

$ErrorActionPreference = "Continue"
$RcloneExe     = "C:\rclone\rclone.exe"
$UserHiveToken = "__RDPUSER__"
$TaskName      = "CloudRDP-RestoreUser"
$PortableDir   = $(if ($env:CLOUDRDP_PORTABLE_DIR) { $env:CLOUDRDP_PORTABLE_DIR } else { "D:\a\cloud-rdp\_portable" })

# 可移动程序共享库（识别 / 搬运 / 还原）
$portableLib = Join-Path $PSScriptRoot "portable-lib.ps1"
if (Test-Path -LiteralPath $portableLib) { . $portableLib }
else { Write-Warning "[restore] 未找到 portable-lib.ps1，可移动程序还原不可用" }

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

    # ---------- 6. 自注销，避免每次登录都覆盖用户改动 ----------
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Say "已注销登录还原任务（仅执行一次）"
    } catch { Warn "注销登录任务失败：$_" }
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
