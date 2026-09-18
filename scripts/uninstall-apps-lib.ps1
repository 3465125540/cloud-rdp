<#
.SYNOPSIS
  程序卸载库：瘦身阶段「真卸载」明确不要的程序。

.DESCRIPTION
  为什么需要它（而不是只删目录）：
    · 只删目录会留下 ARP 卸载项、Windows 服务、ProgramData 数据目录 —— 下次开机
      仍占空间、仍会被快照当成「已装程序」；MSI 产品的缓存包也还留在 C:\Windows\Installer。
    · 真卸载（winget / msiexec / Inno）能一次性清干净，之后删目录只当兜底。

  三级降级（每一级都有超时保护，卸载器弹窗卡死不会拖死开机）：
    ① winget uninstall --id <id> -e --silent --disable-interactivity
    ② ARP 入口：QuietUninstallString → msiexec /x {产品码} /qn /norestart
              → Inno unins000.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
    ③ 目录兜底（由调用方用 Remove-BigTree 清理 paths[]）

  安全约束：
    · SystemComponent=1 的 ARP 条目一律跳过（系统组件，卸了会伤系统）
    · 只处理配置里显式列出的条目（blockedApps），不做任何模糊扫描
    · 全部 fail-soft：任何失败只记状态，永不抛异常、永不返回非 0

.NOTES
  使用方：slim-image.ps1（卸载）、reinstall-apps.ps1（过滤重装清单）、
          backup-snapshot.ps1（过滤 winget 导出 + 合并 excludePaths）
#>

# ---------------------------------------------------------------- 配置读取

# 读 snapshot-config.json 的 blockedApps.entries（归一化；enabled=false 返回空）
function Get-BlockedAppEntries {
    param([string]$ConfigPath)

    if ([string]::IsNullOrWhiteSpace($ConfigPath) -or -not (Test-Path -LiteralPath $ConfigPath)) { return @() }
    $cfg = $null
    try { $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return @() }

    $sec = $null
    try { $sec = $cfg.PSObject.Properties['blockedApps'].Value } catch { $sec = $null }
    if ($null -eq $sec) { return @() }
    if ($null -ne $sec.PSObject.Properties['enabled'] -and -not [bool]$sec.enabled) { return @() }

    $entries = @()
    if ($null -ne $sec.PSObject.Properties['entries']) { $entries = @($sec.entries) }
    if ($entries.Count -eq 0) { return @() }

    $out = New-Object System.Collections.Generic.List[object]
    foreach ($e in $entries) {
        if ($null -eq $e) { continue }
        $name = [string]$e.name
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($null -ne $e.PSObject.Properties['enabled'] -and -not [bool]$e.enabled) { continue }
        $paths = @()
        if ($null -ne $e.PSObject.Properties['paths']) { $paths = @($e.paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) }
        $svcs = @()
        if ($null -ne $e.PSObject.Properties['services']) { $svcs = @($e.services | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) }
        $procs = @()
        if ($null -ne $e.PSObject.Properties['processes']) { $procs = @($e.processes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) }
        $out.Add([pscustomobject]@{
            name     = $name
            match    = [string]$e.match
            wingetId = [string]$e.wingetId
            paths    = $paths
            services = $svcs
            processes= $procs
        })
    }
    return $out.ToArray()
}

# 判断某个 winget 包是否属于「不要的程序」（按 wingetId 精确 或 match 正则）
function Test-BlockedAppPackage {
    param(
        [string]$PackageIdentifier = '',
        [string]$PackageName = '',
        [object[]]$Entries = @()
    )
    foreach ($e in @($Entries)) {
        if ([string]::IsNullOrWhiteSpace($e)) { continue }
        if (-not [string]::IsNullOrWhiteSpace($e.wingetId) -and
            $PackageIdentifier -and
            $e.wingetId.Trim().ToLower() -eq $PackageIdentifier.Trim().ToLower()) { return $true }
        if (-not [string]::IsNullOrWhiteSpace($e.match)) {
            foreach ($s in @($PackageIdentifier, $PackageName)) {
                if ([string]::IsNullOrWhiteSpace($s)) { continue }
                try { if ($s -match $e.match) { return $true } } catch { }
            }
        }
    }
    return $false
}

