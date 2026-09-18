<#
.SYNOPSIS
    注册表导入容错库：把 reg.exe import 的「部分成功」正确识别出来。

.DESCRIPTION
    背景（实测，2026-09-17）：
      reg.exe import 是 best-effort —— 能写的键都写，个别键写不了时
      返回 exit=1 并报「并未将所有数据都成功写入到注册表中」。
      旧代码把 exit!=0 一律当「整个文件还原失败」→ 用户看到
      「个人配置还原失败: reg:HKCU-Software.reg」的误报，
      而实际上 3934 个键里只 9 个没写进去（99.8% 成功）。

    写不进去的键分两类，都属于「不该让还原判失败」：
      1. **Windows 保护键**：默认程序关联 UserChoice
         （...\Explorer\FileExts\<ext>\UserChoice、...\UrlAssociations\http\UserChoice 等），
         系统给它们加了防劫持 ACL，管理员也写不进 —— 这是设计如此。
      2. **被系统进程占用的键**：CurrentVersion\Feeds / Search / SearchSettings 等
         （搜索索引、Feed 服务持有句柄）。

    本库的做法：
      · 先整文件导入一次（最快路径，绝大多数文件一次就 exit 0）；
      · 失败时把文件按 [键] 块拆开逐块导入，精确收集失败键名；
      · 部分块成功 = partial（数据基本都回来了）→ 调用方只记告警，不计失败；
      · 全部块都失败 = failed → 调用方才记 problem。

.NOTES
    拆块时每个临时块文件都带 "Windows Registry Editor Version 5.00" 头；
    临时文件放 $env:TEMP，用完即删。
#>

function Invoke-RegImportTolerant {
    param(
        [Parameter(Mandatory = $true)][string]$RegFile,
        # 只收集失败键名用；>0 时拆块重试（0 = 不拆块，直接整文件判定）
        [int]$MaxBlockRetry = 4000
    )

    $result = [ordered]@{
        ok         = $false      # 整文件一次成功
        partial    = $false      # 部分块成功（数据基本已还原）
        failed     = $false      # 全部块都失败 / 文件不可读
        failedKeys = @()         # 失败的键名（[xxx] 里的内容）
        blocks     = 0
        failedN    = 0
    }

    if (-not (Test-Path -LiteralPath $RegFile)) {
        $result.failed = $true
        $result.failedKeys = @("<file missing: $RegFile>")
        return $result
    }

    # ---------- 快速路径：整文件导入 ----------
    & reg.exe import $RegFile 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $result.ok = $true
        return $result
    }

    # ---------- 慢速路径：拆块定位 ----------
    $txt = $null
    try { $txt = Get-Content -LiteralPath $RegFile -Raw -Encoding Unicode } catch { }
    if ([string]::IsNullOrWhiteSpace($txt)) {
        $result.failed = $true
        $result.failedKeys = @('<unreadable or empty>')
        return $result
    }

    $lines = $txt -split "`r`n|`n"
    $blocks = New-Object System.Collections.Generic.List[object]
    $cur = $null
    foreach ($ln in $lines) {
        if ($ln.StartsWith('[')) {
            if ($null -ne $cur) { $blocks.Add($cur) }
            $cur = New-Object System.Collections.Generic.List[string]
            $cur.Add($ln)
        } elseif ($null -ne $cur) {
            $cur.Add($ln)
        }
    }
    if ($null -ne $cur) { $blocks.Add($cur) }

    $result.blocks = $blocks.Count
    if ($blocks.Count -eq 0) {
        $result.failed = $true
        $result.failedKeys = @('<no key blocks>')
        return $result
    }

    $failedKeys = New-Object System.Collections.Generic.List[string]
    $i = 0
    foreach ($b in $blocks) {
        $i++
        if ($i -gt $MaxBlockRetry) { break }
        $tmp = Join-Path $env:TEMP ("regblk_" + [guid]::NewGuid().ToString('N') + ".reg")
        try {
            (@('Windows Registry Editor Version 5.00', '') + [string[]]$b.ToArray()) -join "`r`n" |
                Out-File -LiteralPath $tmp -Encoding Unicode -Force
            & reg.exe import $tmp 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                $key = [string]$b[0]
                $key = $key.TrimStart('[').TrimEnd(']')
                $failedKeys.Add($key)
            }
        } catch {
            $failedKeys.Add([string]$b[0])
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    $result.failedN    = $failedKeys.Count
    $result.failedKeys = $failedKeys.ToArray()
    $result.partial    = ($failedKeys.Count -gt 0) -and ($failedKeys.Count -lt $blocks.Count)
    $result.failed     = ($failedKeys.Count -ge $blocks.Count)
    if ($failedKeys.Count -eq 0) { $result.ok = $true }   # 理论上不会走到（整文件已失败）
    return $result
}

# 把失败键列表压成一行日志文本（最多 N 个，超出显示 …+n）
function Format-RegFailedKeys {
    param([string[]]$Keys, [int]$Max = 6)
    if (-not $Keys -or $Keys.Count -eq 0) { return '' }
    $show = $Keys | Select-Object -First $Max
    $s = $show -join ' ; '
    if ($Keys.Count -gt $Max) { $s += (" …+" + ($Keys.Count - $Max)) }
    return $s
}
