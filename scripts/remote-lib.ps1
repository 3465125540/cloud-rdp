<#
.SYNOPSIS
  139 云盘（AList/WebDAV）远端可达性判定 + rclone 退出码分类的共享库。

.DESCRIPTION
  ── 为什么需要它（一次真实事故）──
  139 的 DNS 抖动了几秒（`lookup personal-kd-njs.yun.139.com: no such host`），
  AList 于是对 WebDAV 的 PROPFIND 回 404，rclone 把 404 归类成「目录不存在」→ 退出码 3。
  旧脚本一见 3/4 就写 RESTORE_STATUS=EMPTY，等于把「网络抖了一下」记成「远端本来就是空的」：
  开机日志照样报成功，实际一个文件都没拉回来；紧接着 sync-up 又把空目录推回 139，假状态被坐实。

  ── 本库的做法 ──
  把判定从「rclone 退出码」升级成「先探根、再逐级探」：
    1. 先列 AList 挂载根（默认 alist:，即 139 云盘根）—— 能列出来 = 网络 + 鉴权都正常；
    2. 再逐级往下列，缺哪一级就报哪一级；
    3. 只有「根可列 + 父级可列 + 子级确实不在」时才敢判 EMPTY；根都列不出来 → TRANSIENT。
  换句话说：**绝不把「探不动」当成「不存在」**。

  ── 为什么还需要它（第二次真实事故，比上面那次更隐蔽）──
  上面那套「先探后拉」上线后，机器依旧报 EMPTY，日志却自相矛盾：
      [remote] 诊断：alist: 实际列出 62 项 → 10浜胯韩浠借瘉.txt, AI鏂囦欢搴?, ...
      [sync-down] 探测结果: EMPTY —— 远端确实不存在：alist:/AI文件库（里面没有「AI文件库」）
  62 项里那串 `AI鏂囦欢搴?` **就是**「AI文件库」—— 数据一直在，只是名字被解坏了。
  根因：rclone 恒以 UTF-8 输出文件名，而 Windows PowerShell 5.1 / pwsh 在中文系统上
  默认按 ACP=936(GBK) 解码子进程 stdout（实测 pwsh 7.6.6 的 [Console]::OutputEncoding
  默认值就是 DBCSCodePageEncoding）。于是 Get-RemoteProbe 拿「AI文件库」去 -contains
  比一份乱码列表，永远匹配不上 → 判 EMPTY。后果与 acc-1 同源：机器空着手开机，
  接着 sync-up / backup-snapshot -Push 又把空壳推回 139 覆盖好数据。

  ⚠️ 为什么「事后修乱码」当不了主防线：奇数长度的 UTF-8 名（AI文件库 = 11 字节）被 GBK
  两两分组后，落单的最后 1 字节会被替换成 '?'，**信息永久丢失**。实测把 '?' 去掉再用
  0x80..0xBF 逐个补回，有 64 种都能通过严格 UTF-8 解码（AI文件庀 / AI文件庁 / … /
  AI文件库 / …），只有已知目标名才反查得回来。所以主防线是「从源头按 UTF-8 解码」
  （Set-RcloneOutputEncoding + Invoke-RcloneList 的 .NET Process 路径），
  修乱码只作兜底，且判不出来时宁可报 ENCODING 也绝不报 EMPTY。

  两条必须靠字段/规则兜住的细节（都是实测踩出来的）：
    · 兜底修复会把乱码「洗干净」，洗完后 Test-ListingLooksMojibake 就看不到证据了 ——
      故 Invoke-RcloneList 额外返回 MojibakeFixed（本次修回几个名字），哨兵与「仍有乱码」取或。
    · 「编码坏过」不等于「一律 ENCODING」：ASCII 字节在 UTF-8/GBK 下完全一致，纯 ASCII 目标
      （_snapshot 等）的缺失依旧可信 → 判 EMPTY；只有非 ASCII 目标（AI文件库）才可能藏进乱码里
      → 判 ENCODING。反过来，若 Get-MojibakeVariants 能由目标名正向反查命中乱码项，
      则直接判 OK（比 ENCODING 更好：数据能正常拉取，无需人工介入）。

  判定结果（五态）：
    OK        远端可列，目标子目录存在（含「变体反查命中乱码项」这一路）
    EMPTY     远端可列，目标子目录确实不存在（首次运行正常）
    TRANSIENT 网络/后端瞬时故障（DNS、超时、5xx、连接重置）—— 应重试，**绝不写远端**
    AUTH      鉴权失败（401/403/Authorization 过期）—— 需要换 token
    ENCODING  远端可列、目标名含非 ASCII，但目录名疑似被误解码（GBK/UTF-8 混淆）→
              **无法证明目标不存在**，绝不判 EMPTY、绝不写远端；修编码后重试即可，属可恢复故障

