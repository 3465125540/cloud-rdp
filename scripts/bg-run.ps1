<#
.SYNOPSIS
  通用「后台任务」助手：把任意长脚本丢到后台跑，主流程不阻塞；另一步再等它。

.DESCRIPTION
  为什么需要：第 1 步（开机瘦身）与第 7 步（从 139 拉数据）互不依赖，串行跑纯属浪费。
  本脚本让它们**并行**：
    · -Mode Start  在第 1 / 第 7 步调用：用 Start-Process 拉起自己（-Mode Run）后**立刻返回**；
    · -Mode Run    后台进程：跑目标脚本，输出落日志、退出码落状态文件，最后写 done 标记；
    · -Mode Wait   在第 7b 步调用：等 done 标记（带心跳），把后台脚本写进
                   <SysDir>\_state\bg-<name>-ghenv.txt 的环境变量**回填**到本步的 GITHUB_ENV。

  ⚠️ 为什么环境变量要绕这一圈：GitHub Actions 只在**每个 step 结束时**读一次 $env:GITHUB_ENV。
     后台进程写它没用（那时 step 早已结束、runner 不会再读）。所以 -Mode Run 先把
     $env:GITHUB_ENV 指到一个临时文件，目标脚本的 Set-GhEnv 就写进那个文件；
     -Mode Wait 再把文件内容回填到**当步**的 GITHUB_ENV —— 这样第 2 步（基线）与
     第 13 步（ENV READY）照旧能读到 SLIM_* / RESTORE_*。

  ⚠️ 进程树：GitHub 在 step **超时/被杀**时会杀掉该 step 的整棵进程树（见 0f 步复盘），
     所以调用方必须是「启动后立刻正常返回」的短 step；正常结束的 step 不会波及子进程
     （与 reinstall-apps.ps1 -Background / finalize-background.ps1 -Background 同一套用法）。

  产物（都在 <SysDir>\_state\）：
    bg-<name>.log          目标脚本的完整输出
    bg-<name>-ghenv.txt    目标脚本透出的 GITHUB_ENV 行（等回填用）
    bg-<name>-status.json  { name, exitCode, startedUtc, doneUtc }
    bg-<name>-done.flag    完成标记（存在即代表跑完，无论成败）
    bg-<name>.pid          后台进程 PID（Wait 用它判断「进程没了但没写标记」）

.NOTES
  本脚本永不返回非 0 —— 后台任务失败不该让 job 标红（真相看 status.json / log）。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('Start','Run','Wait')][string]$Mode,
    [Parameter(Mandatory=$true)][string]$Name,
    [string]$Target = "",          # 目标脚本（相对路径按 scripts\ 解析）
    [string]$TargetArgs = "",      # 追加参数（原样拼在 -File <target> 之后）
    [int]$TimeoutSec  = 3600,      # Wait 的最长等待
    [int]$HeartbeatSec = 60        # Wait 的心跳间隔（往 job 日志打一行，证明没死）
)
$ErrorActionPreference = 'Continue'

