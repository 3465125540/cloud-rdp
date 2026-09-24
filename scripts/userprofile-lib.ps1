<#
.SYNOPSIS
  确保 RDP 用户配置文件（C:\Users\<user> + NTUSER.DAT）在「用户登录之前」就存在。

.DESCRIPTION
  为什么必须有这个库 —— 这是「Edge 还原后缺少用户数据、所有网页账号数据丢失」的根因：

  整机还原是按作用域切分的：
    · 机器级（C:\scripts、C:\Users\Public\Desktop…）→ 开机时以 runneradmin 身份还原；
    · 用户级（C:\Users\<user>\... ，Edge User Data / 桌面 / 文档 / .workbuddy 全在这里）
      → **只有当该用户的配置文件已存在时**才可能还原。
  而 runner 进程是 runneradmin，RDP 用户 a 的 profile 在该用户首次登录前并不存在。
  所以 restore-snapshot.ps1 的 4d 段会先用备用凭据「预创建」profile。

  真机事故（run 35780696116，全轮 run 里 C:\Users\a 从未出现）：
    用户数据（Edge User Data / 桌面 / 文档 / WorkBuddy）**全程零还原**，
    日志里只有一句「用户配置文件未创建成功（将交给登录任务）」——
    因为登录任务同样依赖 profile，最终就是静默丢数据。

  根因就是这一行：
      Start-Process -FilePath cmd.exe -ArgumentList '/c exit' -Credential $cred
  PowerShell 的 Start-Process 在指定 -Credential 时**不会**顺手加载目标用户的配置文件：
  -LoadUserProfile 是一个**独立参数**，其默认值是 $false（官方文档原文：
  "The default value is FALSE"）。于是 .NET 走
  CreateProcessWithLogonW + LOGON_NETCREDENTIALS_ONLY —— 进程起来了、也不报错，
  但**目标用户的 profile 根本没被创建**，NTUSER.DAT 不存在
  → 4d 整段被跳过 → 用户数据丢失，且没有任何异常可查。

  修法：
    ① 显式加 -LoadUserProfile（.NET 会转成 LOGON_WITH_PROFILE，真正创建 profile），
       并**轮询等待** NTUSER.DAT 落盘（首次要复制 Default profile，可能要几秒到几十秒）；
    ② 万一二次登录服务（seclogon）不可用仍失败，退化为「手工登记 profile」：
       建目录 + 复制 C:\Users\Default\NTUSER.DAT + 写 ProfileList\<SID>。
       这一步很关键 —— 只建目录不登记，Windows 首次登录会另建
       C:\Users\<user>.<机器名>，还原的数据用户照样看不到。

  本库另提供 Invoke-AsRdpUser：以 RDP 用户身份（且加载其 profile）跑一条命令，
  用于需要「真实用户上下文」的探测（如 Edge DPAPI 解密能力探测）。

.NOTES
  函数前缀 UP / RdpUser，避免与 userhive-lib.ps1 的同名工具函数冲突。
  所有函数 fail-soft，永不抛异常；返回值为可序列化对象。
#>

# 该用户的 SID（S-1-5-21-...）；取不到返回 $null
function Get-UPUserSid {
    param([string]$RdpUser)
    if ([string]::IsNullOrWhiteSpace($RdpUser)) { return $null }
    try { return (Get-LocalUser -Name $RdpUser -ErrorAction Stop).SID.Value } catch { return $null }
}

function Write-UPMsg {
    param([string]$Message, [scriptblock]$Log)
    if ($null -ne $Log) { try { & $Log $Message; return } catch { } }
    Write-Host "[userprofile] $Message"
}

# 备用凭据（用户名 + 明文密码）→ PSCredential
function New-UPCredential {
    param([string]$RdpUser, [string]$Password)
    if ([string]::IsNullOrWhiteSpace($RdpUser) -or [string]::IsNullOrWhiteSpace($Password)) { return $null }
    try {
        $ss = New-Object System.Security.SecureString
        foreach ($ch in $Password.ToCharArray()) { [void]$ss.AppendChar($ch) }
        $ss.MakeReadOnly()
        return (New-Object System.Management.Automation.PSCredential($RdpUser, $ss))
    } catch { return $null }
}