.NOTES
  纯函数库：不 exit、不抛致命错，可被任意脚本 `. .\scripts\remote-lib.ps1` 引入。
  导出函数：
    Get-RcloneErrorKind        rclone 退出码 → OK/EMPTY/TRANSIENT（纯映射，仅作粗判）
    Get-RemoteRoot             求 139 侧「根」路径（AList 挂载点）
    Get-RemoteLevels           求目标相对根的层级
    Set-RcloneOutputEncoding   把 rclone 输出解码钉成 UTF-8（进程级幂等）
    Repair-MojibakeName        「UTF-8 被 GBK 误解码」的事后修复（兜底，可能返回 $null）
    Get-MojibakeVariants       由目标名正向生成它被误解码后的形态（用于前缀反查）
    Test-NameInList            目标名是否在列表里（含 mojibake 容错比较）
    Test-ListingLooksMojibake  一份目录列表是否「看起来是乱码」→ ENCODING 哨兵
    Invoke-RcloneList          单次 lsf（带超时 + 强制 UTF-8 解码，返回结构化结果）
    Get-RemoteProbe            逐级探测 → 五态判定对象
    Resolve-RemoteVerdict      带重试的探测（TRANSIENT 才重试）
    Test-AlistRemoteReachable  带重试的「根是否可列」布尔判定
    Set-RestoreStatus          统一写状态：GITHUB_ENV + _state/restore-status.json + 标记文件
#>

# ------------------------------------------------------------------ 退出码粗判
function Get-RcloneErrorKind {
    <#
      rclone 退出码 → 粗分类。**仅供日志参考，不要拿它判 EMPTY**：
      139 的 DNS 故障会经 AList 404 变成 rclone 码 3，与「真的没有」完全同码。
      要下结论请用 Get-RemoteProbe / Resolve-RemoteVerdict。
    #>
    param([int]$Code)
    if ($Code -eq 0) { return 'OK' }
    if ($Code -eq 3 -or $Code -eq 4) { return 'EMPTY' }
    return 'TRANSIENT'
}

# ------------------------------------------------------------------ 路径推导
function Get-RemoteRoot {
    <#
      139 侧的「根」= AList 存储挂载点（健康时必定可列）。
      优先级：显式 -Root > 环境变量 CLOUDRDP_REMOTE_ROOT > 由 CLOUDRDP_REMOTE_BASE 取前缀 > alist:
      挂载点已改为 /（整盘根），所以 root = alist:；层级 alist:/AI文件库/CloudRDP -> @('AI文件库','CloudRDP')
    #>
    param([string]$Remote = "", [string]$Root = "")
    if (-not [string]::IsNullOrWhiteSpace($Root)) { return $Root.TrimEnd('/') }
    if (-not [string]::IsNullOrWhiteSpace($env:CLOUDRDP_REMOTE_ROOT)) {
        return $env:CLOUDRDP_REMOTE_ROOT.TrimEnd('/')
    }
    $base = [string]$env:CLOUDRDP_REMOTE_BASE
    if (-not [string]::IsNullOrWhiteSpace($base)) {
        $parts = @($base.TrimEnd('/').Split('/') | Where-Object { $_ -ne '' })
        if ($parts.Count -ge 1) { return $parts[0] }
    }
    if (-not [string]::IsNullOrWhiteSpace($Remote)) {
        $parts = @($Remote.TrimEnd('/').Split('/') | Where-Object { $_ -ne '' })
        if ($parts.Count -ge 1) { return $parts[0] }
    }
    return 'alist:'
}

