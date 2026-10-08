#requires -Version 5.1
<#
.SYNOPSIS
    hub 协调器：巡检账号池 → 维持 target_machines 台在跑 → 指派 primary/standby → 发布权威状态。

.DESCRIPTION
    跑在 hub 仓库的定时 workflow（pool-coordinator.yml）里。每 10 分钟一次：
      ① 用各账号 PAT 查各 fork 的「在跑机」（in_progress/queued）
      ② 决策：补足到 target_machines 台；对到寿命阈值的机器提前派替补（换账号）
      ③ 用对应账号的 PAT 触发 windows-rdp.yml（带上 pool_role / pool_hub / pool_id）
      ④ 把权威角色写进 state/pool-state.json（由 workflow 推到 pool-state 分支；spoke 读它）

    永不返回非 0 —— 协调失败不该让定时任务标红。缺 token / 查不到都只跳过并记录。

.PARAMETER DryRun
    只打印决策、不真派发（用于演练 / 单测）。
#>
[CmdletBinding()]
param(
    [string]$ConfigPath   = '',
    [string]$ApiBaseUri   = 'https://api.github.com',
    [string]$OutStatePath = '',
    [string]$PrevStatePath= '',
    [int]   $DispatchGuardMinutes = 8,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'pool-lib.ps1')

function Say([string]$m) { Write-Host "[pool] $m" }

if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot 'pool-config.json' }
$cfg = Get-PoolConfig -Path $ConfigPath

$hub = $cfg.hub
$wf  = $(if ($hub.workflow) { [string]$hub.workflow } else { 'windows-rdp.yml' })
$ref = $(if ($hub.ref) { [string]$hub.ref } else { 'main' })

$now = (Get-Date).ToUniversalTime()

Say "池 = $($cfg.pool_id)  目标 = $($cfg.target_machines) 台  模式 = $(if ($DryRun) { 'DRY-RUN' } else { 'LIVE' })"
Say "hub = $($hub.owner)/$($hub.repo)  状态分支 = $($hub.state_branch)  触发 ref = $ref"

# ---------- 0. 读上一轮状态（防重复派发用）----------
$recent = @{}
if (-not [string]::IsNullOrWhiteSpace($PrevStatePath) -and (Test-Path -LiteralPath $PrevStatePath)) {
    try {
        $prev = (Get-Content -LiteralPath $PrevStatePath -Raw -Encoding UTF8) | ConvertFrom-Json
        if ($prev.recent_dispatches) {
            foreach ($prop in $prev.recent_dispatches.PSObject.Properties) {
                try { $recent[$prop.Name] = ([datetime]$prop.Value).ToUniversalTime() } catch { }
            }
        }
        Say "读到上一轮状态（$(if ($prev.updated_utc) { $prev.updated_utc } else { '?' })）"
    } catch { Say "上一轮状态解析失败：$($_.Exception.Message)" }
}

# ---------- 1. 发现各账号在跑机 ----------
# 顺带收集「每账号巡检明细」($reports)，随池状态一起发布 —— 工作台读它做实时状态监测。
$alive    = @()
$accounts = @($cfg.accounts)
$reports  = @()
foreach ($acc in $accounts) {
    $rep = [pscustomobject]@{
        id          = [string]$acc.id
        owner       = [string]$acc.owner
        repo        = [string]$acc.repo
        enabled     = ($acc.enabled -ne $false)
        secret_name = [string]$acc.token_secret
        token_state = 'ok'        # ok | missing | query_failed | disabled
        alive_count = 0
        # 「在跑」拆两档：真在跑（in_progress）/ 排队中（pending/queued/…，机器还没起）。
        # alive_count 仍 = 未结束的 run 总数（Get-PoolPlan 用它做防抖，别改口径），
        # running/queued 只供工作台如实展示 —— 否则面板「在跑 2 台」会和
        # 「机器运行实况」只显示 1 台打架（排队中的机器 tailnet 上看不到）。
        running_count = 0
        queued_count  = 0
        total       = 0
        last_run    = $null
        note        = ''
    }
    if ($acc.enabled -eq $false) {
        $rep.token_state = 'disabled'
        $rep.note        = '账号已停用'
        $reports += $rep
        continue
    }
    $tok = Get-PoolAccountToken -Account $acc
    if ([string]::IsNullOrWhiteSpace($tok)) {
        $rep.token_state = 'missing'
        $rep.note        = "Secret $($acc.token_secret) 未配置"
        Say "账号 $($acc.id) ($($acc.owner))：跳过（Secret $($acc.token_secret) 未配置）"
        $reports += $rep
        continue
    }
    $r = Get-AccountAliveRuns -Account $acc -Token $tok -Workflow $wf -ApiBaseUri $ApiBaseUri
    if (-not $r.ok) {
        $rep.token_state = 'query_failed'
        $rep.note        = [string]$r.error
        Say "账号 $($acc.id) ($($acc.owner))：查询失败 —— $($r.error)"
        $reports += $rep
        continue
    }
    $rep.alive_count = @($r.runs).Count
    # 真在跑 = GitHub run 状态严格是 in_progress；其余未结束的（pending/queued/…）算排队中。
    $rep.running_count = @($r.runs | Where-Object { $_.status -eq 'in_progress' }).Count
    $rep.queued_count  = $rep.alive_count - $rep.running_count
    $rep.total       = [int]$r.total
    $rep.last_run    = $r.last_run
    Say "账号 $($acc.id) ($($acc.owner))：在跑 $($rep.running_count) 台 / 排队 $($rep.queued_count) 台（未结束 $($r.runs.Count)，历史 $($r.total) 条）"
    $alive += $r.runs
    $reports += $rep
}
Say "在跑机合计 = $($alive.Count) / 目标 $($cfg.target_machines)"

