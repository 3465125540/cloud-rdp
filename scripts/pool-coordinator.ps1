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

# ---------- 2. 决策 ----------
$plan = Get-PoolPlan -Config $cfg -Alive $alive -Now $now
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
