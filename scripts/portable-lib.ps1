<#
.SYNOPSIS
  可移动（便携 / 绿色）程序的识别、搬运与还原 —— 共享函数库。

.DESCRIPTION
  被 backup-snapshot.ps1 与 restore-snapshot.ps1 以 dot-source 方式加载，本身不执行任何动作。

  设计要点：
  · 识别默认**保守**（宁可漏，不可误移）：只认「非 MSI 安装 + 非系统目录 + 自包含」的程序。
  · 搬运默认 **copy 不是 move** —— move 会破坏正在运行的机器（快捷方式 / 注册表引用失效），
    而且每 60 分钟抓一次快照会反复搬。可选 `-Mode relocate` 用 junction 实现「只留一份实体」。
  · **原安装路径**是权威元数据（`originalPath` 绝对路径），还原时按它精确放回。
  · 元数据同时写三处：<DestRoot>\_manifest.json、<Stage>\apps\portable.json、manifest.json 的 apps.portable[]

.NOTES
  所有函数名以 Get-Portable / Copy-Portable / Restore-Portable / Test-Portable / Get-PortableMirrorRel
  开头，避免与 backup-snapshot.ps1 内的同名工具函数冲突。
#>

# ---------------------------------------------------------------- 通用小工具

function Get-PortableTreeBytes {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [long]0 }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
    if (-not $sum) { return [long]0 }
    return [long]$sum
}