# ---------- 1b. fork 漂移自愈：把各 fork 的 main 快进到 hub ----------
# 为什么放在「决策」之前、且不受 -DryRun 影响：
#   fork 落后 → 机器跑到旧 workflow（0p 同步不到 .github/workflows/）→ 新步骤不生效。
#   这是「用户每次开机都要找人救」的根因。自愈是幂等、只读→快进 的低危动作，
#   与「派发机器」是两回事，所以 dry-run 也照做（-DryRun 只挡派发，不挡自愈）。
$forkSync = @()
foreach ($acc in $accounts) {
    if ($acc.enabled -eq $false) { continue }
    $s = Sync-PoolFork -Account $acc -Token (Get-PoolAccountToken -Account $acc) `
                       -HubOwner ([string]$hub.owner) -HubRepo ([string]$hub.repo) `
                       -Branch $ref -ApiBaseUri $ApiBaseUri
    if ($s.action -eq 'synced') {
        Say "fork 自愈：$($acc.id) ($($acc.owner)) —— $($s.note)"
    } elseif ($s.action -in @('diverged', 'error')) {
        Say "fork 自愈：$($acc.id) ($($acc.owner)) 未同步 —— $($s.note)"
    }
    $forkSync += [pscustomobject]@{ id = [string]$acc.id; owner = [string]$acc.owner;
                                    action = [string]$s.action; ok = [bool]$s.ok; note = [string]$s.note }
}
Say "fork 自愈：$(@($forkSync | Where-Object { $_.action -eq 'synced' }).Count) 个已快进 / 共 $($forkSync.Count) 个账号（其余：已最新/本仓库/无 token）"

# ---------- 2. 决策 ----------
# 从上一轮状态里挑出「已知不可用」的账号：凭证坏（query_failed / missing）或上一轮派发失败。
# 它们本轮不参与候选 —— 死账号占着候选位会让协调器每轮都白试一遍、永远轮不到能用的那个
# （acc-1 账号被停用 + acc-4 Actions 被禁用时，池子就是这样卡在 1/2 台补不上）。
# 只取上一轮 → 天然一轮自愈：账号恢复后下一轮就不再被跳过。
$blocked = @()
if ($prev -and $prev.accounts) {
    foreach ($pa in @($prev.accounts)) {
        if (-not $pa) { continue }
        $own = [string]$pa.owner
        if ([string]::IsNullOrWhiteSpace($own)) { continue }
        $ts = [string]$pa.token_state
        if ($ts -eq 'query_failed' -or $ts -eq 'missing') { $blocked += $own; continue }
        if ([string]$pa.note -like '*派发失败*') { $blocked += $own; continue }
        # ⚠️ 还有一类「派发成功但机器起不来」：GitHub 收下 dispatch（204）、run 也建出来了，
        #    但 job 根本没建（0 jobs）→ conclusion = startup_failure。
        #    典型原因：账号邮箱未验证 / 该账号 Actions 被禁用 / 账单或额度问题。
        #    这种**不会**留下「派发失败」的痕迹，只看 dispatch 结果永远发现不了 ——
        #    不排掉的话协调器每轮都会白派一次（acc-5 于 2026-10-06 起连续 8 次 startup_failure）。
        $lr = $pa.last_run
        if ($lr -and [string]$lr.conclusion -eq 'startup_failure') { $blocked += $own }
    }
    $blocked = @($blocked | Select-Object -Unique)
}

# 把「最近一次 run 启动失败」写进该账号本轮的巡检 note —— 否则面板只显示「凭证正常」，
# 看不出这个账号其实出不了机器（用户 2026-10-08 就是看着 acc-5「凭证正常」来问的）。
if ($prev -and $prev.accounts) {
    foreach ($rep in $reports) {
        $own = [string]$rep.owner
        if ([string]::IsNullOrWhiteSpace($own)) { continue }
        foreach ($pa in @($prev.accounts)) {
            if (-not $pa -or [string]$pa.owner -ne $own) { continue }
            $lr = $pa.last_run
            if ($lr -and [string]$lr.conclusion -eq 'startup_failure') {
                $tag = '最近一次 run 启动失败（startup_failure）：GitHub 没建出 job —— 常见于' +
                       '「账号邮箱未验证」/「该账号 Actions 被禁用」/「账单或额度问题」，' +
                       '去该账号的 GitHub 设置里查（run 页面会有 Annotations 写明原因）'
                if ([string]::IsNullOrWhiteSpace([string]$rep.note)) { $rep.note = $tag }
                else { $rep.note = "$([string]$rep.note)　$tag" }
            }
            break
        }
    }
}
if ($blocked.Count -gt 0) { Say "已知不可用（本轮不参与候选）：$($blocked -join ', ')" }