function Get-RemoteLevels {
    <#
      Remote 相对 Root 的层级。
      alist:/AI文件库/CloudRDP + root=alist: -> @('AI文件库','CloudRDP')
    #>
    param([string]$Remote, [string]$Root)
    $r = ([string]$Remote).TrimEnd('/')
    $b = ([string]$Root).TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($r) -or [string]::IsNullOrWhiteSpace($b)) { return @() }
    if (-not $r.ToLowerInvariant().StartsWith($b.ToLowerInvariant())) { return @() }
    $tail = $r.Substring($b.Length).Trim('/')
    if ([string]::IsNullOrWhiteSpace($tail)) { return @() }
    return @($tail.Split('/') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

# ------------------------------------------------------------------ 编码防线
function Set-RcloneOutputEncoding {
    <#
      把 rclone 输出的解码方式钉成 UTF-8（进程级幂等，可反复调用）。

      这是「AI文件库 被误判 EMPTY」事故的**主防线**：rclone 恒以 UTF-8 输出，
      而中文 Windows 上 PowerShell 默认按 ACP=936(GBK) 解码子进程 stdout。
      实测（pwsh 7.6.6 / 中文 Windows）：[Console]::OutputEncoding 默认值 =
      DBCSCodePageEncoding，`& rclone lsf alist:` 拿到的目录名全是乱码。

      两件事都要做：
        ① RegisterProvider —— .NET Core(pwsh) 默认不含 CP936，mojibake 兜底路径要用它；
        ② [Console]::OutputEncoding = UTF8 —— 让退化的 `& exe` 路径也按 UTF-8 解码。
    #>
    try {
        $null = [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance)
    } catch { }
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
}

function Repair-MojibakeName {
    <#
      「UTF-8 字节被 GBK 误解码」的事后修复 —— **仅兜底，不是主防线**。
      算法：把串按 CP936 编码回字节，再用「严格 UTF-8」（遇非法序列即抛错）解码。
        解得出 = 它原本就是合法 UTF-8 → 确实被误解码过，返回修复值；
        抛错   = 返回 $null。两种情况都会抛错，调用方**无法区分**：
                 a) 本来就是正常中文名（如 'AI文件库'，其 GBK 字节不是合法 UTF-8）；
                 b) 奇数长度名的末字节被 '?' 吞掉，已不可逆。
      所以本函数只能用来「识别出列表里有乱码」（配合 Test-ListingLooksMojibake），
      不能用来「把乱码还原成目标名」—— 还原请走 Get-MojibakeVariants 正向反查。
      注：纯 ASCII 名（'CloudRDP'）会解出与原串相同的结果，属无害恒等变换。
    #>
    param([AllowEmptyString()][AllowNull()][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    try {
        $null = [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance)
        $gbk    = [System.Text.Encoding]::GetEncoding(936)
        $strict = New-Object System.Text.UTF8Encoding($false, $true)
        return $strict.GetString($gbk.GetBytes($Name))
    } catch {
        return $null
    }
}

function Get-MojibakeVariants {
    <#
      由**已知目标名**正向生成「它被 UTF-8→GBK 误解码后会变成什么样」。
      这是奇数长度名（末字节被 '?' 吞掉、不可逆）唯一可行的救法：
      不猜乱码是什么，而是算出目标名的乱码形态，再去列表里（前缀）匹配。
      例：'AI文件库'（UTF-8 11 字节）→ @('AI鏂囦欢搴?', 'AI鏂囦欢搴')
    #>
    param([AllowEmptyString()][AllowNull()][string]$Name)
    $v = @()
    if ([string]::IsNullOrWhiteSpace($Name)) { return $v }
    try {
        $null = [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance)
        $gbk  = [System.Text.Encoding]::GetEncoding(936)
        $u8   = [System.Text.Encoding]::UTF8.GetBytes($Name)
        $m    = $gbk.GetString($u8)
        if (-not [string]::IsNullOrWhiteSpace($m)) { $v += $m }
        # 去掉替换符（不同运行时可能是 '?' 或 U+FFFD）后的前缀形态
        foreach ($q in @('?', [string][char]0xFFFD)) {
            $t = $m.TrimEnd($q.ToCharArray())
            if (-not [string]::IsNullOrWhiteSpace($t) -and $v -notcontains $t) { $v += $t }
        }
    } catch { }
    return $v
}

function Test-NameInList {
    <#
      目标名是否出现在一份 rclone 列表里 —— 带 mojibake 容错的 `-contains`。
      三级比较：① 直接相等；② 列表项修复后相等（救偶数长度名）；
                ③ 目标名的 mojibake 变体相等 / 前缀命中（救末字节被吞的奇数长度名）。
      ③ 的前缀至少 4 字符才比，避免 '同步'→'鍚屾' 这类短名误命中无关项。
    #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Name,
        [AllowNull()][string[]]$Names
    )
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $list = @($Names | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($list.Count -eq 0) { return $false }
    if ($list -contains $Name) { return $true }

    # ② 列表项可能是 mojibake → 修复后再比
    foreach ($n in $list) {
        $r = Repair-MojibakeName -Name $n
        if ($r -and $r -eq $Name) { return $true }
    }
    # ③ 由目标名正向算出 mojibake 形态再比（含前缀，救不可逆的末字节）
    foreach ($v in @(Get-MojibakeVariants -Name $Name)) {
        if ($list -contains $v) { return $true }
        $head = $v.TrimEnd('?', [char]0xFFFD)
        if ($head.Length -ge 4) {
            foreach ($n in $list) { if ($n.StartsWith($head)) { return $true } }
        }
    }
    return $false
}

function Test-ListingLooksMojibake {
    <#
      一份目录列表是否「看起来是被 GBK 误解码过的」→ ENCODING 哨兵。
      判据：列表里**任一项**满足「修复成功 + 修复后 != 原串 + 修复后含汉字」，即认定为乱码列表。
        '10浜胯韩浠借瘉.txt' → 修复成 '10亿身份证.txt'（含汉字、不等于原串）→ 命中
        'AI文件库'（正常名） → 修复抛错返回 $null → 不命中
        'CloudRDP'（纯 ASCII）→ 修复后 == 原串 → 不命中
      意义：奇数长度名（如 AI文件库）自己修不回来，但同一份列表里的偶数长度名能修回来，
      足以证明「这份列表的编码坏了」，从而拦住 EMPTY 误判。
    #>
    param([AllowNull()][string[]]$Names)
    foreach ($n in @($Names)) {
        if ([string]::IsNullOrWhiteSpace($n)) { continue }
        $r = Repair-MojibakeName -Name $n
        if ($r -and $r -ne $n -and $r -match '[\u4e00-\u9fff]') { return $true }
    }
    return $false
}

# ------------------------------------------------------------------ 单次列举
function Invoke-RcloneList {
    <#
      单次 `rclone lsf <Path> --max-depth 1`。返回对象：
        Path / Code / Ok / Names / Text / UsedProcessApi / MojibakeFixed
      永不抛致命错（rclone 不存在 → Code=-1、Ok=$false）。
      注意用短超时（默认 25s）：探测必须能失败，不能把开机流程挂死。

      解码走三层（顺序即优先级）：
        ① .NET Process + StandardOutputEncoding=UTF8 —— **绕过 PowerShell 的 console
           解码路径**，与 console 代码页彻底解耦。实测把 console 编码故意设回 GBK(936)
           后，本路径依然正确拿到「AI文件库」，是唯一可证明可靠的方案。
        ② Process 路径异常时退回 `& exe`；此前 Set-RcloneOutputEncoding 已把
           console 编码设为 UTF-8，所以退化路径也是对的。
        ③ 每个名字再过 Repair-MojibakeName 兜底（正常名恒等，不受影响）。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$RcloneExe,
        [Parameter(Mandatory=$true)][string]$Path,
        [int]$TimeoutSec = 25
    )
    Set-RcloneOutputEncoding

    if ([string]::IsNullOrWhiteSpace($RcloneExe) -or -not (Test-Path -LiteralPath $RcloneExe)) {
        return [pscustomobject]@{
            Path = $Path; Code = -1; Ok = $false; Names = @()
            Text = "未找到 rclone：$RcloneExe"; UsedProcessApi = $false
            MojibakeFixed = 0
        }
    }

    $out     = @()
    $code    = -1
    $usedApi = $false

    # ---- ① 首选：.NET Process 直读 stdout/stderr，强制 UTF-8 ----
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $RcloneExe
        # 用 Arguments 字符串而非 ArgumentList：后者在 PowerShell 5.1(.NET Framework) 上不存在
        $psi.Arguments = ('lsf "{0}" --max-depth 1 --timeout {1}s --contimeout {1}s --retries 1 --low-level-retries 1' -f $Path, [int]$TimeoutSec)
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

        $p  = [System.Diagnostics.Process]::Start($psi)
        # 必须异步读双流：只读 stdout 时，stderr 缓冲写满会让子进程阻塞 → 双向死锁
        $so = $p.StandardOutput.ReadToEndAsync()
        $se = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit([int]($TimeoutSec * 1000 + 15000))) {
            try { $p.Kill() } catch { }
            $code = -2
            $out  = @("rclone 超时（${TimeoutSec}s）未返回，已强杀")
        } else {
            $code = $p.ExitCode
            $out  = @(($so.Result -split "`r?`n")) + @(($se.Result -split "`r?`n"))
        }
        $p.Dispose()
        $usedApi = $true
    } catch {
        # ---- ② 退回 PowerShell 调用（console 编码已在上面设成 UTF-8）----
        try {
            $out = @(& $RcloneExe lsf $Path --max-depth 1 `
                     --timeout "${TimeoutSec}s" --contimeout "${TimeoutSec}s" `
                     --retries 1 --low-level-retries 1 2>&1)
            $code = $LASTEXITCODE
        } catch {
            $code = -1
            $out  = @("$($_.Exception.Message)")
        }
    }

    $names  = @()
    $lines  = @()
    $fixedN = 0
    foreach ($o in $out) {
        if ($o -is [System.Management.Automation.ErrorRecord]) {
            # rclone 的 stderr 被 2>&1 包成 ErrorRecord；直接 ToString() 会带上
            # 「所在位置 … + CategoryInfo …」的调用栈噪声，日志里没法看。只取第一行消息。
            $m = ''
            try { $m = [string]$o.Exception.Message } catch { $m = '' }
            if ([string]::IsNullOrWhiteSpace($m)) { $m = [string]$o }
            $lines += (($m -split "`r?`n")[0]).Trim()
            continue
        }
        $s = ([string]$o).Trim()
        $lines += $s
        $n = $s.TrimEnd('/')
        if (-not [string]::IsNullOrWhiteSpace($n)) {
            # ③ 兜底：万一上游仍按 GBK 解了（例如 rclone 被包了一层 cmd），这里再救一次
            $fixed = Repair-MojibakeName -Name $n
            if ($fixed -and $fixed -ne $n -and $fixed -match '[\u4e00-\u9fff]') {
                # 修回了一个被误解码的名字 → 记下证据。层2 会把 Names「洗干净」，
                # 洗完之后 Test-ListingLooksMojibake 就再也检测不到乱码了；
                # 下游 ENCODING 哨兵只能靠这个计数知道「编码坏过」。
                $fixedN++
                $names += $fixed
            } else { $names += $n }
        }
    }
    return [pscustomobject]@{
        Path           = $Path
        Code           = $code
        Ok             = ($code -eq 0)
        Names          = $names
        Text           = (($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' | ').Trim()
        UsedProcessApi = $usedApi
        MojibakeFixed  = $fixedN
    }
}

