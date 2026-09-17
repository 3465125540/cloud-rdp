<#
.SYNOPSIS
  把暂存快照里的「旧 RDP 用户名」整体迁移成当前账号名（幂等、可反向自愈）。

.DESCRIPTION
  背景：快照按绝对路径镜像（%RDPUSERPROFILE%\Desktop -> files/C/Users/<name>/Desktop），
  且还原侧会用 manifest.rdpUser 覆盖当前用户名（restore-snapshot.ps1 第 168 / 534 行）。
  所以一旦改了 RDP 账号名，不做迁移就会出现「文件还原到旧 profile、以新账号登录看不到」
  的静默数据丢失。

  本脚本在 pre-restore 拉完快照之后、校验/规划/准备之前被调用，做三件事：

    1. 改目录名：files|programs\<盘>\Users\<Old>  ->  ...\Users\<New>
    2. 改 JSON  ：$Stage 下所有 *.json 的每个字符串值
                  （\Users\Old 与 /Users/Old 两种形式），并把 rdpUser 字段置为 <New>
    3. 改 REG   ：$Stage 下所有 *.reg（UTF-16LE）
                  先替换「双反斜杠转义」形式再替换「单反斜杠」形式，避免破坏 .reg 转义；
                  HKEY_USERS\__RDPUSER__ 占位符不动（它是 SID 归一化的锚点）

  幂等      ：manifest.rdpUser 已等于目标名 -> 直接返回，不碰任何文件。
  反向自愈  ：账号改回去时同样会迁移回去（方向由「当前账号」决定）。
  不回推远端：由本次 run 收尾的全量推送（rclone copy / sync）负责同步。
  不碰 .lnk ：二进制，死链交由还原后的 Repair-Shortcuts 修复。

.NOTES
  参数：
    -Stage    暂存根（如 D:\cloudrdp-sys\_snapshot）
    -NewName  当前账号名
    -OldName  旧账号名；缺省取 manifest.rdpUser
  失败时 throw —— 调用方用 try/catch 兜住，保证不阻断开机。
  刻意不用 exit：本脚本由 pre-restore.ps1 以 & 方式调用，exit 会牵连调用方作用域。
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Stage,
    [Parameter(Mandatory)][string]$NewName,
    [string]$OldName
)

$ErrorActionPreference = 'Stop'

function Say   ([string]$m) { Write-Host "[migrate] $m" }
function WarnM ([string]$m) { Write-Host "[migrate] $m" -ForegroundColor Yellow }
function Set-Status([string]$s) {
    if ($env:GITHUB_ENV) { "SNAPSHOT_USERMIGRATE=$s" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding ascii }
}

if ([string]::IsNullOrWhiteSpace($NewName)) { throw '缺少 -NewName' }
if (-not (Test-Path -LiteralPath $Stage)) { Say "暂存目录不存在：$Stage（跳过）"; Set-Status 'SKIPPED'; return }

$manifestPath = Join-Path $Stage 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { Say '无 manifest.json（首次运行），跳过迁移'; Set-Status 'SKIPPED'; return }

$mf = $null
try { $mf = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json }
catch { Set-Status 'FAILED'; throw "manifest.json 解析失败：$_" }

# 以 manifest 记录的用户名为准 —— 幂等性必须建立在「快照的真实状态」上，
# 不能依赖调用方传进来的 -OldName（它可能是过期值，会导致重复改写）。
$mfUser = [string]$mf.rdpUser
if (-not [string]::IsNullOrWhiteSpace($mfUser)) {
    if ($OldName -and ($OldName -ne $mfUser)) {
        WarnM "  -OldName（$OldName）与 manifest.rdpUser（$mfUser）不一致 —— 以 manifest 为准"
    }
    $OldName = $mfUser
}
if ([string]::IsNullOrWhiteSpace($OldName)) { Say '快照未记录用户名，跳过迁移'; Set-Status 'SKIPPED'; return }
if ($OldName -eq $NewName) { Say "快照用户名已是 $NewName —— 无需迁移"; Set-Status 'SKIPPED'; return }

Say "用户名迁移：$OldName  ->  $NewName"

# ---------------------------------------------------------------- 0. 替换规则
$esc = [regex]::Escape($OldName)
# 单反斜杠形式（JSON 解码后的值；.reg 的键路径）
$reBs  = [regex]::new('(?i)\\Users\\'  + $esc + '(?=\\|/|$|")')
# 正斜杠形式（manifest 的 store / mirrorRel 用正斜杠）
$reFs  = [regex]::new('(?i)/Users/'   + $esc + '(?=/|\\|$|")')
# .reg 里的双反斜杠转义形式（必须最先替换，否则单反斜杠规则会破坏转义）
$reBs2 = [regex]::new('(?i)\\\\Users\\\\' + $esc + '(?=\\\\|/|$|")')
$repBs  = '\Users\'  + $NewName
$repFs  = '/Users/'  + $NewName
$repBs2 = '\\Users\\' + $NewName

function Rewrite-Str([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return $s }
    $r = $reBs2.Replace($s, $repBs2)   # 双反斜杠优先
    $r = $reBs.Replace($r, $repBs)
    $r = $reFs.Replace($r, $repFs)
    return $r
}