# 手工登记 profile：建目录 + 复制 Default hive + 写 ProfileList\<SID>
# 返回 @{ ok; note }
function Register-UPProfileManually {
    param([string]$RdpUser, [scriptblock]$Log)

    $sid  = Get-UPUserSid -RdpUser $RdpUser
    if (-not $sid) { return @{ ok = $false; note = '取不到该用户的 SID，无法登记 profile' } }

    $home = Join-Path 'C:\Users' $RdpUser
    $dat  = Join-Path $home 'NTUSER.DAT'
    $note = ''
    try {
        New-Item -ItemType Directory -Force -Path $home | Out-Null

        # ① 复制 Default 模板 hive（Windows 首次登录本来也是这么做的）
        $defDir = 'C:\Users\Default'
        $defDat = Join-Path $defDir 'NTUSER.DAT'
        if (Test-Path -LiteralPath $defDat) {
            if (-not (Test-Path -LiteralPath $dat)) {
                Copy-Item -LiteralPath $defDat -Destination $dat -Force
                foreach ($ext in @('NTUSER.DAT.LOG1', 'NTUSER.DAT.LOG2')) {
                    $s = Join-Path $defDir $ext
                    if (Test-Path -LiteralPath $s) { Copy-Item -LiteralPath $s -Destination (Join-Path $home $ext) -Force -ErrorAction SilentlyContinue }
                }
                $note = '已复制 Default hive'
            }
        } else {
            $note = '未找到 Default\NTUSER.DAT（登录时由 Windows 自行生成 hive）'
        }

        # ② 登记 ProfileList：不做这一步，首次登录 Windows 会另建 <user>.<机器名>
        $key = "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
        & reg.exe add $key /v ProfileImagePath /t REG_EXPAND_SZ /d $home /f 2>&1 | Out-Null
        $e1 = $LASTEXITCODE
        & reg.exe add $key /v Flags /t REG_DWORD /d 0 /f 2>&1 | Out-Null
        & reg.exe add $key /v State /t REG_DWORD /d 0 /f 2>&1 | Out-Null
        if ($e1 -ne 0) { $note += '；ProfileList 写入失败（码 ' + $e1 + '）' }

        # ③ 属主 / ACL 交回该用户（否则用户登录后没有写权限）
        & icacls.exe $home /setowner "$RdpUser" /T /C /Q 2>&1 | Out-Null
        & icacls.exe $home /grant ("{0}:(OI)(CI)F" -f $RdpUser) /T /C /Q 2>&1 | Out-Null
    } catch {
        return @{ ok = $false; note = ('登记失败：' + $_.Exception.Message) }
    }
    $ok = (Test-Path -LiteralPath $home)
    return @{ ok = $ok; note = $note }
}

<#
.SYNOPSIS
  保证 C:\Users\<RdpUser>\NTUSER.DAT 存在（用户登录前预创建 profile）。
.OUTPUTS
  [pscustomobject]@{ ok; path; dat; sid; method; note }
    method = existing | logon-with-profile | manual-register | failed