# ------------------------------------------------------------------ 逐级探测
function Get-RemoteProbe {
    <#
      逐级探测 Remote 是否存在，给出四态判定。返回对象：
        Remote / Root / Levels / RootOk / RootCode / RootNames
        LeafExists / MissingAt / Verdict / Message

      判定顺序（关键：先证明「能看见」，再说「看不见」）：
        ① 列 Root 失败 → 按 rclone 文本判 AUTH 或 TRANSIENT（**不判 EMPTY**）
        ② Root 可列但父级里没有目标子目录 → EMPTY（父目录看得见，里面确实没有）
        ③ 父级里有目标子目录、却列不出它 → AUTH / TRANSIENT
        ④ 全部可列 → OK
    #>
    param(
        [Parameter(Mandatory=$true)][string]$RcloneExe,
        [Parameter(Mandatory=$true)][string]$Remote,
        [string]$Root = "",
        [int]$TimeoutSec = 25
    )
    $root   = Get-RemoteRoot -Remote $Remote -Root $Root
    $levels = @(Get-RemoteLevels -Remote $Remote -Root $root)

    $res = [ordered]@{
        Remote     = $Remote
        Root       = $root
        Levels     = $levels
        RootOk     = $false
        RootCode   = -1
        RootNames  = @()
        LeafNames  = @()
        LeafExists = $false
        MissingAt  = ''
        Verdict    = 'TRANSIENT'
        Message    = ''
    }

    # ---- ① 探根：能列出来 = 网络 + 鉴权都正常 ----
    $probe = Invoke-RcloneList -RcloneExe $RcloneExe -Path $root -TimeoutSec $TimeoutSec
    $res.RootCode  = $probe.Code
    $res.RootNames = $probe.Names
    if (-not $probe.Ok) {
        $v = Get-RemoteTextVerdict $probe.Text
        if ($v) { $res.Verdict = $v } else { $res.Verdict = 'TRANSIENT' }
        $res.Message = "无法列出 139 根目录 $root（rclone 码 $($probe.Code)）：$($probe.Text)"
        return [pscustomobject]$res
    }
    $res.RootOk = $true

    # ---- ②③④ 逐级往下：缺哪级报哪级 ----
    $cur     = $root
    $curList = $probe
    for ($i = 0; $i -lt $levels.Count; $i++) {
        $leaf = $levels[$i]
        $cur  = $cur.TrimEnd('/') + '/' + $leaf

        # 用 Test-NameInList 而非 `-contains`：后者遇到「UTF-8 输出被按 GBK 解码」的乱码
        # 列表时永远匹配不上，会把**明明存在**的目录判成 EMPTY（真实事故：62 项里的
        # `AI鏂囦欢搴?` 就是「AI文件库」）。前者带 mojibake 容错比较。
        if (-not (Test-NameInList -Name $leaf -Names $curList.Names)) {
            $res.MissingAt = $cur
            $res.LeafNames = $curList.Names

            # 诊断：把父目录实际列到的内容打出来，一眼定位「根到底映射到了哪层 / 是否为空」
            $shown = if ($curList.Names -and $curList.Names.Count -gt 0) {
                ($curList.Names -join ', ')
            } else { '（空列表）' }
            Write-Host "[remote] 诊断：$($curList.Path) 实际列出 $($curList.Names.Count) 项 → $shown"

            # ---- 判 EMPTY 前的最后一道哨兵：这份列表可不可信？----
            # 两个证据源，任一命中即认为「本次列举的编码坏过」：
            #   a) Test-ListingLooksMojibake —— 列表里**仍有**能还原成汉字名的项；
            #   b) $curList.MojibakeFixed —— Invoke-RcloneList 层2 **已经修回过** N 个名字。
            # 为什么必须要 b：层2 修复会把乱码「洗干净」，洗完后 a 再也检测不到证据
            # （实测：10浜胯韩浠借瘉.txt → 10亿身份证.txt 后，a 恒为 false），哨兵形同虚设。
            # 修复动作本身就是「编码坏过」的铁证，必须由计数字段承接、不能让它悄悄消失。
            #
            # ⚠️ 但「编码坏过」≠「一定判 ENCODING」—— 还要看**目标名是不是 ASCII**：
            #   ASCII 字符在 UTF-8 与 GBK 里字节完全一致，绝不会被误解码影响，
            #   所以纯 ASCII 目标（如 _snapshot）的「不存在」即使列表有乱码也可信 → 判 EMPTY。
            #   只有**含非 ASCII 的目标**（如 AI文件库）才可能被乱码藏起来，此时拒绝判 EMPTY。
            # （误判 EMPTY 会让机器空着手开机，随后 sync-up / backup-snapshot -Push 把空壳
            #   推回 139 覆盖好数据，正是 acc-1 事故的翻版。）
            $stillMojibake = $false
            try { $stillMojibake = [bool](Test-ListingLooksMojibake -Names $curList.Names) } catch { }
            $fixedCount = 0
            try { $fixedCount = [int]($curList.MojibakeFixed) } catch { }
            $listUnreliable = ($stillMojibake -or $fixedCount -gt 0)
            $leafNonAscii   = ($leaf -match '[^\x00-\x7F]')
            if ($listUnreliable -and $leafNonAscii) {
                $res.Verdict = 'ENCODING'
                $res.Message = "父目录 $($curList.Path) 可列（$($curList.Names.Count) 项，" +
                               "兜底修复 $fixedCount 项、仍有乱码=$stillMojibake），" +
                               "目录名疑似被按 GBK 误解码（rclone 的 UTF-8 输出未被正确解码），" +
                               "无法证明非 ASCII 目标「$leaf」不存在 —— 拒绝判 EMPTY。" +
                               "处置：确认 PowerShell 以 UTF-8 解码子进程输出后重跑"
                Write-Warning "[remote] ENCODING：$($res.Message)"
                Write-Warning "[remote] ENCODING 样例：$shown"
                return [pscustomobject]$res
            }

            $res.Verdict = 'EMPTY'
            $res.Message = "远端确实不存在：$cur（父目录 $($curList.Path) 可列，里面没有「$leaf」）"
            return [pscustomobject]$res
        }

        $next = Invoke-RcloneList -RcloneExe $RcloneExe -Path $cur -TimeoutSec $TimeoutSec
        if (-not $next.Ok) {
            $v = Get-RemoteTextVerdict $next.Text
            if ($v) { $res.Verdict = $v } else { $res.Verdict = 'TRANSIENT' }
            $res.MissingAt = $cur
            $res.LeafNames = $curList.Names
            $res.Message   = "父目录里明明有「$leaf」，却列不出 $cur（rclone 码 $($next.Code)）：$($next.Text)"
            return [pscustomobject]$res
        }
        $curList = $next
    }

    $res.LeafExists = $true
    $res.LeafNames  = $curList.Names
    $res.Verdict    = 'OK'
    $res.Message    = "远端可列且目标存在：$Remote（$($curList.Path) 下有 $($curList.Names.Count) 项）"
    return [pscustomobject]$res
}

