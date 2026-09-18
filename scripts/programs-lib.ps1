<#
.SYNOPSIS
  安装型程序（Program Files 类）的识别 / 备份 / 还原 —— 共享函数库。

.DESCRIPTION
  被 backup-snapshot.ps1 与 restore-snapshot.ps1 以 dot-source 方式加载，本身不执行动作。

  目标：让「关机前装好的程序」在下次开机后**照常能用**，同时**不让 C 盘变大**。

  · 备份：把程序安装目录镜像到 <Stage>\programs\<盘符>\<路径>，
          并**逐程序导出它的 Uninstall 注册表键** —— 这样还原后「应用和功能」认得它、
          winget 也会判定「已安装」从而跳过重装（避免装两份）。
  · 还原：程序实体落到 D 盘（CLOUDRDP_PROGRAMS_DIR），
          在原安装路径（如 C:\Program Files\Foo）建 **junction** 指过去
          → 原路径照常可用、快捷方式/注册表引用都不变，而 C 盘零增长。
          若关闭 junction 或原路径不在 C 盘，则直接还原到原路径。

  **只备份「用户装的」程序**，镜像自带的约 120GB 工具链绝不碰，靠三重保险：
    ① 增量判定：开机基线（镜像自带程序集合）里的 regPath 一律跳过
    ② 静态黑名单：imageBlockPaths（VS / Android SDK / hostedtoolcache / AzureCLI …）
    ③ 体积上限：单程序 + 总量

.NOTES
  函数前缀 Get-Program / Test-Program / Backup-Program / Restore-Program / New-Program / Convert-Program / Import-Program，
  避免与 portable-lib.ps1 / backup-snapshot.ps1 的同名工具函数冲突。
#>

# ---------------------------------------------------------------- 通用小工具

function Get-ProgramTreeBytes {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [long]0 }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
    if (-not $sum) { return [long]0 }
    return [long]$sum
}