#>
function Initialize-RdpUserProfile {
    param(
        [string]$RdpUser,
        [scriptblock]$Log,
        [int]$WaitSec = 40,
        [switch]$NoFallback
    )

    $r = [pscustomobject]@{
        ok = $false; path = $null; dat = $null; sid = $null; method = 'failed'; note = ''
    }
    if ([string]::IsNullOrWhiteSpace($RdpUser)) { $r.note = '未指定 RDP 用户'; return $r }

    $home = Join-Path 'C:\Users' $RdpUser
    $dat  = Join-Path $home 'NTUSER.DAT'
    $r.path = $home
    $r.dat  = $dat
    $r.sid  = Get-UPUserSid -RdpUser $RdpUser

    # 已经有就什么都不做（幂等）
    if (Test-Path -LiteralPath $dat) {
        $r.ok = $true; $r.method = 'existing'; $r.note = '用户配置文件已存在'
        return $r
    }

    # ---------- ① 首选：备用凭据登录 + -LoadUserProfile ----------
    # 关键：-LoadUserProfile 必须显式给。缺了它 = LOGON_NETCREDENTIALS_ONLY
    # → 进程起得来、不报错，但 profile 不会被创建（真机事故根因）。
    if ([string]::IsNullOrWhiteSpace($env:RDP_PASSWORD)) {
        Write-UPMsg '缺少 RDP_PASSWORD，无法用备用凭据预创建用户配置文件' -Log $Log
        $r.note = '缺少 RDP_PASSWORD'
    } else {
        $cred = New-UPCredential -RdpUser $RdpUser -Password $env:RDP_PASSWORD
        if (-not $cred) {
            $r.note = '构造备用凭据失败'
        } else {
            try {
                Write-UPMsg ('预创建用户配置文件：{0}（-LoadUserProfile）' -f $home) -Log $Log
                $p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c exit' -Credential $cred `
                        -LoadUserProfile -WindowStyle Hidden -PassThru -ErrorAction Stop
                if ($p) {
                    try { Wait-Process -Id $p.Id -Timeout 90 -ErrorAction Stop }
                    catch { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { } }
                }
            } catch {
                $r.note = ('备用凭据登录失败：' + $_.Exception.Message)
                Write-UPMsg ('备用凭据登录失败（将继续尝试兜底）：{0}' -f $_.Exception.Message) -Log $Log
            }
            # profile 首次创建要复制 Default 整棵目录，落盘有延迟 —— 轮询等
            for ($i = 0; $i -lt $WaitSec; $i++) {
                if (Test-Path -LiteralPath $dat) { break }
                Start-Sleep -Seconds 1
            }
            if (Test-Path -LiteralPath $dat) {
                $r.ok = $true; $r.method = 'logon-with-profile'
                $r.note = '已用 -LoadUserProfile 创建并登记'
                Write-UPMsg ('用户配置文件已创建并登记：{0}' -f $home) -Log $Log
                return $r
            }
            if ([string]::IsNullOrWhiteSpace($r.note)) { $r.note = ('等待 {0}s 后仍未出现 NTUSER.DAT' -f $WaitSec) }
        }
    }

    # ---------- ② 兜底：手工登记 ----------
    if ($NoFallback) { return $r }
    Write-UPMsg ('登录方式未生成 profile，退化为手工登记（{0}）' -f $r.note) -Log $Log
    $m = Register-UPProfileManually -RdpUser $RdpUser -Log $Log
    if ($m.ok) {
        $r.ok = $true; $r.method = 'manual-register'
        $r.note = ('已手工登记 profile（{0}）' -f $m.note)
        Write-UPMsg ('已手工登记 profile：{0}  {1}' -f $home, $m.note) -Log $Log
    } else {
        $r.note = ($r.note + '；兜底也失败：' + $m.note)
        Write-UPMsg ('profile 兜底失败：{0}' -f $m.note) -Log $Log
    }
    return $r
}

<#
.SYNOPSIS
  以 RDP 用户身份（加载其 profile）执行一条命令，并把 stdout 落到临时文件。
.DESCRIPTION
  用途：需要「真实用户上下文」的探测 —— 典型是 Edge 的 DPAPI 解密能力
  （CryptUnprotectData 的 CurrentUser 作用域取的是**当前进程所属用户**的密钥，
   以 runneradmin 跑必然失败，必须真正以用户 a 的身份跑）。

  为什么不用 -RedirectStandardOutput：Start-Process 的 -Credential 与重定向参数互斥，
  所以由子进程自己把结果写进 -OutFile。
.OUTPUTS
  [pscustomobject]@{ ran; exit; output; note }
#>
function Invoke-AsRdpUser {
    param(
        [string]$RdpUser,
        [string]$FilePath,
        [string[]]$Arguments,
        [scriptblock]$Log,
        [int]$TimeoutSec = 90,
        [string]$What = 'user-cmd'
    )

    $res = [pscustomobject]@{ ran = $false; exit = $null; output = ''; note = '' }
    if ([string]::IsNullOrWhiteSpace($env:RDP_PASSWORD)) { $res.note = '缺少 RDP_PASSWORD'; return $res }

    $cred = New-UPCredential -RdpUser $RdpUser -Password $env:RDP_PASSWORD
    if (-not $cred) { $res.note = '构造备用凭据失败'; return $res }

    $p = $null
    try {
        $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -Credential $cred `
                -LoadUserProfile -WindowStyle Hidden -PassThru -ErrorAction Stop
    } catch {
        $res.note = ('{0} 启动失败：{1}' -f $What, $_.Exception.Message)
        Write-UPMsg $res.note -Log $Log
        return $res
    }
    if (-not $p) { $res.note = ('{0} 未返回进程对象' -f $What); return $res }

    $res.ran = $true
    try { Wait-Process -Id $p.Id -Timeout $TimeoutSec -ErrorAction Stop }
    catch {
        try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
        $res.note = ('{0} 超过 {1}s 未结束，已放弃' -f $What, $TimeoutSec)
        Write-UPMsg $res.note -Log $Log
    }
    try { $res.exit = $p.ExitCode } catch { }
    return $res
}