function Get-RemoteTextVerdict {
    <#
      rclone 报错文本 → AUTH / TRANSIENT（判不出来返回空串，由调用方兜底 TRANSIENT）。
      存在的意义：把「token 过期」与「网络抖」区分开，好让日志给出正确处置建议。
    #>
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $t = $Text.ToLowerInvariant()
    if ($t -match '401|403|unauthorized|forbidden|invalid.?token|token.{0,12}expir|authorization') { return 'AUTH' }
    if ($t -match 'no such host|dial tcp|connection refused|connection reset|i/o timeout|context deadline exceeded|tls handshake|unexpected eof|too many requests|429|50[234]') { return 'TRANSIENT' }
    return ''
}

# ------------------------------------------------------------------ 带重试封装
function Resolve-RemoteVerdict {
    <#
      带重试的探测：只有 TRANSIENT 才重试（EMPTY / OK / AUTH 立即返回，别浪费开机时间）。
      返回最后一次的探测对象（含 .Verdict / .Message）。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$RcloneExe,
        [Parameter(Mandatory=$true)][string]$Remote,
        [string]$Root = "",
        [int]$Attempts = 3,
        [int]$DelaySec = 6,
        [int]$TimeoutSec = 25
    )
    $last = $null
    $n = [Math]::Max(1, $Attempts)
    for ($i = 1; $i -le $n; $i++) {
        $last = Get-RemoteProbe -RcloneExe $RcloneExe -Remote $Remote -Root $Root -TimeoutSec $TimeoutSec
        if ($last.Verdict -ne 'TRANSIENT') { return $last }
        if ($i -lt $n) {
            Write-Warning "[remote] 第 $i/$n 次探测为 TRANSIENT：$($last.Message)"
            Write-Warning "[remote] $DelaySec 秒后重试……"
            Start-Sleep -Seconds $DelaySec
        }
    }
    return $last
}