# C:\Program Files\Foo -> C\Program Files\Foo
function Get-ProgramMirrorRel {
    param([string]$Abs)
    $a = $Abs.TrimEnd('\')
    $a = $a -replace '^([A-Za-z]):', '$1'
    return ($a -replace '^[\\/]+', '')
}

function Test-ProgramReparsePoint {
    param([string]$Path)
    try {
        $it = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return (($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    } catch { return $false }
}

# 若路径是 junction/symlink，返回它的真实目标；否则原样返回
function Get-ProgramRealPath {
    param([string]$Path)
    try {
        $it = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            $t = $null
            try { $t = $it.Target } catch { }
            if (-not $t) { try { $t = $it.LinkTarget } catch { } }
            if ($t) {
                $t = [string]($t | Select-Object -First 1)
                if ($t -and (Test-Path -LiteralPath $t)) { return $t }
            }
        }
    } catch { }
    return $Path
}

# PowerShell 注册表路径 -> reg.exe 可用的路径
# Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\... -> HKLM\SOFTWARE\...
function Convert-ProgramRegPath {
    param([string]$PSPath)
    if ([string]::IsNullOrWhiteSpace($PSPath)) { return "" }
    $p = $PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''
    $p = $p -replace '^HKEY_LOCAL_MACHINE', 'HKLM'
    $p = $p -replace '^HKEY_CURRENT_USER', 'HKCU'
    return $p
}

# ---------------------------------------------------------------- 识别

function Get-ProgramSystemRoots {
    # 这些目录里的东西永远不备份（系统自身 / 商店应用 / 共享组件）
    return @(
        'C:\Windows',
        'C:\Program Files\WindowsApps',
        'C:\Program Files\Windows Defender',
        'C:\Program Files\Common Files',
        'C:\Program Files (x86)\Common Files',
        'C:\ProgramData'
    )
}

function Get-ProgramImageBlockPaths {
    # GitHub Windows runner 镜像自带软件的位置 —— 备份它们纯浪费带宽（约 120GB）
    return @(
        'C:\tools',
        'C:\Android',
        'C:\azureCli',
        'C:\hostedtoolcache',
        'C:\Strawberry',
        'C:\Program Files\Microsoft Visual Studio',
        'C:\Program Files (x86)\Microsoft Visual Studio',
        'C:\Program Files\dotnet',
        'C:\Program Files (x86)\dotnet',
        'C:\Program Files\nodejs',
        'C:\Program Files\Git',
        'C:\Program Files\Git LFS',
        'C:\Program Files\Google',
        'C:\Program Files (x86)\Google',
        'C:\Program Files\Mozilla Firefox',
        'C:\Program Files\Microsoft SDKs',
        'C:\Program Files (x86)\Microsoft SDKs',
        'C:\Program Files\Windows Kits',
        'C:\Program Files (x86)\Windows Kits',
        'C:\Program Files\Microsoft SQL Server',
        'C:\Program Files\PowerShell',
        'C:\Program Files\Windows PowerShell',
        'C:\Program Files\Microsoft\Edge',
        'C:\Program Files (x86)\Microsoft\Edge',
        'C:\Program Files\Microsoft\EdgeWebView',
        'C:\Program Files (x86)\Microsoft\EdgeWebView',
        'C:\Program Files\Java',
        'C:\Program Files\Eclipse Adoptium',
        'C:\Program Files\Microsoft\jdk',
        'C:\Program Files\Amazon',
        'C:\Program Files\Microsoft Azure',
        'C:\Program Files\Azure',
        'C:\Program Files\Docker',
        'C:\Program Files\Mercurial',
        'C:\Program Files\CMake',
        'C:\Program Files\LLVM',
        'C:\Program Files\R',
        'C:\Program Files\Microsoft.NET',
        'C:\Program Files\Microsoft',
        'C:\Program Files (x86)\Microsoft',
        'C:\ProgramData\chocolatey'
    )
}

# 枚举 Uninstall 注册表，返回程序条目
#
# ⚠️ 为什么要 -ExtraHiveRoots（真机实测的坑）：
#   备份/基线扫描跑在 runneradmin 身份下，`HKCU:` 是 **runneradmin 的 hive**，
#   看不到 RDP 用户（a）的卸载项。于是「用户级安装」这一类程序
#   （程序体在 %LOCALAPPDATA%\<厂商>、卸载项在用户 HKCU）整类漏抓 ——
#   还原后桌面只剩图标、点开报「找不到目标」。
#   调用方先用 userhive-lib.ps1 的 Mount-RdpUserHive 拿到根（HKU\<SID> 或 HKU\__CRDP_USR），
#   再传进来即可。
function Get-InstalledPrograms {
    param(
        [string[]]$ExtraHiveRoots = @()
    )

    # 用户 hive 的 SID/加载名一律归一化，保证「基线」与「备份」两侧可比：
    #   已登录时根是 HKU\S-1-5-21-...，未登录时是我们 reg load 的 HKU\__CRDP_USR，
    #   换台机器 SID 还会变 —— 不归一化则增量门永远对不上。
    $UserHiveToken = 'HKU\__RDPUSER__'

    $hives = @(
        @{ parent = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall';             scope = 'machine' },
        @{ parent = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; scope = 'machine' },
        @{ parent = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall';             scope = 'user' }
    )
    $extraRoots = New-Object System.Collections.Generic.List[string]
    foreach ($r in @($ExtraHiveRoots)) {
        if ([string]::IsNullOrWhiteSpace($r)) { continue }
        $rr = ([string]$r).TrimEnd('\')
        if (-not $rr) { continue }

        # 两种写法都要吃得下：
        #   'HKU\__CRDP_USR'            —— reg.exe / Mount-RdpUserHive 的写法
        #   'HKCU\Software\__crdp_src'  —— PowerShell 注册表提供程序要求 HKCU:\... 才能 Test-Path
        $rrPs = $rr
        if ($rrPs -match '^[A-Za-z][A-Za-z0-9_]*$') { $rrPs = $rrPs + ':' }
        elseif ($rrPs -notmatch '^[A-Za-z][A-Za-z0-9_]*:') { $rrPs = $rrPs -replace '^([A-Za-z][A-Za-z0-9_]*)\\', '$1:\' }
        $rrReg = $rrPs -replace ':', ''      # HKCU\Software\... —— 与 Convert-ProgramRegPath 的输出同形

        $extraRoots.Add($rrReg)
        $hives += @{ parent = ($rrPs + '\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall');             scope = 'user' }
        $hives += @{ parent = ($rrPs + '\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'); scope = 'user' }
    }

    $list = New-Object System.Collections.Generic.List[object]

    foreach ($h in $hives) {
        if (-not (Test-Path -LiteralPath $h.parent)) { continue }
        foreach ($k in @(Get-ChildItem -LiteralPath $h.parent -ErrorAction SilentlyContinue)) {
            $props = $null
            try { $props = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop } catch { continue }
            if ($null -eq $props) { continue }

            $est = 0
            if ($props.EstimatedSize) { try { $est = [int]$props.EstimatedSize } catch { $est = 0 } }

            # regPathReal = 真实路径（给 reg.exe export 用）
            # regPath     = 归一化路径（给基线 / 清单 / 跨机比对用）
            $regPathReal = Convert-ProgramRegPath -PSPath $k.PSPath
            $regPath     = $regPathReal
            foreach ($rr in $extraRoots) {
                if ($regPathReal -like ($rr + '\*')) {
                    $regPath = $UserHiveToken + $regPathReal.Substring($rr.Length)
                    break
                }
            }

            $list.Add([pscustomobject]@{
                regPath          = $regPath
                regPathReal      = $regPathReal
                keyName          = [string]$k.PSChildName
                scope            = [string]$h.scope
                displayName      = [string]$props.DisplayName
                version          = [string]$props.DisplayVersion
                publisher        = [string]$props.Publisher
                installLocation  = [string]$props.InstallLocation
                displayIcon      = [string]$props.DisplayIcon
                uninstallString  = [string]$props.UninstallString
                estimatedSizeKB  = $est
                windowsInstaller = $props.WindowsInstaller
                systemComponent  = $props.SystemComponent
                parentKeyName    = [string]$props.ParentKeyName
                releaseType      = [string]$props.ReleaseType
            })
        }
    }
    return $list.ToArray()
}

# 扫描已装程序，**包含 RDP 用户的用户级安装**（自动挂载 / 卸载用户 hive）
#
# 为什么单独包一层：备份与基线两处都要用，且都必须「同源」——
# 否则基线里没有用户级条目、备份里却有，增量门会把它们当新装反复抓；
# 反过来则会永远漏抓。所以两边都调这个函数。
#
# ⚠️ 用户已登录时不 load/unload（会崩会话）；未登录时才 reg load，用后必须 unload。
function Get-InstalledProgramsIncludingUser {
    param(
        [string]$RdpUser,
        [scriptblock]$Log = $null
    )

    # 需要 userhive-lib.ps1 提供 Mount/Dismount；没加载就自己 dot-source 进来
    if (-not (Get-Command Mount-RdpUserHive -ErrorAction SilentlyContinue)) {
        $uhLib = Join-Path $PSScriptRoot 'userhive-lib.ps1'
        if (Test-Path -LiteralPath $uhLib) { . $uhLib }
    }

    $extra = @()
    $mount = $null
    if (-not [string]::IsNullOrWhiteSpace($RdpUser) -and (Get-Command Mount-RdpUserHive -ErrorAction SilentlyContinue)) {
        try {
            $mount = Mount-RdpUserHive -RdpUser $RdpUser
            if ($mount.ok) {
                $extra = @($mount.root)
                if ($Log) { try { & $Log ('用户 hive：' + $mount.note) } catch { } }
            } else {
                if ($Log) { try { & $Log ('用户 hive 不可用，用户级程序本次不参与：' + $mount.note) } catch { } }
            }
        } catch {
            if ($Log) { try { & $Log ('挂载用户 hive 异常：' + $_.Exception.Message) } catch { } }
        }
    }

    $result = @()
    try {
        $result = @(Get-InstalledPrograms -ExtraHiveRoots $extra)
    } catch {
        $result = @()
    }

    if ($mount -and (Get-Command Dismount-RdpUserHive -ErrorAction SilentlyContinue)) {
        try { Dismount-RdpUserHive -Mount $mount } catch { }
    }
    return $result
}
# 目录是否可作为「程序安装目录」（存在 + 不在系统/镜像路径内）
function Test-ProgramDirUsable {
    param(
        [string]$Dir,
        [string[]]$SystemRoots     = @(),
        [string[]]$ImageBlockPaths = @()
    )
    if ([string]::IsNullOrWhiteSpace($Dir)) { return $false }
    $d = ([string]$Dir).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $d -PathType Container)) { return $false }
    $dl = $d.ToLower()
    foreach ($s in (@($SystemRoots) + @($ImageBlockPaths))) {
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        $sl = ([string]$s).TrimEnd('\').ToLower()
        if ($dl -eq $sl -or $dl.StartsWith($sl + '\')) { return $false }
    }
    return $true
}

# InstallLocation 为空/不存在时，从 DisplayIcon / UninstallString 推断安装目录。
# 为什么需要：很多程序（尤其中文软件、用户级安装）的 Uninstall 键里**不写 InstallLocation**，
# 导致「程序本体」被整条跳过 —— 这是桌面快捷方式还原后变死链的主因之一。
function Resolve-ProgramInstallDir {
    param(
        $Entry,
        [string[]]$SystemRoots     = @(),
        [string[]]$ImageBlockPaths = @()
    )

    # ① 原本就有可用的 InstallLocation
    $loc = ([string]$Entry.installLocation).TrimEnd('\')
    if (Test-ProgramDirUsable -Dir $loc -SystemRoots $SystemRoots -ImageBlockPaths $ImageBlockPaths) { return $loc }

    # ② 从 DisplayIcon / UninstallString 推断
    foreach ($raw in @([string]$Entry.displayIcon, [string]$Entry.uninstallString)) {
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $s = $raw.Trim()
        $s = ($s -split ',')[0].Trim()                       # 去掉图标索引（如 "C:\App\app.exe,0"）
        if ($s.StartsWith('"')) { $s = $s.Substring(1) }     # 去前引号
        $q = $s.IndexOf('"')
        if ($q -ge 0) { $s = $s.Substring(0, $q) }           # 去后引号及其后参数
        $s = $s.Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        if ($s -notmatch '^[A-Za-z]:\\') { continue }        # 只要绝对路径
        if ($s -match '(?i)\\msiexec(\.exe)?$') { continue } # MSI 卸载器，不是安装目录
        if ($s -match '(?i)^[A-Za-z]:\\Windows\\') { continue }
        $dir = $null
        if     (Test-Path -LiteralPath $s -PathType Leaf)      { $dir = Split-Path -Path $s -Parent }
        elseif (Test-Path -LiteralPath $s -PathType Container) { $dir = $s }
        if ($dir -and (Test-ProgramDirUsable -Dir $dir -SystemRoots $SystemRoots -ImageBlockPaths $ImageBlockPaths)) {
            return $dir.TrimEnd('\')
        }
    }
    return $null
}

# 单条记录是否「值得备份的安装型程序」
function Test-ProgramCandidate {
    param(
        $Entry,
        [string[]]$SystemRoots,
        [string[]]$ImageBlockPaths,
        [string[]]$Blocklist
    )

    if ([string]::IsNullOrWhiteSpace([string]$Entry.displayName)) { return $false }
    if ($Entry.systemComponent -eq 1) { return $false }
    if (-not [string]::IsNullOrWhiteSpace([string]$Entry.parentKeyName)) { return $false }
    if ([string]$Entry.releaseType -match '(?i)Update|Hotfix|Security|ServicePack') { return $false }
    if ([string]$Entry.publisher -match '(?i)^Microsoft') { return $false }

    foreach ($b in $Blocklist) {
        if (-not [string]::IsNullOrWhiteSpace($b) -and ([string]$Entry.displayName -match $b)) { return $false }
    }

    $loc = [string]$Entry.installLocation
    if ([string]::IsNullOrWhiteSpace($loc)) { return $false }
    $loc = $loc.TrimEnd('\')
    if (-not (Test-Path -LiteralPath $loc -PathType Container)) { return $false }

    $ll = $loc.ToLower()
    foreach ($sr in $SystemRoots) {
        $s = $sr.TrimEnd('\').ToLower()
        if ($ll -eq $s -or $ll.StartsWith($s + '\')) { return $false }
    }
    foreach ($bp in $ImageBlockPaths) {
        $b = $bp.TrimEnd('\').ToLower()
        if ($ll -eq $b -or $ll.StartsWith($b + '\')) { return $false }
    }
    return $true
}

# 从全部已装程序里挑出「要备份的」：增量 + 体积上限
function Get-ProgramsToBackup {
    param(
        [object[]]$All,
        [string[]]$BaselineRegPaths      = @(),   # 开机基线（镜像自带）→ 跳过
        [string[]]$AlwaysIncludeRegPaths = @(),   # 之前备份过的 → 必须继续带（跨运行持久）
        [string[]]$AlwaysIncludeLocations= @(),   # 之前备份过的「目录」→ 必须继续带（快捷方式补抓跨运行持久）
        [string[]]$ExcludePaths          = @(),   # 已被 portable 处理过的目录
        [string[]]$SystemRoots           = @(),
        [string[]]$ImageBlockPaths       = @(),
        [string[]]$Blocklist             = @(),
        [int]     $MaxMBPerApp           = 1024,
        [int]     $MaxTotalMB            = 2048,
        [bool]    $DeriveInstallLocation = $true  # InstallLocation 缺失时从 DisplayIcon/UninstallString 推断
    )

    $baseSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($x in $BaselineRegPaths)      { if ($x) { [void]$baseSet.Add($x.ToLower()) } }
    $prevSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($x in $AlwaysIncludeRegPaths) { if ($x) { [void]$prevSet.Add($x.ToLower()) } }
    $locSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($x in $AlwaysIncludeLocations) { if ($x) { [void]$locSet.Add((([string]$x).TrimEnd('\')).ToLower()) } }

    $selected = New-Object System.Collections.Generic.List[object]
    $skipped  = New-Object System.Collections.Generic.List[string]
    $seen     = New-Object 'System.Collections.Generic.HashSet[string]'
    $totalBytes = [long]0

    foreach ($a in $All) {
        $name = [string]$a.displayName
        $loc  = ([string]$a.installLocation).TrimEnd('\')

        # InstallLocation 缺失/不可用时，尝试从 DisplayIcon / UninstallString 推断
        if ($DeriveInstallLocation -and -not (Test-ProgramDirUsable -Dir $loc -SystemRoots $SystemRoots -ImageBlockPaths $ImageBlockPaths)) {
            $derived = Resolve-ProgramInstallDir -Entry $a -SystemRoots $SystemRoots -ImageBlockPaths $ImageBlockPaths
            if ($derived) {
                $a | Add-Member -NotePropertyName installLocation -NotePropertyValue $derived -Force
                $a | Add-Member -NotePropertyName derived         -NotePropertyValue $true     -Force
                $loc = $derived
            }
        }

        if (-not (Test-ProgramCandidate -Entry $a -SystemRoots $SystemRoots -ImageBlockPaths $ImageBlockPaths -Blocklist $Blocklist)) {
            continue
        }
        if (-not $seen.Add($loc.ToLower())) { continue }

        $excluded = $false
        foreach ($ep in $ExcludePaths) {
            if (-not [string]::IsNullOrWhiteSpace($ep) -and $loc.ToLower().StartsWith($ep.TrimEnd('\').ToLower())) { $excluded = $true; break }
        }
        if ($excluded) { continue }

        $regKey     = ([string]$a.regPath).ToLower()
        $isShortcut = ([string]$a.reason -eq 'shortcut')
        $isNew      = -not $baseSet.Contains($regKey)
        $isPrev     = $prevSet.Contains($regKey) -or ($loc -and $locSet.Contains($loc.ToLower()))
        # 快捷方式线索合成的条目没有 regPath，不受「镜像自带」增量门约束
        if (-not $isShortcut -and -not $isNew -and -not $isPrev) { continue }

        $size = [long]$a.estimatedSizeKB * 1KB
        if ($size -le 0) { $size = Get-ProgramTreeBytes -Path $loc }
        if ($MaxMBPerApp -gt 0 -and ($size / 1MB) -gt $MaxMBPerApp) {
            $skipped.Add(("{0}（{1:N0} MB > 单程序上限 {2} MB）" -f $name, ($size / 1MB), $MaxMBPerApp))
            continue
        }
        if ($MaxTotalMB -gt 0 -and (($totalBytes + $size) / 1MB) -gt $MaxTotalMB) {
            $skipped.Add(("{0}（超出总量上限 {1} MB）" -f $name, $MaxTotalMB))
            continue
        }
        $totalBytes += $size

        $selected.Add([pscustomobject]@{
            name             = $name
            displayName      = $name
            version          = [string]$a.version
            publisher        = [string]$a.publisher
            installLocation  = $loc
            bytes            = $size
            scope            = [string]$a.scope
            regPath          = [string]$a.regPath
            windowsInstaller = $a.windowsInstaller
            reason           = $(if ($isShortcut) { 'shortcut' } elseif ($isNew) { 'new' } else { 'prev' })
        })
    }

    return @{ selected = $selected.ToArray(); skipped = $skipped.ToArray(); totalBytes = $totalBytes }
}

# ---------------------------------------------------------------- 备份侧

function Backup-Programs {
    param(
        [object[]]$Apps,
        [string]  $Stage,
        [string]  $ProgramsRoot = '',       # 还原根（用于识别「实体已在 D 盘」的情况）
        [string]  $RegDir = ''
    )

    $captured = New-Object System.Collections.Generic.List[object]
    $problems = New-Object System.Collections.Generic.List[string]

    if (-not $Apps -or @($Apps).Count -eq 0) {
        return @{ captured = @(); problems = @() }
    }

    $progRoot = Join-Path $Stage "programs"
    if ([string]::IsNullOrWhiteSpace($RegDir)) { $RegDir = Join-Path $progRoot "_registry" }
    New-Item -ItemType Directory -Force -Path $RegDir | Out-Null

    $i = 0
    foreach ($a in $Apps) {
        $i++
        try {
            $src = ([string]$a.installLocation).TrimEnd('\')
            if ([string]::IsNullOrWhiteSpace($src) -or -not (Test-Path -LiteralPath $src)) {
                $problems.Add("missing:$($a.displayName)")
                continue
            }
            # 若实体本身就在我们的还原根里（junction 场景），直接以它为源
            $real = Get-ProgramRealPath -Path $src
            $rel  = Get-ProgramMirrorRel -Abs $src
            $dst  = Join-Path $progRoot $rel
            New-Item -ItemType Directory -Force -Path $dst | Out-Null

            & robocopy $real $dst /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP /XJ /XO 2>&1 | Out-Null
            if ($LASTEXITCODE -ge 8) {
                $problems.Add("program:$src (robocopy $LASTEXITCODE)")
                continue
            }

            # 导出该程序的 Uninstall 键（还原后「应用和功能」与 winget 都认它）
            $safe = ("{0:D3}_{1}" -f $i, ($([string]$a.displayName) -replace '[^\w\.\-]', '_'))
            if ($safe.Length -gt 80) { $safe = $safe.Substring(0, 80) }
            $regLeaf = $safe + ".reg"
            $regFile = Join-Path $RegDir $regLeaf
            $regOk = $false
            $regPathNorm = [string]$a.regPath
            $regPathReal = [string]$a.regPathReal
            if ([string]::IsNullOrWhiteSpace($regPathReal)) { $regPathReal = $regPathNorm }

            # 用户级程序的卸载键【不单独导出】：
            #   ① 它已经在 registry\user\HKCU-Software.reg（HKCU\Software 全量导出）里了，重复导出会互相打架；
            #   ② 从 HKU\<SID> 导出的 .reg 正文带真实 SID，换台机器那个 SID 不存在 → 导入必然失败。
            #   还原侧靠 HKCU-Software.reg 那条既有通道把它带回来（user 作用域导入）。
            $isUserHive = ($regPathNorm -like 'HKU\__RDPUSER__*') -or
                          ($regPathNorm -like 'HKCU\*') -or
                          (([string]$a.scope) -eq 'user')
            if ($isUserHive) {
                if (-not [string]::IsNullOrWhiteSpace($regPathNorm)) {
                    # 视为「已由 HKCU-Software.reg 覆盖」，不算 problem
                    $regOk = $false
                    $regLeaf = ''
                }
            } elseif (-not [string]::IsNullOrWhiteSpace($regPathReal)) {
                & reg.exe export "$regPathReal" "$regFile" /y 2>&1 | Out-Null
                $regOk = ($LASTEXITCODE -eq 0)
                # 只有「本来有 regPath 却导出失败」才算 problem。
                # 快捷方式线索补抓的条目本来就没有 Uninstall 键（regPath 为空），不算失败。
                if (-not $regOk) { $problems.Add("reg:$($a.displayName)") }
            }

            $captured.Add([pscustomobject]@{
                name             = [string]$a.displayName
                displayName      = [string]$a.displayName
                version          = [string]$a.version
                publisher        = [string]$a.publisher
                originalPath     = $src
                mirrorRel        = $rel
                storedPath       = $dst
                bytes            = (Get-ProgramTreeBytes -Path $dst)
                scope            = [string]$a.scope
                regPath          = $regPathNorm
                regFile          = $(if ($regOk) { $regLeaf } else { '' })
                regInUserHive    = $isUserHive
                windowsInstaller = $a.windowsInstaller
                source           = [string]$a.reason
                capturedUtc      = (Get-Date).ToUniversalTime().ToString('o')
            })
        } catch {
            $problems.Add("program-ex:$($a.displayName)")
        }
    }

    return @{ captured = $captured.ToArray(); problems = $problems.ToArray() }
}

function Write-ProgramsManifest {
    param([object[]]$Apps, [string]$Path)
    # 注意：PS 5.1 下 @(<泛型List>) 会抛「参数类型不匹配」，必须用 [object[]] 转换
    $arr = [object[]]$Apps
    $obj = [ordered]@{
        version     = 1
        capturedUtc = (Get-Date).ToUniversalTime().ToString('o')
        count       = $arr.Count
        programs    = $arr
    }
    $dir = Split-Path $Path -Parent
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $obj | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $Path -Encoding UTF8
}

# ---------------------------------------------------------------- 还原侧

function New-ProgramJunction {
    param([string]$Link, [string]$Target)
    try {
        $parent = Split-Path -Path $Link -Parent
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        if (Test-Path -LiteralPath $Link) { return $false }
        & cmd.exe /c mklink /J "$Link" "$Target" 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Import-ProgramRegFile {
    param([string]$RegDir, $Entry)
    $leaf = [string]$Entry.regFile
    if ([string]::IsNullOrWhiteSpace($leaf)) { return $false }
    $f = Join-Path $RegDir $leaf
    if (-not (Test-Path -LiteralPath $f)) { return $false }
    & reg.exe import "$f" 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# 按 originalPath 还原安装型程序。
# -PreferJunction：原路径在 C 盘时，实体落 ProgramsRoot 并在原路径建 junction（C 盘零增长）
# -UserPrefix / -InvertScope：machine / user 作用域分流
function Restore-Programs {
    param(
        [object[]]$Entries,
        [string]  $Stage,
        [string]  $ProgramsRoot = '',
        [switch]  $PreferJunction,
        [string]  $UserPrefix = '',
        [switch]  $InvertScope,
        [string[]]$ExcludePaths = @()      # 永不还原的程序目录（按前缀匹配）
    )

    $restored  = 0
    $junctioned = 0
    $problems  = New-Object System.Collections.Generic.List[string]
    $regDir    = Join-Path (Join-Path $Stage "programs") "_registry"
    $prefix    = if ([string]::IsNullOrWhiteSpace($UserPrefix)) { '' } else { $UserPrefix.ToLower() }

    foreach ($e in @($Entries)) {
        $orig = [string]$e.originalPath
        if ([string]::IsNullOrWhiteSpace($orig)) { continue }

        # 排除名单（前缀匹配）：即使旧快照里含它，也不还原
        $excluded = $false
        foreach ($ep in @($ExcludePaths)) {
            if (-not [string]::IsNullOrWhiteSpace($ep) -and
                $orig.TrimEnd('\').ToLower().StartsWith(([string]$ep).TrimEnd('\').ToLower())) {
                $excluded = $true; break
            }
        }
        if ($excluded) { continue }

        if ($prefix) {
            $inUser = $orig.ToLower().StartsWith($prefix)
            if ($InvertScope) { if ($inUser) { continue } }
            else              { if (-not $inUser) { continue } }
        }

        $rel = [string]$e.mirrorRel
        if ([string]::IsNullOrWhiteSpace($rel)) { $rel = Get-ProgramMirrorRel -Abs $orig }
        $store = Join-Path (Join-Path $Stage "programs") $rel
        if (-not (Test-Path -LiteralPath $store)) { $store = [string]$e.storedPath }
        if ([string]::IsNullOrWhiteSpace($store) -or -not (Test-Path -LiteralPath $store)) {
            $problems.Add("missing-store:$orig")
            continue
        }

        $onC = ($orig -match '^[Cc]:')
        $useJunction = ($PreferJunction -and $onC -and -not [string]::IsNullOrWhiteSpace($ProgramsRoot))
        $target = $(if ($useJunction) { Join-Path $ProgramsRoot $rel } else { $orig })

        # 原路径已存在：是我们建的 junction → 幂等；否则是镜像自带程序 → 不覆盖
        if (Test-Path -LiteralPath $orig) {
            if (Test-ProgramReparsePoint -Path $orig) {
                if ($useJunction) { $junctioned++ }
                $restored++
                [void](Import-ProgramRegFile -RegDir $regDir -Entry $e)
                continue
            }
            $problems.Add("exists:$orig")
            [void](Import-ProgramRegFile -RegDir $regDir -Entry $e)
            continue
        }

        $parent = Split-Path -Path $target -Parent
        if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }

        & robocopy $store $target /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP /XJ 2>&1 | Out-Null
        if ($LASTEXITCODE -ge 8) {
            $problems.Add("restore:$orig (robocopy $LASTEXITCODE)")
            continue
        }

        if ($useJunction) {
            if (New-ProgramJunction -Link $orig -Target $target) { $junctioned++ }
            else { $problems.Add("junction:$orig") }
        }

        [void](Import-ProgramRegFile -RegDir $regDir -Entry $e)
        $restored++
    }

    return @{ restored = $restored; junctioned = $junctioned; problems = $problems.ToArray() }
}


# ---------------------------------------------------------------- 关联数据（AppData / ProgramData）

function Get-ProgramCfg($obj, $name, $fallback) {
    if ($null -eq $obj) { return $fallback }
    if ($obj -is [System.Collections.IDictionary]) {
        if ($obj.Contains($name) -and $null -ne $obj[$name]) { return $obj[$name] }
        return $fallback
    }
    $p = $obj.PSObject.Properties[$name]
    if ($null -eq $p -or $null -eq $p.Value) { return $fallback }
    return $p.Value
}

# 展开 %VAR% 形式的环境变量
function Expand-ProgramPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try { return [Environment]::ExpandEnvironmentVariables($Path) } catch { return $Path }
}

# 生成用于匹配数据目录的候选名（保守：不用「第一个词」，避免匹配到 Microsoft / Windows 这类泛化目录）
function Get-ProgramDataNameCandidates {
    param($Program)
    $names = New-Object System.Collections.Generic.List[string]
    $dn = [string]$Program.displayName
    if (-not [string]::IsNullOrWhiteSpace($dn)) {
        $names.Add($dn.Trim())
        $noVer = ($dn -replace '\s+v?[\d][\d\.]*\s*$', '').Trim()      # 去尾部版本号
        if ($noVer -and $noVer -ne $dn) { $names.Add($noVer) }
    }
    $pub = [string]$Program.publisher
    if (-not [string]::IsNullOrWhiteSpace($pub) -and $pub -notmatch '(?i)^Microsoft') {
        $names.Add($pub.Trim())
        $pw = ($pub -split '[\s,]+')[0].Trim()                          # 发布商首词（品牌名）
        if ($pw.Length -ge 4) { $names.Add($pw) }
    }
    $deny = @('microsoft','windows','common','package','packages','programs','temp','system','update','installer','shared')
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($n in $names) {
        $t = [string]$n
        if ($t.Length -lt 4) { continue }
        if ($deny -contains $t.ToLower()) { continue }
        $out.Add($t)
    }
    return $out.ToArray()
}

# 找出「某个已备份程序」在 AppData / ProgramData 下的关联数据目录。
# 只匹配一级子目录名（+ 发布商目录下的二级），**绝不遍历整个 LocalAppData 的内容**。
function Get-ProgramDataDirs {
    param(
        [object[]]$Programs,
        [object[]]$DataGlobs = @(),
        [int]     $MaxDirs   = 80
    )

    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($r in @($env:APPDATA, $env:LOCALAPPDATA,
                     $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Programs' }),
                     $env:ProgramData)) {
        if ([string]::IsNullOrWhiteSpace($r)) { continue }
        if (-not (Test-Path -LiteralPath $r)) { continue }
        if (-not $roots.Contains($r)) { $roots.Add($r) }
    }

    # 明确排除的系统级数据根（别把整棵 Microsoft / Packages 拖走）
    $hardSkip = New-Object System.Collections.Generic.List[string]
    foreach ($r in @($env:APPDATA, $env:LOCALAPPDATA, $env:ProgramData)) {
        if ([string]::IsNullOrWhiteSpace($r)) { continue }
        $hardSkip.Add((Join-Path $r 'Microsoft'))
        $hardSkip.Add((Join-Path $r 'Packages'))
        $hardSkip.Add((Join-Path $r 'Temp'))
    }
    if ($env:LOCALAPPDATA) { $hardSkip.Add((Join-Path $env:LOCALAPPDATA 'Programs')) }

    $found = New-Object System.Collections.Generic.List[string]
    $seen  = New-Object 'System.Collections.Generic.HashSet[string]'

    function Test-Skip([string]$p) {
        $pl = $p.ToLower()
        foreach ($x in $hardSkip) { if ($pl -eq $x.ToLower()) { return $true } }
        return $false
    }

    # ---------- 1) 显式 dataGlobs（优先，可精确覆盖）----------
    foreach ($g in $DataGlobs) {
        if ($null -eq $g) { continue }
        foreach ($d in @(Get-ProgramCfg $g 'dirs' @())) {
            if ([string]::IsNullOrWhiteSpace($d)) { continue }
            $exp = Expand-ProgramPath ([string]$d)
            if ([string]::IsNullOrWhiteSpace($exp)) { continue }
            if (Test-Skip $exp) { continue }
            if ((Test-Path -LiteralPath $exp) -and $seen.Add($exp.ToLower())) { $found.Add($exp) }
        }
    }

    # ---------- 2) 按程序名 / 发布商匹配一级子目录 ----------
    foreach ($p in $Programs) {
        if ($found.Count -ge $MaxDirs) { break }
        $names = @(Get-ProgramDataNameCandidates -Program $p)
        if (@($names).Count -eq 0) { continue }
        $pub = [string]$p.publisher
        $pubOk = (-not [string]::IsNullOrWhiteSpace($pub)) -and ($pub -notmatch '(?i)^Microsoft')

        foreach ($root in $roots) {
            if ($found.Count -ge $MaxDirs) { break }
            foreach ($sub in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
                if ($found.Count -ge $MaxDirs) { break }
                $nm = $sub.Name
                $hit = $false
                foreach ($n in $names) {
                    if ($nm -ieq $n) { $hit = $true; break }
                    if ($nm -like ($n + '*')) { $hit = $true; break }
                }
                if ($hit) {
                    if (-not (Test-Skip $sub.FullName) -and $seen.Add($sub.FullName.ToLower())) { $found.Add($sub.FullName) }
                    continue
                }
                # 发布商目录下的二级匹配：%APPDATA%\<Publisher>\<App>
                if ($pubOk -and ($nm -ieq $pub -or $nm -like ($pub + '*'))) {
                    foreach ($sub2 in @(Get-ChildItem -LiteralPath $sub.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
                        if ($found.Count -ge $MaxDirs) { break }
                        foreach ($n in $names) {
                            if ($sub2.Name -ieq $n -or $sub2.Name -like ('*' + $n + '*')) {
                                if (-not (Test-Skip $sub2.FullName) -and $seen.Add($sub2.FullName.ToLower())) { $found.Add($sub2.FullName) }
                                break
                            }
                        }
                    }
                }
            }
        }
    }

    return $found.ToArray()
}

# ---------------------------------------------------------------- 文件关联 / COM（HKCR）

# 找出与「被备份程序」相关的文件关联键。
# 只返回命中的 ProgID / CLSID，**绝不导整棵 HKCR**（那含海量系统项）。
function Get-HkcrMatches {
    param(
        [string[]]$ProgramPaths = @(),
        [string[]]$ExtraProgIds = @(),
        [int]     $MaxKeys      = 300
    )

    $hits = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $roots = @(
        @{ ps = 'HKLM:\SOFTWARE\Classes'; reg = 'HKLM\SOFTWARE\Classes' },
        @{ ps = 'HKCU:\Software\Classes'; reg = 'HKCU\Software\Classes' }
    )

    # 1) 手动指定的 ProgID（精确）
    foreach ($pidItem in $ExtraProgIds) {
        if ([string]::IsNullOrWhiteSpace($pidItem)) { continue }
        foreach ($r in $roots) {
            $rk = $r.reg + '\' + $pidItem
            if ((Test-Path -LiteralPath ($r.ps + '\' + $pidItem)) -and $seen.Add($rk.ToLower())) { $hits.Add($rk) }
        }
    }

    # 2) 按 installLocation 子串匹配（只读顶层键的默认值 / shell\open\command）
    $norm = New-Object System.Collections.Generic.List[string]
    foreach ($p in $ProgramPaths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $norm.Add((([string]$p).TrimEnd('\')).ToLower())
    }
    if ($norm.Count -gt 0) {
        foreach ($r in $roots) {
            if (-not (Test-Path -LiteralPath $r.ps)) { continue }
            foreach ($k in @(Get-ChildItem -LiteralPath $r.ps -ErrorAction SilentlyContinue)) {
                if ($hits.Count -ge $MaxKeys) { break }
                $dflt = ''
                $cmd  = ''
                try { $dflt = [string](Get-ItemProperty -LiteralPath $k.PSPath -Name '(default)' -ErrorAction SilentlyContinue).'(default)' } catch { }
                try { $cmd  = [string](Get-ItemProperty -LiteralPath ($k.PSPath + '\shell\open\command') -Name '(default)' -ErrorAction SilentlyContinue).'(default)' } catch { }
                $blob = (($dflt + ' ') + $cmd).ToLower()
                if ([string]::IsNullOrWhiteSpace($blob)) { continue }
                foreach ($n in $norm) {
                    if ($blob.Contains($n)) {
                        $rk = $r.reg + '\' + $k.PSChildName
                        if ($seen.Add($rk.ToLower())) { $hits.Add($rk) }
                        break
                    }
                }
            }
        }
    }

    return $hits.ToArray()
}

# ---------------------------------------------------------------- 快捷方式线索（补抓程序本体）
# 为什么需要：程序本体的识别一直依赖 Uninstall 注册表的 InstallLocation，
# 而很多程序（尤其中文软件、用户级安装）根本不写这个字段 → 程序没被备份 →
# 还原后桌面快捷方式报「目标驱动器或网络连接不可用」。
# 这里反过来：以桌面/开始菜单的快捷方式为线索，推断它指向的「程序根目录」并纳入备份。

# 给定目标文件路径 + 边界集合，推断「程序根目录」= 边界下的第一级目录
function Get-ShortcutProgramRoot {
    param(
        [string]$Target,
        [string[]]$Boundaries = @()
    )
    if ([string]::IsNullOrWhiteSpace($Target)) { return $null }
    $t = $Target.Trim()
    if ($t -notmatch '^[A-Za-z]:\\') { return $null }
    $tl = $t.ToLower()

    $bestLen = -1
    $bestOrig = $null
    foreach ($b in $Boundaries) {
        if ([string]::IsNullOrWhiteSpace($b)) { continue }
        $bo = ([string]$b).TrimEnd('\')
        $bl = $bo.ToLower()
        if ($tl -eq $bl) { continue }
        if ($tl.StartsWith($bl + '\')) {
            if ($bl.Length -gt $bestLen) { $bestLen = $bl.Length; $bestOrig = $bo }
        }
    }
    if (-not $bestOrig) { return $null }

    $rel = $t.Substring($bestOrig.Length).TrimStart('\')
    if ([string]::IsNullOrWhiteSpace($rel)) { return $null }
    $parts = @($rel -split '\\')
    if ($parts.Count -lt 2) { return $null }      # 直接躺在边界下的散落文件 → 不采纳
    return ($bestOrig + '\' + $parts[0])
}

# 扫快捷方式目录 → 推断要补抓的程序根目录
function Get-ShortcutTargets {
    param(
        [string[]]$Dirs            = @(),
        [string[]]$Boundaries      = @(),
        [string[]]$SkipPrefixes    = @(),
        [string[]]$SkipFolderNames = @('_失效快捷方式'),
        [string[]]$CaptureDrives   = @('C:'),
        [int]     $MaxMBPerTarget  = 1024,
        [int]     $MaxTotalMB      = 2048
    )

    $candidates = New-Object System.Collections.Generic.List[object]
    $resolved   = New-Object System.Collections.Generic.List[object]
    $skipped    = New-Object System.Collections.Generic.List[string]
    $seen       = New-Object 'System.Collections.Generic.HashSet[string]'
    $totalBytes = [long]0

    $com = $null
    try { $com = New-Object -ComObject WScript.Shell } catch { }

    foreach ($d in $Dirs) {
        if ([string]::IsNullOrWhiteSpace($d) -or -not (Test-Path -LiteralPath $d)) { continue }
        foreach ($l in @(Get-ChildItem -LiteralPath $d -Recurse -File -Filter *.lnk -ErrorAction SilentlyContinue)) {
            $inPark = $false
            foreach ($fn in $SkipFolderNames) {
                if (-not [string]::IsNullOrWhiteSpace($fn) -and $l.FullName -match ('(?i)\\' + [regex]::Escape($fn) + '\\')) { $inPark = $true; break }
            }
            if ($inPark) { continue }

            $target = $null
            if ($com) { try { $target = [string]$com.CreateShortcut($l.FullName).TargetPath } catch { $target = $null } }
            if ([string]::IsNullOrWhiteSpace($target)) { continue }
            $t = $target.Trim()

            if ($t -notmatch '^[A-Za-z]:\\') { $skipped.Add("$($l.Name) -> 非绝对路径"); continue }
            if (-not (Test-Path -LiteralPath $t)) { $skipped.Add("$($l.Name) -> 目标不存在: $t"); continue }

            $drv = $t.Substring(0, 2).ToUpper()
            if (@($CaptureDrives) -notcontains $drv) { continue }

            $tl = $t.ToLower()
            $skipIt = $false
            foreach ($sp in $SkipPrefixes) {
                if ([string]::IsNullOrWhiteSpace($sp)) { continue }
                $spl = ([string]$sp).TrimEnd('\').ToLower()
                if ($tl -eq $spl -or $tl.StartsWith($spl + '\')) { $skipIt = $true; break }
            }
            if ($skipIt) { continue }

            $root = Get-ShortcutProgramRoot -Target $t -Boundaries $Boundaries
            if (-not $root) { $skipped.Add("$($l.Name) -> 无法推断程序根目录"); continue }
            if (-not (Test-Path -LiteralPath $root -PathType Container)) { $skipped.Add("$($l.Name) -> 根目录不存在: $root"); continue }

            $rl = $root.ToLower()
            $skipIt = $false
            foreach ($sp in $SkipPrefixes) {
                if ([string]::IsNullOrWhiteSpace($sp)) { continue }
                $spl = ([string]$sp).TrimEnd('\').ToLower()
                if ($rl -eq $spl -or $rl.StartsWith($spl + '\')) { $skipIt = $true; break }
            }
            if ($skipIt) { continue }
            if (-not $seen.Add($rl)) { continue }

            $bytes = Get-ProgramTreeBytes -Path $root
            if ($MaxMBPerTarget -gt 0 -and ($bytes / 1MB) -gt $MaxMBPerTarget) {
                $skipped.Add(("{0}（{1:N0} MB > 单目录上限 {2} MB）" -f $root, ($bytes / 1MB), $MaxMBPerTarget)); continue
            }
            if ($MaxTotalMB -gt 0 -and (($totalBytes + $bytes) / 1MB) -gt $MaxTotalMB) {
                $skipped.Add(("{0}（超出总量上限 {1} MB）" -f $root, $MaxTotalMB)); continue
            }
            $totalBytes += $bytes

            $candidates.Add([pscustomobject]@{
                installLocation = $root
                displayName     = (Split-Path -Path $root -Leaf)
                version         = ''
                publisher       = ''
                bytes           = $bytes
                scope           = 'machine'
                regPath         = ''
                reason          = 'shortcut'
                shortcut        = $l.FullName
                target          = $t
            })
            $resolved.Add([pscustomobject]@{ shortcut = $l.FullName; target = $t; root = $root })
        }
    }

    return @{ candidates = $candidates.ToArray(); skipped = $skipped.ToArray(); resolved = $resolved.ToArray(); totalBytes = $totalBytes }
}

# 在已还原的程序目录里按文件名唯一定位（用于快捷方式修复）
function Find-RestoredFile {
    param(
        [string]  $FileName,
        [object[]]$ProgramEntries = @(),
        # 额外搜索根（数据目录 / 可移动程序暂存根）：programs.json 没登记的便携程序也能找到
        [string[]]$AdditionalDirs = @(),
        [int]     $MaxSearch      = 3
    )
    if ([string]::IsNullOrWhiteSpace($FileName)) { return $null }
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($p in $ProgramEntries) {
        $op = [string]$p.originalPath
        if ([string]::IsNullOrWhiteSpace($op) -or -not (Test-Path -LiteralPath $op)) { continue }
        $f = @(Get-ChildItem -LiteralPath $op -Recurse -File -Filter $FileName -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($f.Count -gt 0) {
            $hits.Add($f[0].FullName)
            if ($hits.Count -ge $MaxSearch) { break }
        }
    }
    # programs.json 没覆盖到（便携程序只落数据目录）→ 再扫额外目录
    if ($hits.Count -eq 0) {
        foreach ($ad in $AdditionalDirs) {
            if ([string]::IsNullOrWhiteSpace($ad) -or -not (Test-Path -LiteralPath $ad)) { continue }
            $f = @(Get-ChildItem -LiteralPath $ad -Recurse -File -Filter $FileName -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($f.Count -gt 0) {
                $hits.Add($f[0].FullName)
                if ($hits.Count -ge $MaxSearch) { break }
            }
        }
    }
    if ($hits.Count -eq 1) { return $hits[0] }
    return $null
}

# 把路径里的「别的用户名」改写成当前用户目录，命中（改写后的路径存在）才返回，否则 $null。
# 纯函数、无副作用、可单测。解决：快照里的 lnk 把当时的用户名烤死在二进制里。
#   C:\Users\aigc\AppData\Local\LightC\LightC.exe  →  C:\Users\a\AppData\Local\LightC\LightC.exe
function Get-RemappedUserPath {
    param(
        [string]$Path,
        [string]$NewUserName = '',
        [string]$OldUserName = ''
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if ([string]::IsNullOrWhiteSpace($NewUserName)) { $NewUserName = Split-Path -Path $env:USERPROFILE -Leaf }
    if ([string]::IsNullOrWhiteSpace($NewUserName)) { return $null }

    $m = [regex]::Match($Path, '(?i)^([A-Za-z]:\\Users\\)([^\\]+)(\\.*|$)')
    if (-not $m.Success) { return $null }

    $old = $m.Groups[2].Value
    if ($old -ieq $NewUserName) { return $null }                       # 已经是当前用户
    if (-not [string]::IsNullOrWhiteSpace($OldUserName) -and ($old -ine $OldUserName)) { return $null }

    $cand = $m.Groups[1].Value + $NewUserName + $m.Groups[3].Value
    if ((Test-Path -LiteralPath $Path) -and -not (Test-Path -LiteralPath $cand)) { return $null }
    if (Test-Path -LiteralPath $cand) { return $cand }
    return $null
}

# ---------------------------------------------------------------- 快捷方式校验与修复（还原后兜底）

# 还原之后调用：校验每个快捷方式的目标；能唯一定位到已还原的程序就改写指向；
# 修不好的移入「_失效快捷方式」文件夹（非破坏、可找回）。幂等：park 目录内的不再搬。
# ⚠️ 只有在「有程序清单」且「后台重装已结束」时才真的搬 —— 否则只记 BROKEN、留在桌面
#    （park 目录不参与备份，过早 park 会让快捷方式永久消失）。详见函数内 park 安全性判定。
function Repair-Shortcuts {
    param(
        [string[]]$Dirs               = @(),
        [string]$ProgramsManifestPath = '',
        [string]$ParkFolder           = '_失效快捷方式',
        [switch]$ParkBroken,
        # 额外搜索根（数据目录 / 可移动程序暂存根），透传给 Find-RestoredFile
        [string[]]$AdditionalDirs     = @(),
        # 显式指定「旧用户名=新用户名」；留空 = 自动把任意 C:\Users\<别人>\ 改写成当前用户目录
        [string]$UserProfileRemap     = '',
        [string]$LogPath              = '',
        # 快照暂存根（用于判定「后台 winget 重装是否已结束」）；留空则取 $env:CLOUDRDP_SNAPSHOT_STAGE
        [string]$Stage                = '',
        # 后台重装状态文件；留空则取 <Stage>\_logs\apps-status.json
        [string]$ReinstallStatusPath  = ''
    )

    $checked = 0; $ok = 0; $repaired = 0; $parked = 0; $skipped = 0; $parkDeferred = 0
    $lines = New-Object System.Collections.Generic.List[string]

    # 用户目录改写规则：显式指定优先，否则自动用「当前用户目录」兜底。
    # 背景：快照里的 lnk 目标路径把**当时的用户名**烤死在二进制里（如 C:\Users\aigc\...），
    # 换机器/换用户名后必然指向不存在的路径 —— 这类死链可以直接按「同名用户目录」救回来。
    $remapOld = ''; $remapNew = ''
    if (-not [string]::IsNullOrWhiteSpace($UserProfileRemap)) {
        $parts = $UserProfileRemap -split '=', 2
        if ($parts.Count -eq 2) { $remapOld = $parts[0].Trim(); $remapNew = $parts[1].Trim() }
    }
    if ([string]::IsNullOrWhiteSpace($remapNew)) {
        $remapNew = Split-Path -Path $env:USERPROFILE -Leaf   # 当前用户名
    }

    # 已还原程序条目（用于修复时的唯一定位）
    $programs = @()
    if (-not [string]::IsNullOrWhiteSpace($ProgramsManifestPath) -and (Test-Path -LiteralPath $ProgramsManifestPath)) {
        try {
            $pj = Get-Content -LiteralPath $ProgramsManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $programs = @($pj.programs)
        } catch { $programs = @() }
    }

    # ---------------------------------------------------------------- park 安全性判定
    # ⚠️ 真机踩过（会**永久丢数据**）：park = 把快捷方式从桌面移进「_失效快捷方式」，
    #    而该目录**不参与备份**（backup-snapshot.ps1 特意排除它，避免死链被反复备份回去）。
    #    于是「程序还没还原」的那一轮一旦 park，快捷方式就从下一轮快照里彻底消失 ——
    #    机器销毁后不可恢复（实测 LightC.lnk 就这样丢过）。
    # 因此只在**有依据**时才 park：
    #   ① programs.json 有内容（说明程序清单确实还原过；空/缺失 = 目标缺失很可能只是「还没还原」）
    #   ② 后台 winget 重装已结束（apps-status.json 的 state=done）—— 否则目标可能马上就出现
    # 不满足时只记 BROKEN，把快捷方式**留在桌面**，等下一轮程序还原后再修。
    $parkSafe = [bool]$ParkBroken
    $parkDeferReason = ''
    if ($parkSafe -and ($programs.Count -eq 0)) {
        $parkSafe = $false
        $parkDeferReason = '程序清单为空/缺失（目标缺失可能只是「程序还没还原」）'
    }
    if ($parkSafe) {
        $stageRoot = $Stage
        if ([string]::IsNullOrWhiteSpace($stageRoot)) { $stageRoot = [string]$env:CLOUDRDP_SNAPSHOT_STAGE }
        $exportFile = ''
        $statusFile = $ReinstallStatusPath
        if (-not [string]::IsNullOrWhiteSpace($stageRoot)) {
            if ([string]::IsNullOrWhiteSpace($exportFile)) { $exportFile = Join-Path $stageRoot 'apps\winget-export.json' }
            if ([string]::IsNullOrWhiteSpace($statusFile)) { $statusFile = Join-Path $stageRoot '_logs\apps-status.json' }
        }
        # 有重装清单 = 步骤 10 会装东西 → 目标可能稍后出现
        $reinstallEnabled = (-not [string]::IsNullOrWhiteSpace($exportFile)) -and (Test-Path -LiteralPath $exportFile)
        if ($reinstallEnabled) {
            $rsState = ''
            if (-not [string]::IsNullOrWhiteSpace($statusFile) -and (Test-Path -LiteralPath $statusFile)) {
                try { $rsState = [string](Get-Content -LiteralPath $statusFile -Raw -Encoding UTF8 | ConvertFrom-Json).state } catch { $rsState = '' }
            }
            if ($rsState -ne 'done') {
                $parkSafe = $false
                $parkDeferReason = ("后台 winget 重装未结束（state=" + $(if ($rsState) { $rsState } else { '未开始' }) + "）")
            }
        }
    }
    if (-not $parkSafe -and $ParkBroken) {
        $lines.Add("PARKDEFER 暂不移入「$ParkFolder」：$parkDeferReason")
        $parkDeferred++
    }

    $com = $null
    try { $com = New-Object -ComObject WScript.Shell } catch { }

    foreach ($d in $Dirs) {
        if ([string]::IsNullOrWhiteSpace($d) -or -not (Test-Path -LiteralPath $d)) { continue }
        $parkDir = Join-Path $d $ParkFolder
        $parkRe  = '(?i)\\' + [regex]::Escape($ParkFolder) + '\\'

        foreach ($l in @(Get-ChildItem -LiteralPath $d -File -Recurse -ErrorAction SilentlyContinue |
                          Where-Object { $_.Extension -eq '.lnk' -or $_.Extension -eq '.url' })) {
            if ($l.FullName -match $parkRe) { continue }
            $checked++

            # ---------- .url ----------
            if ($l.Extension -eq '.url') {
                $broken = $false; $local = ''
                try {
                    $txt = Get-Content -LiteralPath $l.FullName -Raw -Encoding Default
                    $m = [regex]::Match($txt, '(?im)^\s*URL\s*=\s*(.+)$')
                    if ($m.Success) {
                        $u = $m.Groups[1].Value.Trim()
                        if ($u -match '^(?i)file:/*(.+)$') {
                            $local = ($Matches[1] -replace '/', '\')
                            if (-not (Test-Path -LiteralPath $local)) { $broken = $true }
                        }
                    }
                } catch { }
                if (-not $broken) { $ok++; continue }
                if ($parkSafe) {
                    try {
                        New-Item -ItemType Directory -Force -Path $parkDir | Out-Null
                        $dest = Join-Path $parkDir $l.Name
                        if (Test-Path -LiteralPath $dest) { $dest = Join-Path $parkDir ([IO.Path]::GetFileNameWithoutExtension($l.Name) + "_" + [guid]::NewGuid().ToString('N').Substring(0, 6) + $l.Extension) }
                        Move-Item -LiteralPath $l.FullName -Destination $dest -Force -ErrorAction Stop
                        $parked++; $lines.Add("PARKED    $($l.Name) -> 本地目标缺失: $local")
                    } catch { $skipped++; $lines.Add("SKIP      $($l.Name)（移动失败）") }
                } else { $skipped++; $lines.Add("BROKEN    $($l.Name) -> 本地目标缺失: $local") }
                continue
            }

            # ---------- .lnk ----------
            if (-not $com) { $skipped++; $lines.Add("SKIP      $($l.Name)（WScript.Shell 不可用，整批跳过）"); continue }
            $sc = $null
            try { $sc = $com.CreateShortcut($l.FullName) } catch { $skipped++; $lines.Add("SKIP      $($l.Name)（CreateShortcut 异常：$($_.Exception.Message)）"); continue }
            $target = [string]$sc.TargetPath
            if ([string]::IsNullOrWhiteSpace($target)) { $skipped++; $lines.Add("SKIP      $($l.Name)（无目标路径，特殊快捷方式）"); continue }
            if (Test-Path -LiteralPath $target) { $ok++; continue }

            # 修复 ①：目标里的「别的用户名」改写成当前用户目录（快照把旧用户名烤死在 lnk 里）
            $remapped = Get-RemappedUserPath -Path $target -NewUserName $remapNew -OldUserName $remapOld
            if ($remapped) {
                try {
                    $sc.TargetPath = $remapped
                    $wdNow = [string]$sc.WorkingDirectory
                    $wdNew = Get-RemappedUserPath -Path $wdNow -NewUserName $remapNew -OldUserName $remapOld
                    if ($wdNew) { $sc.WorkingDirectory = $wdNew }
                    $sc.Save()
                    $repaired++
                    $lines.Add("REPAIRED  $($l.Name): $target  ->  $remapped（用户目录名改写）")
                    continue
                } catch { }
            }

            # 修复 ②：按文件名在已还原程序里唯一定位（含数据目录 / 便携程序暂存根的兜底）
            $leaf = Split-Path -Path $target -Leaf
            $hit  = Find-RestoredFile -FileName $leaf -ProgramEntries $programs -AdditionalDirs $AdditionalDirs
            if ($hit) {
                try {
                    $sc.TargetPath = $hit
                    if (-not [string]::IsNullOrWhiteSpace([string]$sc.WorkingDirectory)) {
                        $sc.WorkingDirectory = Split-Path -Path $hit -Parent
                    }
                    $sc.Save()
                    $repaired++; $lines.Add("REPAIRED  $($l.Name): $target  ->  $hit")
                    continue
                } catch { }
            }

            # 修不好 → park
            if ($parkSafe) {
                try {
                    New-Item -ItemType Directory -Force -Path $parkDir | Out-Null
                    $dest = Join-Path $parkDir $l.Name
                    if (Test-Path -LiteralPath $dest) { $dest = Join-Path $parkDir ([IO.Path]::GetFileNameWithoutExtension($l.Name) + "_" + [guid]::NewGuid().ToString('N').Substring(0, 6) + $l.Extension) }
                    Move-Item -LiteralPath $l.FullName -Destination $dest -Force -ErrorAction Stop
                    $parked++; $lines.Add("PARKED    $($l.Name) -> 目标缺失: $target")
                } catch { $skipped++; $lines.Add("SKIP      $($l.Name)（移动失败）") }
            } else {
                $skipped++; $lines.Add("BROKEN    $($l.Name) -> 目标缺失: $target")
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        try {
            $dir = Split-Path -Path $LogPath -Parent
            if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            $head = ("[{0}] 快捷方式校验：检查 {1} / 正常 {2} / 修复 {3} / 移入失效 {4} / 暂缓 {5} / 跳过 {6}" -f (Get-Date).ToString('s'), $checked, $ok, $repaired, $parked, $parkDeferred, $skipped)
            ([object[]]@($head) + [object[]]$lines.ToArray()) | Out-File -LiteralPath $LogPath -Append -Encoding UTF8
        } catch { }
    }

    return @{ checked = $checked; ok = $ok; repaired = $repaired; parked = $parked; parkDeferred = $parkDeferred; skipped = $skipped }
}