# ---------------------------------------------------------------- ARP 扫描

# 扫 ARP（含 64/32 位与 HKCU），排除系统组件
function Get-UninstallEntries {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in $roots) {
        $items = @()
        try { $items = @(Get-ItemProperty -Path $r -ErrorAction SilentlyContinue) } catch { $items = @() }
        foreach ($it in $items) {
            if ($null -eq $it) { continue }
            $dn = [string]$it.DisplayName
            if ([string]::IsNullOrWhiteSpace($dn)) { continue }
            # 系统组件：卸了会伤系统，一律跳过
            $sc = $null
            try { $sc = $it.SystemComponent } catch { }
            if ($sc -eq 1) { continue }
            $out.Add([pscustomobject]@{
                DisplayName          = $dn
                DisplayVersion       = [string]$it.DisplayVersion
                Publisher            = [string]$it.Publisher
                InstallLocation      = [string]$it.InstallLocation
                UninstallString      = [string]$it.UninstallString
                QuietUninstallString = [string]$it.QuietUninstallString
                WindowsInstaller     = ($it.WindowsInstaller -eq 1)
                KeyName              = [string]$it.PSChildName
            })
        }
    }
    return $out.ToArray()
}

# 按 match 正则找 ARP 条目
function Find-UninstallTargets {
    param([object[]]$Entries = @(), [string]$Match = '')
    if ([string]::IsNullOrWhiteSpace($Match)) { return @() }
    $hit = @()
    foreach ($e in @($Entries)) {
        try { if ($e.DisplayName -match $Match) { $hit += $e } } catch { }
    }
    return $hit
}

# 从 UninstallString / 注册表键名里抠出 MSI 产品码 {GUID}
function Get-MsiProductCode {
    param([string]$UninstallString = '', [string]$KeyName = '')
    $m = [regex]::Match([string]$UninstallString, '\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}')
    if ($m.Success) { return $m.Value }
    if ($KeyName -match '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$') { return $KeyName }
    return ''
}

# ---------------------------------------------------------------- 进程执行

# 把命令行拆成 exe + 参数（处理带引号的 exe 路径）
function Split-CommandLine {
    param([string]$CmdLine = '')
    $t = ([string]$CmdLine).Trim()
    if ([string]::IsNullOrWhiteSpace($t)) { return @{ exe = ''; args = '' } }
    if ($t.StartsWith('"')) {
        $end = $t.IndexOf('"', 1)
        if ($end -gt 0) { return @{ exe = $t.Substring(1, $end - 1); args = $t.Substring($end + 1).Trim() } }
    }
    $sp = $t.IndexOf(' ')
    if ($sp -lt 0) { return @{ exe = $t; args = '' } }
    return @{ exe = $t.Substring(0, $sp); args = $t.Substring($sp + 1).Trim() }
}

# 按卸载器类型补齐静默参数（纯函数，便于单测）
#
# ⚠️ 这里的匹配范围是踩过坑的：
#   真机实测 Unity Hub 的卸载器是 "C:\Program Files\Unity Hub\Uninstall Unity Hub.exe"，
#   它「以 Uninstall 开头」但**不以 uninstall.exe 结尾**。旧正则
#   `(uninstall|uninst|unins)\.exe` 匹配不到 → 只传了 /allusers、没有静默参数 →
#   卸载器挂起到超时 → ARP 卸载键残留 → 用户看到「未安装成功」。
#   改成 `(uninstall|uninst|unins)[^\\]*\.exe`（文件名里可含空格）即可覆盖。
function Resolve-UninstallArgTail {
    # ⚠️ 参数名不能叫 $Args —— 那是 PowerShell 的**自动变量**（未绑定参数数组），
    #    声明成同名参数会导致值被吞掉（单测实测：-Args '/allusers' 进去变空串）。
    param([string]$Exe = '', [string]$ArgString = '')

    $exe = [string]$Exe
    $a   = [string]$ArgString
    $low = ($exe + ' ' + $a).ToLower()

    if ($low -match 'msiexec') {
        if ($a -match '(?i)/i\s*(\{[^}]+\})') { $a = '/x ' + $Matches[1] }
        if ($a -notmatch '(?i)/q')         { $a += ' /qn' }
        if ($a -notmatch '(?i)/norestart') { $a += ' /norestart' }
        return $a.Trim()
    }
    if ($exe -match '(?i)unins\d*\.exe') {
        return ($a + ' /VERYSILENT /SUPPRESSMSGBOXES /NORESTART').Trim()
    }
    if ($exe -match '(?i)(uninstall|uninst|unins)[^\\]*\.exe') {
        return ($a + ' /S').Trim()
    }
    return $a.Trim()
}