$plan = Get-PoolPlan -Config $cfg -Alive $alive -Now $now -ExcludeOwners $blocked
Say "决策：$($plan.reason)  primary候选=$($plan.primaryOwner)"

# ---------- 3. 执行派发（带防抖：同一账号 8 分钟内不重复派）----------
$dispatched = @()
$dispatchedNow = @{}
foreach ($d in @($plan.dispatch)) {
    $acc = $d.account
    $lastAt = $null
    if ($recent.ContainsKey([string]$acc.owner)) { $lastAt = $recent[[string]$acc.owner] }
    if ($lastAt -and ($now - $lastAt).TotalMinutes -lt $DispatchGuardMinutes) {
        Say "防抖：账号 $($acc.id) ($($acc.owner)) $([int]($now - $lastAt).TotalMinutes) 分钟前刚派过 → 跳过本轮"
        continue
    }

    $inputs = @{
        duration_minutes = [string]([int]$cfg.machine.keepalive_minutes)
        pool_role        = [string]$d.role
        pool_owner       = [string]$acc.owner
        pool_id          = [string]$cfg.pool_id
        pool_hub         = "$($hub.owner)/$($hub.repo)"
        relay_minutes    = '0'
        install_apps     = 'true'
        migrate_139      = 'false'
        slim_image       = 'auto'
        chinese          = 'on'
    }

    if ($DryRun) {
        Say "[dry-run] 派发 → $($acc.id) ($($acc.owner))  role=$($d.role)  reason=$($d.reason)"
        $dispatched += [pscustomobject]@{ account = $acc; role = $d.role; ok = $true; error = '(dry-run)'; reason = $d.reason }
        $dispatchedNow[[string]$acc.owner] = $now
        continue
    }

    $res = Invoke-WorkflowDispatch -Account $acc -Token (Get-PoolAccountToken -Account $acc) -Workflow $wf -Ref $ref -Inputs $inputs -ApiBaseUri $ApiBaseUri
    if ($res.ok) {
        Say "已派发 → $($acc.id) ($($acc.owner))  role=$($d.role)  reason=$($d.reason)"
        $dispatchedNow[[string]$acc.owner] = $now
    } else {
        Say "派发失败 → $($acc.id) ($($acc.owner)) —— $($res.error)"
    }
    $dispatched += [pscustomobject]@{ account = $acc; role = $d.role; ok = $res.ok; error = $res.error; reason = $d.reason }
}

# ---------- 4. 发布权威状态 ----------
$finalAlive = @($alive)
foreach ($x in $dispatched) {
    if (-not $x.ok) { continue }
    $finalAlive += [pscustomobject]@{
        account = [string]$x.account.id
        owner   = [string]$x.account.owner
        repo    = [string]$x.account.repo
        run_id  = $null
        status  = 'dispatched'
        started = $now.ToString('o')
        created = $now.ToString('o')
        event   = 'pool'
        url     = ''
    }
}
# 把「派发失败」并进对应账号的巡检明细 —— 否则面板只显示「凭证正常」，看不出这个账号其实出不了机器
# （acc-4 的 422 就是这样在面板上藏了一整天）。复用已有的 note 通道，不新增状态字段。
foreach ($x in $dispatched) {
    if ($x.ok) { continue }
    $own = [string]$x.account.owner
    foreach ($rep in $reports) {
        if ([string]$rep.owner -ne $own) { continue }
        $tag = "派发失败（$($x.reason)）：$($x.error)"
        if ([string]::IsNullOrWhiteSpace([string]$rep.note)) { $rep.note = $tag }
        else { $rep.note = "$([string]$rep.note)　$tag" }
        Say "巡检明细：$own 追加派发失败 —— $($x.error)"
        break
    }
}

$state = Build-PoolState -Config $cfg -Alive $finalAlive -Reports $reports

# 记录最近派发时间（供下一轮防抖）
$recentOut = [ordered]@{}
foreach ($k in $recent.Keys) { $recentOut[$k] = $recent[$k].ToString('o') }
foreach ($k in $dispatchedNow.Keys) { $recentOut[$k] = $dispatchedNow[$k].ToString('o') }
$state['recent_dispatches'] = $recentOut

if ([string]::IsNullOrWhiteSpace($OutStatePath)) {
    $OutStatePath = Join-Path $PSScriptRoot '..\state\pool-state.json'
}
$dir = Split-Path -Parent $OutStatePath
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
ConvertTo-PoolStateJson -State $state | Out-File -LiteralPath $OutStatePath -Encoding UTF8

$p = $state.primary
Say ("权威状态：primary = " + $(if ($p) { "$($p.owner) (run $($p.run_id))" } else { '(无)' }) + "  standby = $($state.standby.Count) 台")
Say "状态文件：$OutStatePath  （含 $($reports.Count) 个账号巡检明细）"
exit 0