function Rewrite-Node($Node, [int]$Depth = 0) {
    if ($null -eq $Node -or $Depth -gt 12) { return }
    if ($Node -is [string] -or $Node -is [ValueType]) { return }
    if ($Node -is [System.Array]) {
        for ($i = 0; $i -lt $Node.Length; $i++) {
            $it = $Node[$i]
            if ($it -is [string]) { $Node[$i] = (Rewrite-Str $it) }
            elseif ($it -is [System.Array] -or $it -is [System.Management.Automation.PSCustomObject]) { Rewrite-Node $it ($Depth + 1) }
        }
        return
    }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($pr in @($Node.PSObject.Properties)) {
            if ($pr.Name -eq 'rdpUser') { $pr.Value = $NewName; continue }
            $v = $pr.Value
            if ($v -is [string]) { $pr.Value = (Rewrite-Str $v) }
            elseif ($v -is [System.Array] -or $v -is [System.Management.Automation.PSCustomObject]) { Rewrite-Node $v ($Depth + 1) }
        }
    }
}

# ---------------------------------------------------------------- 1. 改目录名
$dirCount = 0
foreach ($root in @('files', 'programs')) {
    $rootDir = Join-Path $Stage $root
    if (-not (Test-Path -LiteralPath $rootDir)) { continue }
    foreach ($drive in @(Get-ChildItem -LiteralPath $rootDir -Directory -ErrorAction SilentlyContinue)) {
        $usersDir = Join-Path $drive.FullName 'Users'
        if (-not (Test-Path -LiteralPath $usersDir)) { continue }
        $oldDir = Join-Path $usersDir $OldName
        if (-not (Test-Path -LiteralPath $oldDir)) { continue }
        $newDir = Join-Path $usersDir $NewName
        if (Test-Path -LiteralPath $newDir) {
            WarnM ("  目标已存在，先删除：{0}\{1}\Users\{2}" -f $root, $drive.Name, $NewName)
            Remove-Item -LiteralPath $newDir -Recurse -Force
        }
        Move-Item -LiteralPath $oldDir -Destination $newDir
        Say ("  [{0}\{1}] Users\{2} -> Users\{3}" -f $root, $drive.Name, $OldName, $NewName)
        $dirCount++
    }
}

# ---------------------------------------------------------------- 2. 改 JSON
$jsonFiles = @(Get-ChildItem -LiteralPath $Stage -Recurse -File -Filter '*.json' -ErrorAction SilentlyContinue)
$jsonCount = 0
$jsonSkipped = New-Object System.Collections.Generic.List[string]
foreach ($jf in $jsonFiles) {
    $obj = $null
    try { $obj = Get-Content -LiteralPath $jf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { WarnM ("  跳过（解析失败）：{0}" -f $jf.FullName); $jsonSkipped.Add($jf.FullName); continue }

    Rewrite-Node $obj
    $json = ConvertTo-Json -InputObject $obj -Depth 12

    # 先写临时文件校验，再原子替换 —— 避免序列化异常把快照写坏
    $tmp = $jf.FullName + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding $true))
    try { $null = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw ("改写后 JSON 无法解析，已放弃：{0}" -f $jf.FullName)
    }
    Move-Item -LiteralPath $tmp -Destination $jf.FullName -Force
    $jsonCount++
}
Say ("  JSON 已改写：{0} / {1}" -f $jsonCount, $jsonFiles.Count)

# ---------------------------------------------------------------- 3. 改 REG
$regFiles = @(Get-ChildItem -LiteralPath $Stage -Recurse -File -Filter '*.reg' -ErrorAction SilentlyContinue)
$regCount = 0
foreach ($rf in $regFiles) {
    $bytes = [System.IO.File]::ReadAllBytes($rf.FullName)
    $isUtf16 = ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE)
    $txt = if ($isUtf16) {
        [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    } else {
        [System.Text.Encoding]::UTF8.GetString($bytes)
    }
    if ([string]::IsNullOrEmpty($txt)) { continue }

    $new = $reBs2.Replace($txt, $repBs2)   # 双反斜杠优先，保护 .reg 转义
    $new = $reBs.Replace($new, $repBs)
    $new = $reFs.Replace($new, $repFs)
    if ($new -ne $txt) {
        if ($isUtf16) { [System.IO.File]::WriteAllText($rf.FullName, $new, [System.Text.Encoding]::Unicode) }
        else          { [System.IO.File]::WriteAllText($rf.FullName, $new, (New-Object System.Text.UTF8Encoding $false)) }
        $regCount++
    }
}
Say ("  REG 已改写：{0} / {1}" -f $regCount, $regFiles.Count)

# ---------------------------------------------------------------- 4. 校验
$mfTxt = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
if ($mfTxt -match [regex]::Escape($OldName)) {
    Set-Status 'FAILED'
    throw "manifest.json 仍残留旧用户名 $OldName —— 迁移不完整"
}

# 其它载体只告警（例如 _tools/snapshot-config.json 的注释里本来就有旧名）
$leftover = @()
foreach ($f in @($jsonFiles + $regFiles)) {
    if ($f.FullName -eq $manifestPath) { continue }
    try {
        $t = if ($f.Extension -eq '.reg') { Get-Content -LiteralPath $f.FullName -Raw -Encoding Unicode } else { Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 }
        if ($t -match [regex]::Escape($OldName)) { $leftover += $f.FullName.Replace($Stage, '').TrimStart('\') }
    } catch { }
}
if ($leftover.Count -gt 0) { WarnM ("  仍含旧名（多为例外/注释，请确认）：" + ($leftover -join ', ')) }

Set-Status 'OK'
Say ("迁移完成：目录 {0} 个 / JSON {1} 个 / REG {2} 个" -f $dirCount, $jsonCount, $regCount)