$SysDir   = if ($env:CLOUDRDP_SYS_DIR) { $env:CLOUDRDP_SYS_DIR } elseif (Test-Path 'D:\') { 'D:\cloudrdp-sys' } else { 'C:\cloudrdp-sys' }
$StateDir = Join-Path $SysDir '_state'
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

$LogFile    = Join-Path $StateDir ("bg-{0}.log"           -f $Name)
$GhEnvFile  = Join-Path $StateDir ("bg-{0}-ghenv.txt"     -f $Name)
$StatusFile = Join-Path $StateDir ("bg-{0}-status.json"   -f $Name)
$DoneFlag   = Join-Path $StateDir ("bg-{0}-done.flag"     -f $Name)
$PidFile    = Join-Path $StateDir ("bg-{0}.pid"           -f $Name)

function Say([string]$m) { Write-Host ("[bg:{0}] {1}" -f $Name, $m) }

function Resolve-Target([string]$t) {
    if ([string]::IsNullOrWhiteSpace($t)) { return "" }
    if ([System.IO.Path]::IsPathRooted($t)) { return $t }
    return (Join-Path $PSScriptRoot $t)
}

$pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
if (-not $pwsh) { $pwsh = (Get-Command powershell.exe -ErrorAction Stop).Source }

switch ($Mode) {

    'Start' {
        $tgt = Resolve-Target $Target
        if (-not (Test-Path -LiteralPath $tgt)) { Say "目标脚本不存在：$tgt（跳过后台启动）"; exit 0 }
        Remove-Item -LiteralPath $DoneFlag, $StatusFile, $PidFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $LogFile, $GhEnvFile -Force -ErrorAction SilentlyContinue

        $argStr = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode Run -Name "{1}" -Target "{2}"' -f $PSCommandPath, $Name, $tgt
        if (-not [string]::IsNullOrWhiteSpace($TargetArgs)) { $argStr += ' ' + $TargetArgs }

        $p = Start-Process -FilePath $pwsh -ArgumentList $argStr -WindowStyle Hidden -PassThru
        ("{0}" -f $p.Id) | Out-File -LiteralPath $PidFile -Encoding ascii
        Say ("已在后台启动 {0}（pid={1}，log: {2}）" -f (Split-Path $tgt -Leaf), $p.Id, $LogFile)
        exit 0
    }

    'Run' {
        $tgt     = Resolve-Target $Target
        $started = (Get-Date).ToUniversalTime().ToString('o')
        Remove-Item -LiteralPath $GhEnvFile -Force -ErrorAction SilentlyContinue
        # 把 GITHUB_ENV 指到临时文件：目标脚本的 Set-GhEnv 会写这里，而不是真正（已失效）的 step env
        $env:GITHUB_ENV = $GhEnvFile

        $code = 0
        try {
            $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tgt)
            if (-not [string]::IsNullOrWhiteSpace($TargetArgs)) {
                $argList += @($TargetArgs -split '\s+' | Where-Object { $_ })
            }
            & $pwsh @argList *>&1 | Out-File -LiteralPath $LogFile -Encoding utf8
            $code = $LASTEXITCODE
            if ($null -eq $code) { $code = 0 }
        } catch {
            $code = 1
            ("[bg:{0}] 异常：{1}" -f $Name, $_) | Out-File -LiteralPath $LogFile -Append -Encoding utf8
        }

        ([ordered]@{
            name       = $Name
            exitCode   = $code
            startedUtc = $started
            doneUtc    = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json) | Out-File -LiteralPath $StatusFile -Encoding UTF8
        New-Item -ItemType File -Force -Path $DoneFlag | Out-Null
        exit 0
    }

    'Wait' {
        $deadline = (Get-Date).ToUniversalTime().AddSeconds($TimeoutSec)
        $lastBeat = Get-Date
        $t0       = Get-Date
        $died     = $false

        while (-not (Test-Path -LiteralPath $DoneFlag)) {
            if ((Get-Date).ToUniversalTime() -ge $deadline) { break }
            Start-Sleep -Seconds 5

            # 进程没了但没写标记 → 判定被杀，别干等满超时
            if (Test-Path -LiteralPath $PidFile) {
                $pidTxt = (Get-Content -LiteralPath $PidFile -Raw -ErrorAction SilentlyContinue)
                $bgPid = 0
                if ([int]::TryParse(("$pidTxt").Trim(), [ref]$bgPid) -and $bgPid -gt 0) {
                    if (-not (Get-Process -Id $bgPid -ErrorAction SilentlyContinue)) { $died = $true; break }
                }
            }

            if (((Get-Date) - $lastBeat).TotalSeconds -ge $HeartbeatSec) {
                $lastBeat = Get-Date
                $elapsed  = [int]((Get-Date) - $t0).TotalMinutes
                $leftMin  = [int][math]::Max(0, ($deadline - (Get-Date).ToUniversalTime()).TotalMinutes)
                Say ("等待中…（已等 {0} 分钟，上限还剩 {1} 分钟）" -f $elapsed, $leftMin)
            }
        }

        $done = Test-Path -LiteralPath $DoneFlag
        if ($done) {
            $st = 'unknown'
            if (Test-Path -LiteralPath $StatusFile) {
                try { $st = ((Get-Content -LiteralPath $StatusFile -Raw) | ConvertFrom-Json).exitCode } catch { }
            }
            Say ("后台任务已完成（exitCode=$st）")
        } elseif ($died) {
            Say "⚠️ 后台进程已消失但未写完成标记（可能被系统/超时杀掉）"
        } else {
            Say ("⚠️ 等待超时（{0} 秒）仍未完成 —— 不阻断，后续步骤按现有状态继续" -f $TimeoutSec)
        }

        # 回填环境变量（第 2 步的 SLIM_*、第 13 步的 RESTORE_* 都靠它）
        if (Test-Path -LiteralPath $GhEnvFile) {
            $n = 0
            Get-Content -LiteralPath $GhEnvFile -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_ -and $env:GITHUB_ENV) { $_ | Out-File $env:GITHUB_ENV -Append -Encoding ascii; $n++ }
            }
            Say ("已回填 {0} 条环境变量" -f $n)
        }

        # 日志尾巴，方便直接在 job 日志里看到结果
        if (Test-Path -LiteralPath $LogFile) {
            Say "----- 日志末尾 -----"
            Get-Content -LiteralPath $LogFile -Tail 12 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ("    | " + $_) }
        }
        exit 0
    }
}
