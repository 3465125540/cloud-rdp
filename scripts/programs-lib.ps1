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

# 枚举三处 Uninstall 注册表，返回程序条目
function Get-InstalledPrograms {
    $hives = @(
        @{ parent = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall';             scope = 'machine' },
        @{ parent = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; scope = 'machine' },
        @{ parent = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall';             scope = 'user' }
    )
    $list = New-Object System.Collections.Generic.List[object]

    foreach ($h in $hives) {
        if (-not (Test-Path -LiteralPath $h.parent)) { continue }
        foreach ($k in @(Get-ChildItem -LiteralPath $h.parent -ErrorAction SilentlyContinue)) {
            $props = $null
            try { $props = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop } catch { continue }
            if ($null -eq $props) { continue }

            $est = 0
            if ($props.EstimatedSize) { try { $est = [int]$props.EstimatedSize } catch { $est = 0 } }

            $list.Add([pscustomobject]@{
                regPath          = (Convert-ProgramRegPath -PSPath $k.PSPath)
                keyName          = [string]$k.PSChildName
                scope            = [string]$h.scope
                displayName      = [string]$props.DisplayName
                version          = [string]$props.DisplayVersion
                publisher        = [string]$props.Publisher
                installLocation  = [string]$props.InstallLocation
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
        [string[]]$ExcludePaths          = @(),   # 已被 portable 处理过的目录
        [string[]]$SystemRoots           = @(),
        [string[]]$ImageBlockPaths       = @(),
        [string[]]$Blocklist             = @(),
        [int]     $MaxMBPerApp           = 1024,
        [int]     $MaxTotalMB            = 2048
    )

    $baseSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($x in $BaselineRegPaths)      { if ($x) { [void]$baseSet.Add($x.ToLower()) } }
    $prevSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($x in $AlwaysIncludeRegPaths) { if ($x) { [void]$prevSet.Add($x.ToLower()) } }

    $selected = New-Object System.Collections.Generic.List[object]
    $skipped  = New-Object System.Collections.Generic.List[string]
    $seen     = New-Object 'System.Collections.Generic.HashSet[string]'
    $totalBytes = [long]0

    foreach ($a in $All) {
        $name = [string]$a.displayName
        $loc  = ([string]$a.installLocation).TrimEnd('\')

        if (-not (Test-ProgramCandidate -Entry $a -SystemRoots $SystemRoots -ImageBlockPaths $ImageBlockPaths -Blocklist $Blocklist)) {
            continue
        }
        if (-not $seen.Add($loc.ToLower())) { continue }

        $excluded = $false
        foreach ($ep in $ExcludePaths) {
            if (-not [string]::IsNullOrWhiteSpace($ep) -and $loc.ToLower().StartsWith($ep.TrimEnd('\').ToLower())) { $excluded = $true; break }
        }
        if ($excluded) { continue }

        $regKey  = ([string]$a.regPath).ToLower()
        $isNew   = -not $baseSet.Contains($regKey)
        $isPrev  = $prevSet.Contains($regKey)
        if (-not $isNew -and -not $isPrev) { continue }      # 镜像自带的，跳过

        $size = [long]$a.estimatedSizeKB * 1KB
        if ($size -le 0) { $size = Get-ProgramTreeBytes -Path $loc }
        if (($size / 1MB) -gt $MaxMBPerApp) {
            $skipped.Add(("{0}（{1:N0} MB > 单程序上限 {2} MB）" -f $name, ($size / 1MB), $MaxMBPerApp))
            continue
        }
        if ((($totalBytes + $size) / 1MB) -gt $MaxTotalMB) {
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
            reason           = $(if ($isNew) { 'new' } else { 'prev' })
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
            if (-not [string]::IsNullOrWhiteSpace([string]$a.regPath)) {
                & reg.exe export "$($a.regPath)" "$regFile" /y 2>&1 | Out-Null
                $regOk = ($LASTEXITCODE -eq 0)
            }
            if (-not $regOk) { $problems.Add("reg:$($a.displayName)") }

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
                regPath          = [string]$a.regPath
                regFile          = $(if ($regOk) { $regLeaf } else { '' })
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
        [switch]  $InvertScope
    )

    $restored  = 0
    $junctioned = 0
    $problems  = New-Object System.Collections.Generic.List[string]
    $regDir    = Join-Path (Join-Path $Stage "programs") "_registry"
    $prefix    = if ([string]::IsNullOrWhiteSpace($UserPrefix)) { '' } else { $UserPrefix.ToLower() }

    foreach ($e in @($Entries)) {
        $orig = [string]$e.originalPath
        if ([string]::IsNullOrWhiteSpace($orig)) { continue }

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
