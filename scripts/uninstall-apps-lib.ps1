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

        # 静默参数补齐
        $low = ($sp.exe + ' ' + $sp.args).ToLower()
        if ($low -match 'msiexec') {
            $args2 = $sp.args
            if ($args2 -match '(?i)/i\s*(\{[^}]+\})') {
                $code = $Matches[1]
                $args2 = "/x $code"
            }
            if ($args2 -notmatch '(?i)/q') { $args2 += ' /qn' }
            if ($args2 -notmatch '(?i)/norestart') { $args2 += ' /norestart' }
            $argTail = $args2
        } elseif ($sp.exe -match '(?i)unins\d*\.exe') {
            $argTail = ($sp.args + ' /VERYSILENT /SUPPRESSMSGBOXES /NORESTART').Trim()
        } elseif ($sp.exe -match '(?i)(uninstall|uninst|unins)\.exe') {
            $argTail = ($sp.args + ' /S').Trim()
        } else {
            $argTail = $sp.args
        }

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
