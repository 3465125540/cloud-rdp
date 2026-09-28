<#
  session-lib.ps1 —— 会话归属诊断 + 桌面「切到 UU远程」快捷方式安装。

  ── 背景（真机事实，与 README §15 对应）────────────────────────────────────
  * UU远程（网易 GameViewer）是屏幕镜像型工具，连的是机器的**控制台会话**。
  * GitHub-hosted Windows 镜像把 runneradmin 放在控制台
    → UU远程 默认看到的是 runneradmin 的桌面，不是 a（这就是「账户不一致」）。
  * 仓库里没有任何自动登录 / 会话脚本；把控制台交给 a 的唯一安全手段是
    Windows 自带的 tscon（见 scripts/session-handover.ps1）。
  * 本库只做「诊断 + 装快捷方式」，**不自动切换** —— 切换会让那次 RDP 断开，
    交给用户按需触发（桌面快捷方式），这是 瑀子 2026-09-28 选定的方式。

  ── 导出 ──────────────────────────────────────────────────────────────────
    Get-RdpSessionReport                 [-RdpUser a]        会话布局报告（对象）
    Format-RdpSessionReport              [-RdpUser a]        一行文字
    Install-RdpSessionHandoverShortcut   [-RdpUser a]        公共桌面放「切到 UU远程」
#>

function Get-RdpSessionReport {
    [CmdletBinding()]
    param([string]$RdpUser = 'a')

    $qw = Join-Path $env:SystemRoot 'System32\qwinsta.exe'
    $sessions = @()
    if (Test-Path -LiteralPath $qw) {
        try {
            foreach ($ln in (& $qw 2>$null)) {
                $raw = [string]$ln
                if ([string]::IsNullOrWhiteSpace($raw)) { continue }
                $isCur = $raw.TrimStart().StartsWith('>')
                $t = ($raw -replace '^[> ]+', '').Trim() -split '\s+'
                if ($t.Count -lt 2) { continue }
                $name = $t[0]
                if ($name.ToLower() -in @('sessionname', '会话名')) { continue }   # 表头
                # 用户名列：第 2 个 token 不像「纯数字 / 状态词」时才是用户名（列缺失时为空）
                $user = ''
                if ($t[1] -notmatch '^\d+$' -and
                    $t[1] -notin @('Conn', 'Disc', 'Listen', 'Active', 'Idle', '已断开', '活动', '侦听')) {
                    $user = $t[1]
                }
                $id = ($t | Select-Object -Skip 1 | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1)
                $sessions += [pscustomobject]@{ name = $name; user = $user; id = $id; current = $isCur }
            }
        } catch { }
    }

    $console = $sessions | Where-Object { $_.name.ToLower() -eq 'console' } | Select-Object -First 1
    $a = $sessions | Where-Object { $_.user -eq $RdpUser } | Select-Object -First 1

    $consoleOwner = '?'
    if ($console) { $consoleOwner = if ($console.user) { $console.user } else { '(登录界面)' } }

    [pscustomobject]@{
        ok           = ($consoleOwner -eq $RdpUser)
        rdpUser      = $RdpUser
        consoleOwner = $consoleOwner
        consoleId    = if ($console) { $console.id } else { $null }
        aSessionId   = if ($a) { $a.id } else { $null }
        aState       = if ($a) { $a.name } else { '(无会话)' }
        sessions     = $sessions
    }
}

function Format-RdpSessionReport {
    [CmdletBinding()]
    param([string]$RdpUser = 'a')
    $r = Get-RdpSessionReport -RdpUser $RdpUser
    if ($r.ok) {
        return "控制台会话 = $RdpUser（UU远程 看到的就是 $RdpUser）"
    }
    $aPart = if ($r.aSessionId) { "$RdpUser 在会话 $($r.aSessionId)（$($r.aState)）" } else { "$RdpUser 还没登录（无会话）" }
    "控制台会话 = $($r.consoleOwner)（不是 $RdpUser）；$aPart —— 要让 UU远程 看到 $RdpUser，请在 $RdpUser 桌面双击「切到 UU远程」"
}

function Install-RdpSessionHandoverShortcut {
    [CmdletBinding()]
    param([string]$RdpUser = 'a', [string]$ScriptPath)

    $res = @{ ok = $false; path = ''; note = '' }
    try {
        if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
            $base = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { (Get-Location).Path }
            $ScriptPath = Join-Path $base 'scripts\session-handover.ps1'
        }
        if (-not (Test-Path -LiteralPath $ScriptPath)) { $res.note = "找不到 $ScriptPath"; return $res }

        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $desktop = Join-Path $env:PUBLIC 'Desktop'
        if (-not (Test-Path -LiteralPath $desktop)) { $desktop = [Environment]::GetFolderPath('CommonDesktopDirectory') }
        New-Item -ItemType Directory -Force -Path $desktop | Out-Null

        $lnkPath = Join-Path $desktop '切到 UU远程.lnk'
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut($lnkPath)
        $lnk.TargetPath       = $ps
        $lnk.Arguments        = '-NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
        $lnk.WorkingDirectory = Split-Path -Parent $ScriptPath
        $lnk.Description      = "把 $RdpUser 的会话交给控制台，让 UU远程 落到 $RdpUser（RDP 会断开，程序保留）"
        $lnk.IconLocation     = "$env:SystemRoot\System32\shell32.dll,137"
        $lnk.Save()

        $res.ok = $true
        $res.path = $lnkPath
    } catch { $res.note = $_.Exception.Message }
    return $res
}