# C:\apps\Foo -> C\apps\Foo
function Get-PortableMirrorRel {
    param([string]$Abs)
    $a = $Abs.TrimEnd('\')
    $a = $a -replace '^([A-Za-z]):', '$1'
    return ($a -replace '^[\\/]+', '')
}

# ---------------------------------------------------------------- 识别

function Get-PortableSystemRoots {
    return @(
        'C:\Windows',
        'C:\Program Files',
        'C:\Program Files (x86)',
        'C:\ProgramData',
        'C:\Program Files\WindowsApps'
    )
}

# 判定一条 Uninstall 记录是否为「可移动程序」。全部条件必须同时满足。
function Test-PortableCandidate {
    param($Entry, [string[]]$SystemRoots, [string[]]$Blocklist)

    if ([string]::IsNullOrWhiteSpace([string]$Entry.DisplayName)) { return $false }
    if ($Entry.SystemComponent -eq 1) { return $false }
    if (-not [string]::IsNullOrWhiteSpace([string]$Entry.ParentKeyName)) { return $false }

    $rt = [string]$Entry.ReleaseType
    if ($rt -match '(?i)Update|Hotfix|Security|ServicePack') { return $false }

    # 排除 MSI 安装（MSI 有自己的安装数据库，搬目录没意义）
    if ($Entry.WindowsInstaller -eq 1) { return $false }
    if ([string]$Entry.UninstallString -match '(?i)msiexec') { return $false }

    # 排除微软自家组件
    if ([string]$Entry.Publisher -match '(?i)^Microsoft') { return $false }
    foreach ($b in $Blocklist) {
        if (-not [string]::IsNullOrWhiteSpace($b) -and ([string]$Entry.DisplayName -match $b)) { return $false }
    }

    $loc = [string]$Entry.InstallLocation
    if ([string]::IsNullOrWhiteSpace($loc)) { return $false }
    $loc = $loc.TrimEnd('\')
    if (-not (Test-Path -LiteralPath $loc)) { return $false }

    # 排除落在系统目录里的（那里面的东西不该被搬走）
    $ll = $loc.ToLower()
    foreach ($sr in $SystemRoots) {
        $s = $sr.TrimEnd('\').ToLower()
        if ($ll -eq $s -or $ll.StartsWith($s + '\')) { return $false }
    }

    # 至少有一个顶层 exe
    if (@(Get-ChildItem -LiteralPath $loc -Filter *.exe -File -ErrorAction SilentlyContinue).Count -eq 0) { return $false }

    return $true
}

function Get-PortableApps {
    param(
        [string[]]$ScanRoots      = @(),
        [string[]]$Blocklist      = @(),
        [int]     $MaxMBPerApp    = 2048,
        [int]     $MaxTotalMB     = 8192
    )

    $systemRoots = Get-PortableSystemRoots
    $results = New-Object System.Collections.Generic.List[object]
    $seen    = New-Object 'System.Collections.Generic.HashSet[string]'
    $totalBytes = [long]0

    # ---------- 主层：Uninstall 注册表 ----------
    $uninstPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($p in $uninstPaths) {
        foreach ($e in @(Get-ItemProperty -Path $p -ErrorAction SilentlyContinue)) {
            if (-not (Test-PortableCandidate -Entry $e -SystemRoots $systemRoots -Blocklist $Blocklist)) { continue }
            $loc = ([string]$e.InstallLocation).TrimEnd('\')
            if (-not $seen.Add($loc.ToLower())) { continue }
            $size = Get-PortableTreeBytes -Path $loc
            if (($size / 1MB) -gt $MaxMBPerApp) { continue }
            if ((($totalBytes + $size) / 1MB) -gt $MaxTotalMB) { continue }
            $totalBytes += $size
            $results.Add([pscustomobject]@{
                name         = ($loc -replace '^.*\\', '')
                displayName  = [string]$e.DisplayName
                publisher    = [string]$e.Publisher
                version      = [string]$e.DisplayVersion
                originalPath = $loc
                bytes        = $size
                source       = 'registry'
            })
        }
    }

    # ---------- 辅层：目录扫描（抓没有注册表记录的绿色软件）----------
    foreach ($root in $ScanRoots) {
        if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root)) { continue }
        foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            $loc = $d.FullName
            if (-not $seen.Add($loc.ToLower())) { continue }
            # 有卸载器 = 是安装型软件，交给注册表层处理
            if (@(Get-ChildItem -LiteralPath $loc -Filter 'uninstall*.exe' -File -ErrorAction SilentlyContinue).Count -gt 0) { continue }
            if (@(Get-ChildItem -LiteralPath $loc -Filter *.exe -File -ErrorAction SilentlyContinue).Count -eq 0) { continue }
            $size = Get-PortableTreeBytes -Path $loc
            if (($size / 1MB) -gt $MaxMBPerApp) { continue }
            if ((($totalBytes + $size) / 1MB) -gt $MaxTotalMB) { continue }
            $totalBytes += $size
            $results.Add([pscustomobject]@{
                name         = $d.Name
                displayName  = $d.Name
                publisher    = ''
                version      = ''
                originalPath = $loc
                bytes        = $size
                source       = 'scan'
            })
        }
    }

    return $results.ToArray()
}

# ---------------------------------------------------------------- 搬运（备份侧）

function Copy-PortableApps {
    param(
        [object[]]$Apps,
        [string]  $DestRoot,
        [string]  $Mode = 'copy'          # copy | relocate
    )

    $captured = New-Object System.Collections.Generic.List[object]
    $problems = New-Object System.Collections.Generic.List[string]

    if (-not $Apps -or $Apps.Count -eq 0) {
        return @{ captured = @(); problems = @() }
    }
    New-Item -ItemType Directory -Force -Path $DestRoot | Out-Null

    foreach ($a in $Apps) {
        try {
            $rel = Get-PortableMirrorRel -Abs $a.originalPath
            $dst = Join-Path $DestRoot $rel
            New-Item -ItemType Directory -Force -Path $dst | Out-Null

            & robocopy $a.originalPath $dst /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP /XJ /XO 2>&1 | Out-Null
            $code = $LASTEXITCODE
            if ($code -ge 8) {
                $problems.Add("portable:$($a.originalPath) (robocopy $code)")
                continue
            }

            $actualMode = 'copy'

            # 可选 relocate：校验拷贝成功后，把原目录换成指向副本的 junction（只留一份实体）
            if ($Mode -eq 'relocate') {
                $bak = $a.originalPath + '.cloudrdp-orig'
                if (-not (Test-Path -LiteralPath $bak)) {
                    try {
                        Move-Item -LiteralPath $a.originalPath -Destination $bak -Force -ErrorAction Stop
                        & cmd.exe /c mklink /J "$($a.originalPath)" "$dst" 2>&1 | Out-Null
                        if ($LASTEXITCODE -eq 0) {
                            $actualMode = 'relocate'
                        } else {
                            Move-Item -LiteralPath $bak -Destination $a.originalPath -Force -ErrorAction SilentlyContinue
                            $problems.Add("relocate-junction:$($a.originalPath)")
                        }
                    } catch {
                        if (Test-Path -LiteralPath $bak) {
                            Move-Item -LiteralPath $bak -Destination $a.originalPath -Force -ErrorAction SilentlyContinue
                        }
                        $problems.Add("relocate-move:$($a.originalPath)")
                    }
                } else {
                    $actualMode = 'relocate'    # 之前已 relocate 过
                }
            }

            $captured.Add([pscustomobject]@{
                name         = $a.name
                displayName  = $a.displayName
                publisher    = $a.publisher
                version      = $a.version
                originalPath = $a.originalPath
                mirrorRel    = $rel
                storedPath   = $dst
                bytes        = (Get-PortableTreeBytes -Path $dst)
                mode         = $actualMode
                source       = $a.source
                capturedUtc  = (Get-Date).ToUniversalTime().ToString('o')
            })
        } catch {
            $problems.Add("portable-ex:$($a.originalPath)")
        }
    }

    return @{ captured = $captured.ToArray(); problems = $problems.ToArray() }
}

# 写出便携程序清单（供还原侧消费）
function Write-PortableManifest {
    param([object[]]$Apps, [string]$Path)
    # 注意：本机 PS 5.1 下 @(<泛型List>) 会抛「参数类型不匹配」，必须用 [object[]] 转换
    $arr = [object[]]$Apps
    $obj = [ordered]@{
        version     = 1
        capturedUtc = (Get-Date).ToUniversalTime().ToString('o')
        count       = $arr.Count
        apps        = $arr
    }
    $dir = Split-Path $Path -Parent
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $obj | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $Path -Encoding UTF8
}

# ---------------------------------------------------------------- 还原（还原侧）

# 按 originalPath 把便携程序放回原位。
# -UserPrefix：若非空，则只还原 originalPath 落在该前缀下的条目（用于 machine/user 作用域分流）。
function Restore-PortableApps {
    param(
        [string]$ManifestPath,
        [string]$UserPrefix = '',
        [switch]$InvertScope              # 与 UserPrefix 取反：只还原「不在用户目录下」的
    )

    $restored = 0
    $problems = New-Object System.Collections.Generic.List[string]

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        return @{ restored = 0; problems = @('no-manifest'); skipped = $true }
    }
    $mf = $null
    try { $mf = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return @{ restored = 0; problems = @('bad-manifest'); skipped = $true } }

    $prefix = if ([string]::IsNullOrWhiteSpace($UserPrefix)) { '' } else { $UserPrefix.ToLower() }

    foreach ($e in @($mf.apps)) {
        $orig = [string]$e.originalPath
        if ([string]::IsNullOrWhiteSpace($orig)) { continue }

        if ($prefix) {
            $inUser = $orig.ToLower().StartsWith($prefix)
            if ($InvertScope) { if ($inUser) { continue } }
            else             { if (-not $inUser) { continue } }
        }

        if (-not (Test-Path -LiteralPath $e.storedPath)) {
            $problems.Add("missing-store:$orig")
            continue
        }

        New-Item -ItemType Directory -Force -Path $orig | Out-Null
        & robocopy $e.storedPath $orig /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP /XJ 2>&1 | Out-Null
        if ($LASTEXITCODE -ge 8) {
            $problems.Add("restore:$orig (robocopy $LASTEXITCODE)")
        } else {
            $restored++
        }
    }

    return @{ restored = $restored; problems = $problems.ToArray(); skipped = $false }
}