function Test-AlistRemoteReachable {
    <#
      「139 根是否可列」的布尔判定（带重试）。$true = 网络+鉴权都正常。
      用途：sync-up 推数据前的守卫 —— 探不到就绝不 mkdir/copy，避免在 139 上留垃圾。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$RcloneExe,
        [Parameter(Mandatory=$true)][string]$Remote,
        [string]$Root = "",
        [int]$Attempts = 3,
        [int]$DelaySec = 6,
        [int]$TimeoutSec = 25,
        [switch]$Quiet
    )
    $n = [Math]::Max(1, $Attempts)
    for ($i = 1; $i -le $n; $i++) {
        $p = Get-RemoteProbe -RcloneExe $RcloneExe -Remote $Remote -Root $Root -TimeoutSec $TimeoutSec
        if ($p.RootOk) { return $true }
        if (-not $Quiet) { Write-Warning "[remote] 第 $i/$n 次探测不可达（$($p.Verdict)）：$($p.Message)" }
        if ($i -lt $n) { Start-Sleep -Seconds $DelaySec }
    }
    return $false
}

# ------------------------------------------------------------------ 状态读取
function Get-RestoreStatus {
    <#
      读 <SysDir>\_state\restore-status.json（无则 $null）。结构：
        { updated_utc, host, run_id, role, data{status,reason,...}, snapshot{status,reason,...} }
    #>
    param([string]$SysDir = "")
    if ([string]::IsNullOrWhiteSpace($SysDir)) {
        if ($env:CLOUDRDP_SYS_DIR) { $SysDir = $env:CLOUDRDP_SYS_DIR }
        elseif (Test-Path 'D:\') { $SysDir = 'D:\cloudrdp-sys' }
        else { $SysDir = 'C:\cloudrdp-sys' }
    }
    $p = Join-Path $SysDir '_state\restore-status.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Get-RestoreStatusValue {
    <#
      取某作用域的状态串：-Scope snapshot -> 'OK'|'EMPTY'|'TRANSIENT'|'FAILED'|'AUTH'|'PARTIAL'（无记录返回 ''）。
    #>
    param(
        [ValidateSet('data', 'snapshot')][string]$Scope = 'data',
        [string]$SysDir = ""
    )
    $o = Get-RestoreStatus -SysDir $SysDir
    if (-not $o) { return '' }
    $p = $o.PSObject.Properties[$Scope]
    if ($p -and $p.Value) { return [string]$p.Value.status }
    return ''
}

function Get-GhEnvValue {
    <#
      从 GITHUB_ENV 文件里取某个变量的**最后一次**写入值。
      为什么需要：写 GITHUB_ENV 只对**后续步骤**生效，当前进程的 $env: 不会变；
      而 pre-restore 需要在同一进程里读回 restore-snapshot.ps1 刚写的 SNAPSHOT_STATUS。
    #>
    param([Parameter(Mandatory=$true)][string]$Name)
    if (-not $env:GITHUB_ENV) { return '' }
    if (-not (Test-Path -LiteralPath $env:GITHUB_ENV)) { return '' }
    $v = ''
    try {
        $rx = '^' + [regex]::Escape($Name) + '=(.*)$'
        foreach ($line in @(Get-Content -LiteralPath $env:GITHUB_ENV -ErrorAction SilentlyContinue)) {
            $m = [regex]::Match([string]$line, $rx)
            if ($m.Success) { $v = $m.Groups[1].Value }
        }
    } catch { }
    return $v
}

# ------------------------------------------------------------------ 状态落盘
function Set-RestoreStatus {
    <#
      统一写「数据恢复 / 快照拉取」状态。三处落地，缺一不可：
        1) GITHUB_ENV：RESTORE_STATUS / RESTORE_REASON（供后续步骤与保活自愈判断）
        2) <SysDir>\_state\restore-status.json（供工作台经 SMB 读，含 reason / 时间 / 远端路径）
        3) 标记文件（向后兼容 README 里写的 _RESTORE_FAILED.txt）
      绝不做「网络失败也报 OK」这种事：Status 由调用方按 Verdict 传。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Status,
        [string]$Reason = "",
        [ValidateSet('data', 'snapshot')][string]$Scope = 'data',
        [string]$SysDir = "",
        [string]$Remote = "",
        [string]$Local  = "",
        [switch]$KeepLegacyMarker
    )
    $st = ([string]$Status).Trim().ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($st)) { $st = 'UNKNOWN' }

    if ([string]::IsNullOrWhiteSpace($SysDir)) {
        if ($env:CLOUDRDP_SYS_DIR) { $SysDir = $env:CLOUDRDP_SYS_DIR }
        elseif (Test-Path 'D:\') { $SysDir = 'D:\cloudrdp-sys' }
        else { $SysDir = 'C:\cloudrdp-sys' }
    }

    # ---- 1) GITHUB_ENV ----
    try {
        if ($env:GITHUB_ENV) {
            if ($Scope -eq 'snapshot') {
                "SNAPSHOT_STATUS=$st" | Out-File $env:GITHUB_ENV -Append -Encoding ascii
            } else {
                "RESTORE_STATUS=$st" | Out-File $env:GITHUB_ENV -Append -Encoding ascii
            }
            "RESTORE_REASON=$Reason" | Out-File $env:GITHUB_ENV -Append -Encoding ascii
        }
    } catch { Write-Warning "[remote] 写 GITHUB_ENV 失败：$($_.Exception.Message)" }

    # ---- 2) _state\restore-status.json（工作台读这个）----
    # 按 scope 分键合并写：data / snapshot 各占一个键，**互不覆盖**。
    # （踩过的坑：sync-down 与 pre-restore 都写同一个文件，后写的把先写的冲掉，
    #   于是「数据恢复了没」和「快照拉下来了没」只能看到一个。）
    try {
        $stateDir = Join-Path $SysDir '_state'
        New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
        $jsonPath = Join-Path $stateDir 'restore-status.json'

        $obj = [ordered]@{
            updated_utc = (Get-Date).ToUniversalTime().ToString('o')
            host        = $env:COMPUTERNAME
            run_id      = $env:GITHUB_RUN_ID
            role        = if ($env:POOL_ROLE) { $env:POOL_ROLE } else { '' }
        }
        if (Test-Path -LiteralPath $jsonPath) {
            try {
                $old = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($k in @('data', 'snapshot')) {
                    if ($old.PSObject.Properties[$k] -and $old.$k) { $obj[$k] = $old.$k }
                }
                # 兼容更早的单对象结构（顶层 status/reason）：当作 data 读回来
                if (-not $obj.Contains('data') -and $old.PSObject.Properties['status'] -and $old.status) {
                    $obj['data'] = [ordered]@{
                        status = [string]$old.status; reason = [string]$old.reason
                        at_utc = [string]$old.at_utc; scope = 'data'
                    }
                }
            } catch { }
        }
        $obj[$Scope] = [ordered]@{
            status = $st
            reason = $Reason
            scope  = $Scope
            remote = $Remote
            local  = $Local
            at_utc = (Get-Date).ToUniversalTime().ToString('o')
        }
        # 先写临时文件再替换，避免工作台读到写了一半的 JSON
        $tmp = $jsonPath + '.tmp'
        ($obj | ConvertTo-Json -Depth 6) | Out-File -LiteralPath $tmp -Encoding UTF8
        try { if ([System.IO.File]::Exists($jsonPath)) { [System.IO.File]::Delete($jsonPath) } } catch { }
        [System.IO.File]::Move($tmp, $jsonPath)
    } catch { Write-Warning "[remote] 写 restore-status.json 失败：$($_.Exception.Message)" }

    # ---- 3) 标记文件（数据作用域；沿用 README 里的老名字）----
    if ($Scope -eq 'data' -and -not [string]::IsNullOrWhiteSpace($Local)) {
        try {
            $fail  = Join-Path $Local '_RESTORE_FAILED.txt'
            $empty = Join-Path $Local '_RESTORE_EMPTY.txt'
            foreach ($f in @($fail, $empty)) {
                try { if ([System.IO.File]::Exists($f)) { [System.IO.File]::Delete($f) } } catch { }
            }
            if ($st -eq 'EMPTY' -and $KeepLegacyMarker) {
                @(
                  "restore EMPTY at $((Get-Date).ToUniversalTime().ToString('o'))"
                  "reason=$Reason"
                  "remote=$Remote"
                ) | Out-File -LiteralPath $empty -Encoding utf8
            } elseif ($st -in @('TRANSIENT', 'FAILED', 'AUTH') -and $KeepLegacyMarker) {
                @(
                  "restore $st at $((Get-Date).ToUniversalTime().ToString('o'))"
                  "reason=$Reason"
                  "remote=$Remote"
                ) | Out-File -LiteralPath $fail -Encoding utf8
            }
        } catch { Write-Warning "[remote] 写标记文件失败：$($_.Exception.Message)" }
    }
}
