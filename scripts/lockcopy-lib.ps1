# ============================================================================
#  被占用文件的容错复制 + 「无还原价值」文件名判定
# ============================================================================
#
#  .SYNOPSIS
#    解决 Chromium 系浏览器（Edge / Chrome）用户数据在跨机备份还原时报假失败的问题。
#
#  .DESCRIPTION
#    浏览器用 LevelDB 存本地数据，运行时以【独占方式】持有这些文件：
#      · LOCK      —— 0 字节的文件锁
#      · LOG       —— LevelDB 的人类可读日志
#      · LOG.old   —— 上一份 LOG
#
#    后果（真机实测）：
#      备份侧：robocopy 复制失败 → manifest 里 robocopy 返回码 9（8 = 有文件没复制成）
#      还原侧：robocopy 覆盖失败 → 返回码 >= 8 → 整个 Edge 目录被误判为「还原失败」
#              → 桌面出现 _CloudRDP_还原失败.txt
#
#    而这些文件毫无还原价值：LOCK 是锁、LOG/LOG.old 是日志，浏览器下次启动自行重建。
#
#    因此本库提供两件事：
#      1) Test-IgnorableFileName —— 把上述文件判为「可忽略失败」，不算还原失败
#      2) Copy-FileShared        —— 用双向 FileShare.ReadWrite 重试真失败的文件
#                                   （robocopy 用独占写打开目标，遇到占用必败）
#
#  .NOTES
#    只做「补写」，不做删除；不改任何既有还原语义（robocopy 依旧不加 /PURGE）。
# ============================================================================

# 无还原价值的运行时文件名（大小写不敏感）
$script:IgnorableRuntimeFileNames = @('LOCK', 'LOG', 'LOG.old')

<#
.SYNOPSIS
  判断文件名是否属于「无还原价值」的浏览器运行时文件。
.PARAMETER Path
  文件名或完整路径（只看最后一段）。
.OUTPUTS
  [bool]
#>
function Test-IgnorableFileName {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $n = [System.IO.Path]::GetFileName($Path)
    if ([string]::IsNullOrWhiteSpace($n)) { return $false }
    foreach ($x in @($script:IgnorableRuntimeFileNames)) {
        if ([string]::Equals($n, $x, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

<#
.SYNOPSIS
  共享读写复制单个文件 —— 即使源/目标正被别的进程占用也能成功。
.PARAMETER Source
  源文件绝对路径。
.PARAMETER Destination
  目标文件绝对路径（父目录不存在会自动创建）。
.PARAMETER BufferSize
  复制缓冲区字节数，默认 1 MB。
.OUTPUTS
  [hashtable] @{ ok = [bool]; reason = [string]; bytes = [long] }
.NOTES
  与 robocopy 的区别：robocopy 以独占方式打开目标（GENERIC_WRITE，无共享位），
  目标被浏览器/索引服务占用时直接失败；这里两侧都带 FileShare.ReadWrite，可以写进去。
#>
function Copy-FileShared {
    param(
        [string]$Source,
        [string]$Destination,
        [int]$BufferSize = 1MB
    )

    $res = @{ ok = $false; reason = ''; bytes = [long]0 }
    if ([string]::IsNullOrWhiteSpace($Source) -or [string]::IsNullOrWhiteSpace($Destination)) {
        $res.reason = '参数为空'
        return $res
    }
    if (-not (Test-Path -LiteralPath $Source)) {
        $res.reason = '源不存在'
        return $res
    }
    if ($BufferSize -le 0) { $BufferSize = 1MB }

    $dir = Split-Path -Path $Destination -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        try { New-Item -ItemType Directory -Force -Path $dir | Out-Null } catch { }
    }

    $inS = $null
    $outS = $null
    try {
        $inS = [System.IO.File]::Open(
            $Source,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite)
        $outS = [System.IO.File]::Open(
            $Destination,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::ReadWrite)

        $buf = [byte[]]::new($BufferSize)
        $total = [long]0
        while ($true) {
            $n = $inS.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $outS.Write($buf, 0, $n)
            $total += $n
        }
        $outS.Flush()
        $res.ok = $true
        $res.bytes = $total
    } catch {
        $res.reason = $_.Exception.Message
    } finally {
        if ($outS) { try { $outS.Dispose() } catch { } }
        if ($inS)  { try { $inS.Dispose() }  catch { } }
    }

    # 保留源文件时间戳（对齐 robocopy /COPY:DAT 的语义）
    if ($res.ok) {
        try {
            $si = Get-Item -LiteralPath $Source -Force
            $di = Get-Item -LiteralPath $Destination -Force
            if ($si.LastWriteTimeUtc.Year -gt 1601) { $di.LastWriteTimeUtc = $si.LastWriteTimeUtc }
        } catch { }
    }
    return $res
}

<#
.SYNOPSIS
  从 robocopy 输出里解析出「复制失败」的文件路径。
.PARAMETER RobocopyOutput
  robocopy 的逐行输出（stdout + stderr 合并）。
.OUTPUTS
  [string[]] 失败的绝对路径（拿不到则为空数组）
.NOTES
  中/英文两种 robocopy 的失败行格式：
    2026/09/18 10:06:30 错误 32 (0x00000020) 正在复制文件 C:\...\LOCK
    2026/09/18 10:06:30 ERROR 32 (0x00000020) Copying File C:\...\LOCK
#>
function Get-RobocopyFailedFile {
    param([string[]]$RobocopyOutput)

    # 去重：robocopy 对同一个失败文件会打印两次（目录扫描阶段 + 复制阶段），
    # 不去重会让调用方对同一文件重复重试。-contains 对字符串是大小写不敏感的。
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($ln in @($RobocopyOutput)) {
        if ([string]::IsNullOrWhiteSpace($ln)) { continue }
        if ($ln -match '^\s*(?:\d{4}[/-]\d{2}[/-]\d{2}\s+\d{2}:\d{2}:\d{2}\s+)?(?:错误|ERROR)\s+\d+\s+\(0x[0-9A-Fa-f]+\)\s+\S+\s+(.+?)\s*$') {
            $p = $Matches[1].Trim()
            if (-not ($out -contains $p)) { $out.Add($p) }
        }
    }
    return $out.ToArray()
}

<#
.SYNOPSIS
  把某根目录下的绝对路径还原成相对路径（拿不到返回 $null）。
#>
function Get-RelPathUnder {
    param([string]$Path, [string]$Root)
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $null }
    $p = $Path.TrimEnd('\')
    $r = $Root.TrimEnd('\')
    if ($p.Length -le $r.Length) { return $null }
    if (-not $p.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $p.Substring($r.Length).TrimStart('\')
}
