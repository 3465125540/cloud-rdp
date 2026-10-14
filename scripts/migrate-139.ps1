<#
.SYNOPSIS
  把 139 云盘上的老路径迁移到新路径（一次性、幂等、**只 copy 不 move**）。

.DESCRIPTION
  老: alist:/cloudrdp/CloudRDP    →  新: alist:/cloudrdp/AI文件库/CloudRDP
  老: alist:/cloudrdp/_snapshot   →  新: alist:/cloudrdp/AI文件库/_snapshot

  触发条件（满足任一）：
    · 环境变量 INPUT_MIGRATE_139 = 'true'（workflow_dispatch 的 migrate_139 输入）
    · 显式传 -Force

  幂等守卫：仅当「新路径为空 且 老路径非空」才执行，重复跑无副作用。
  安全：只 copy 不 move，老数据原样保留，可随时切回。

.NOTES
  本脚本永不返回非 0。
#>
[CmdletBinding()]
param(
    [string]$OldBase  = "alist:/cloudrdp",
    [string]$NewBase  = $(if ($env:CLOUDRDP_REMOTE_BASE) { $env:CLOUDRDP_REMOTE_BASE } else { "alist:/cloudrdp/AI文件库" }),
    [string]$RcloneExe = $(if ($env:CLOUDRDP_SYS_DIR) { Join-Path $env:CLOUDRDP_SYS_DIR "rclone\rclone.exe" } elseif (Test-Path 'D:\') { "D:\cloudrdp-sys\rclone\rclone.exe" } else { "C:\rclone\rclone.exe" }),
    [switch]$Force
)

$ErrorActionPreference = "Continue"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Say([string]$m)  { Write-Host "[migrate] $m" }
function Warn([string]$m) { Write-Warning "[migrate] $m" }

# 远端目录统计；不存在/不可读时 Ok=$false
function Get-RemoteStat {
    param([string]$Path)
    $json = (& $RcloneExe size $Path --json --timeout 0 --contimeout 0 2>$null | Out-String)
    if ($json -match '\{') {
        try {
            $o = ($json.Substring($json.IndexOf('{')) | ConvertFrom-Json)
            return @{ Ok = $true; Count = [int]$o.count; Bytes = [double]$o.bytes }
        } catch { }
    }
    return @{ Ok = $false; Count = 0; Bytes = 0 }
}

if (-not $Force -and $env:INPUT_MIGRATE_139 -ne 'true') {
    Say "未请求迁移（INPUT_MIGRATE_139 != true），跳过。要迁移请勾选 migrate_139，或本地加 -Force。"
    exit 0
}
if (-not (Test-Path -LiteralPath $RcloneExe)) { Warn "未找到 rclone，跳过迁移"; exit 0 }

# 预检目标根是否存在（不静默创建 AI文件库，避免建出影子目录）
$probe = & $RcloneExe lsf $NewBase --max-depth 1 --timeout 0 --contimeout 0 2>&1
if ($LASTEXITCODE -ne 0) {
    Warn "目标根 $NewBase 不存在或不可访问 —— 请先在 139 云盘建好「AI文件库」文件夹，再重跑。"
    exit 0
}

Say "老根 = $OldBase"
Say "新根 = $NewBase"

foreach ($name in @("CloudRDP", "_snapshot")) {
    $old = "$OldBase/$name"
    $new = "$NewBase/$name"

    $so = Get-RemoteStat -Path $old
    if (-not $so.Ok)     { Say "$name : 老路径不存在或不可读（$old），跳过"; continue }
    if ($so.Count -eq 0) { Say "$name : 老路径为空，无需迁移"; continue }

    $sn = Get-RemoteStat -Path $new
    if ($sn.Ok -and $sn.Count -gt 0) {
        Say ("{0} : 新路径已有 {1} 个文件，跳过（幂等）" -f $name, $sn.Count)
        continue
    }

    Say ("{0} : 迁移 {1}  ->  {2}   （{3} 个文件 / {4:N2} MB）" -f $name, $old, $new, $so.Count, ($so.Bytes / 1MB))
    & $RcloneExe copy $old $new `
        --transfers 4 --checkers 8 `
        --timeout 0 --contimeout 0 `
        --retries 3 --low-level-retries 5 `
        --stats-one-line -v

    if ($LASTEXITCODE -eq 0) {
        Say "$name : 迁移完成（老数据仍保留在 $old，确认无误后可自行删除）"
    } else {
        Warn "$name : 迁移失败（rclone 码 $LASTEXITCODE）"
    }
}

Say "迁移流程结束"
exit 0