# 带超时执行（卸载器卡住就 kill，不让它拖死开机）
function Invoke-ProcessWithTimeout {
    param([string]$Exe = '', [string]$ArgString = '', [int]$TimeoutSec = 300)
    $res = [ordered]@{ rc = -1; timedOut = $false; err = '' }
    if ([string]::IsNullOrWhiteSpace($Exe)) { $res.rc = -3; $res.err = 'empty exe'; return $res }
    try {
        $p = Start-Process -FilePath $Exe -ArgumentList $ArgString -PassThru -NoNewWindow -ErrorAction Stop
        if ($null -eq $p) { $res.rc = -3; $res.err = 'no process'; return $res }
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill() } catch { }
            $res.timedOut = $true
            $res.rc = -2
        } else {
            $res.rc = $p.ExitCode
        }
    } catch {
        $res.rc = -3
        $res.err = $_.Exception.Message
    }
    return $res
}

# 停掉目标程序的服务与进程（best-effort）
function Stop-AppServices {
    param([string[]]$ServiceNames = @(), [string[]]$ProcessNames = @())
    foreach ($s in @($ServiceNames)) {
        try { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue } catch { }
    }
    foreach ($p in @($ProcessNames)) {
        try { Get-Process -Name $p -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch { }
    }
}

# ---------------------------------------------------------------- 卸载主流程

# 卸载单个 blockedApps 条目。返回 @{ name; ok; method; detail; dryRun; arpHits }
function Invoke-AppUninstall {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [object[]]$ArpEntries = @(),
        [int]$TimeoutSec = 300,
        [switch]$DryRun
    )

    $r = [ordered]@{ name = [string]$Entry.name; ok = $false; method = ''; detail = ''; dryRun = [bool]$DryRun; arpHits = @() }

    $hits = Find-UninstallTargets -Entries $ArpEntries -Match ([string]$Entry.match)
    $r.arpHits = @($hits | ForEach-Object { $_.DisplayName })

    if ($DryRun) {
        $r.method = 'dryrun'
        $r.detail = "wingetId=$(if ($Entry.wingetId) { $Entry.wingetId } else { '-' }) ; arp=$(if ($hits.Count -gt 0) { ($hits | ForEach-Object { $_.DisplayName }) -join ' | ' } else { '无' })"
        return $r
    }

    # 先停服务/进程，否则卸载器多半失败
    Stop-AppServices -ServiceNames @($Entry.services) -ProcessNames @($Entry.processes)

    # ---------- ① winget ----------
    if (-not [string]::IsNullOrWhiteSpace($Entry.wingetId)) {
        $rc = Invoke-ProcessWithTimeout -Exe 'winget.exe' -TimeoutSec $TimeoutSec `
            -ArgString ("uninstall --id {0} -e --silent --disable-interactivity --accept-source-agreements" -f $Entry.wingetId)
        if ($rc.rc -eq 0) {
            $r.ok = $true; $r.method = 'winget'; $r.detail = "winget uninstall $($Entry.wingetId) -> 0"
            return $r
        }
        $r.detail = "winget rc=$($rc.rc)$(if ($rc.timedOut) { ' (timeout)' })"
    }

    # ---------- ② ARP ----------
    foreach ($h in @($hits)) {
        $cmd = ''
        $argTail = ''
        if (-not [string]::IsNullOrWhiteSpace($h.QuietUninstallString)) {
            $cmd = $h.QuietUninstallString
        } elseif ($h.WindowsInstaller) {
            $code = Get-MsiProductCode -UninstallString $h.UninstallString -KeyName $h.KeyName
            if ($code) { $cmd = "msiexec.exe /x $code /qn /norestart" }
        } elseif (-not [string]::IsNullOrWhiteSpace($h.UninstallString)) {
            $cmd = $h.UninstallString
        }
        if ([string]::IsNullOrWhiteSpace($cmd)) { continue }

        $sp = Split-CommandLine -CmdLine $cmd
        if ([string]::IsNullOrWhiteSpace($sp.exe)) { continue }

        # 静默参数补齐（逻辑抽成纯函数，便于单测）
        $argTail = Resolve-UninstallArgTail -Exe $sp.exe -ArgString $sp.args

        $rc = Invoke-ProcessWithTimeout -Exe $sp.exe -ArgString $argTail -TimeoutSec $TimeoutSec
        # 0 = 成功；3010 / 1641 = 成功但需重启
        if ($rc.rc -eq 0 -or $rc.rc -eq 3010 -or $rc.rc -eq 1641) {
            $r.ok = $true
            $r.method = 'arp'
            $r.detail = ("$($h.DisplayName) -> rc=$($rc.rc)")
            return $r
        }
        $r.detail = ($r.detail + " ; arp $($h.DisplayName) rc=$($rc.rc)$(if ($rc.timedOut) { ' (timeout)' })").Trim(' ', ';')
    }

    if (-not $r.ok) {
        if ([string]::IsNullOrWhiteSpace($r.detail)) { $r.detail = '未找到卸载入口（交给目录兜底）' }
        $r.method = 'none'
    }
    return $r
}

# ============================================================================
#  残留清理（卸载器不管的部分）
# ============================================================================
#
#  真机实测（server-18，2026-09-18）：
#    · 8 个目标程序的**目录**都被删掉了，但
#      HKLM\SOFTWARE\...\Uninstall\Unity Technologies - Hub **还在** →
#      程序在「应用和功能」里依旧显示已安装 → 用户认为「未卸载成功」。
#      根因：Unity Hub 的卸载器是 "Uninstall Unity Hub.exe"（非 MSI、非 Inno），
#      旧代码没给它补静默参数 → 挂起到超时 → 卸载器没删自己的 ARP 键。
#    · 另有 2 个残留空目录：C:\Strawberry、C:\Program Files\Microsoft SDKs\Service Fabric
#      （内容被卸载器清了，目录本身没删掉）。
#
#  所以卸载之后要再补两刀：删 ARP 键 + 删残留目录。
# ============================================================================

# winget 是否可用（用于诊断：很多「卸载失败」其实是 winget 压根不在 PATH）
function Test-WingetAvailable {
    try {
        $w = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($w) { return [string]$w.Source }
    } catch { }
    foreach ($p in @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'),
        'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe')) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return ''
}

# 删除某个 blockedApp 残留的 ARP 卸载键（「应用和功能」里的条目）
#
# 为什么要删：只要这个键还在，Windows 就认为程序已安装 ——
#   ① 用户看到「未卸载成功」；② 备份侧会把它当已装程序；③ 还原后 winget 可能再装回来。
#
# .OUTPUTS
#   [pscustomobject]@{ candidates; removed; failed }
function Remove-BlockedAppArpKeys {
    param(
        $Entry,
        [object[]]$ArpEntries = @(),
        [switch]$DryRun,
        [scriptblock]$Log = $null
    )

    $say = { param($m) if ($Log) { try { & $Log $m } catch { } } }

    $removed = New-Object System.Collections.Generic.List[string]
    $failed  = New-Object System.Collections.Generic.List[string]

    $names = @()
    foreach ($h in @(Find-UninstallTargets -Entries $ArpEntries -Match ([string]$Entry.match))) {
        $kn = [string]$h.KeyName
        if (-not [string]::IsNullOrWhiteSpace($kn)) { $names += $kn }
    }
    $names = @($names | Select-Object -Unique)
    if ($names.Count -eq 0) {
        return [pscustomobject]@{ candidates = 0; removed = @(); failed = @() }
    }

    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    $cand = 0
    foreach ($kn in $names) {
        foreach ($rt in $roots) {
            $p = $rt + '\' + $kn
            if (-not (Test-Path -LiteralPath $p)) { continue }
            $cand++
            if ($DryRun) { $removed.Add($p); continue }
            try {
                Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
                if (Test-Path -LiteralPath $p) { $failed.Add($p) }
                else { $removed.Add($p); & $say ('已清除残留卸载项 ' + $p) }
            } catch {
                $failed.Add(($p + ' (' + $_.Exception.Message + ')'))
            }
        }
    }

    return [pscustomobject]@{ candidates = $cand; removed = $removed.ToArray(); failed = $failed.ToArray() }
}

# 删除某个 blockedApp 残留的目录（清内容 → 删目录本身 → 重试）
#
# 为什么要单独做：卸载器经常「清了内容但不删目录」，而 slim 的 targets 删除
# 在卸载之前执行（那时文件还在、被占用），所以卸载完成后必须再补一刀。
#
# .OUTPUTS
#   [pscustomobject]@{ removed; leftover; freedBytes }
function Remove-BlockedAppLeftoverDirs {
    param(
        $Entry,
        [switch]$DryRun,
        [scriptblock]$Log = $null,
        [int]$MaxRounds = 3
    )

    $say = { param($m) if ($Log) { try { & $Log $m } catch { } } }

    $removed  = New-Object System.Collections.Generic.List[string]
    $leftover = New-Object System.Collections.Generic.List[string]
    $freed    = [long]0

    foreach ($p in @($Entry.paths)) {
        if ([string]::IsNullOrWhiteSpace([string]$p)) { continue }
        $path = ([string]$p).TrimEnd('\')
        if (-not (Test-Path -LiteralPath $path)) { continue }

        if ($DryRun) { $removed.Add($path); continue }

        try {
            $sz = Get-ChildItem -LiteralPath $path -Recurse -Force -File -ErrorAction SilentlyContinue |
                  Measure-Object -Property Length -Sum
            if ($sz -and $sz.Sum) { $freed += [long]$sz.Sum }
        } catch { }

        for ($i = 1; $i -le [math]::Max(1, $MaxRounds); $i++) {
            if (-not (Test-Path -LiteralPath $path)) { break }

            # (1) 清空内容（robocopy /MIR 空目录），保留目录本身
            $empty = Join-Path $env:TEMP ('__crdp_empty_' + [guid]::NewGuid().ToString('N'))
            try {
                New-Item -ItemType Directory -Force -Path $empty | Out-Null
                & robocopy $empty $path /MIR /R:1 /W:1 /NFL /NDL /NJH /NJS /NP /XJ 2>&1 | Out-Null
            } catch { } finally {
                Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue
            }

            # (2) 删目录本身
            & cmd.exe /c rmdir /s /q "$path" 2>&1 | Out-Null
            if (Test-Path -LiteralPath $path) {
                try { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue } catch { }
            }
            if (-not (Test-Path -LiteralPath $path)) { break }
            Start-Sleep -Milliseconds 600
        }

        if (Test-Path -LiteralPath $path) {
            $leftover.Add($path)
            & $say ('残留目录仍删不掉：' + $path)
        } else {
            $removed.Add($path)
            & $say ('已清除残留目录 ' + $path)
        }
    }

    return [pscustomobject]@{ removed = $removed.ToArray(); leftover = $leftover.ToArray(); freedBytes = $freed }
}
