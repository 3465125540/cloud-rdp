#requires -Version 5.1
<#
.SYNOPSIS
    账号池公共库：读池配置 / GitHub API 封装 / 在跑机发现 / 角色决策 / 池状态构造。

.DESCRIPTION
    被两处复用：
      * hub 侧：scripts/pool-coordinator.ps1（巡检 + 补机 + 轮换 + 发布权威角色）
      * spoke 侧：windows-rdp.yml 的池角色逻辑（standby 轮询 hub 状态 → 自升为主）
    所有网络函数都接受 -ApiBaseUri / -RawBaseUri，便于单测注入本地 mock，不碰真 GitHub。

    设计要点：
      * 一个账号 = 一个 fork（owner/repo）。同一账号的 fork 自带 concurrency 串行 → 天然一台机。
      * 角色：primary = 最老的在跑机（稳定、不抖动）；其余 standby。
      * 跨账号约束：同一 owner 绝不出现在两台在跑机里。
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

function Get-PoolConfig {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Join-Path $PSScriptRoot 'pool-config.json' }
    if (-not (Test-Path -LiteralPath $Path)) { throw "pool-config.json 不存在：$Path" }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    return ($raw | ConvertFrom-Json)
}

# 从 env 读某个账号的 PAT。两级来源，读不到返回 ''：
#   ① 统一 JSON Secret：POOL_TOKENS = {"<owner>":"ghp_...","<id>":"ghp_..."}（推荐，加账号不用改 workflow）
#   ② 每账号一个 Secret：账号配置里的 token_secret 指定 env 名
function Get-PoolAccountToken {
    param($Account)
    if (-not $Account) { return '' }
    $json = [string]$env:POOL_TOKENS
    if (-not [string]::IsNullOrWhiteSpace($json)) {
        try {
            $map = $json | ConvertFrom-Json
            foreach ($key in @([string]$Account.owner, [string]$Account.id)) {
                if ([string]::IsNullOrWhiteSpace($key)) { continue }
                $prop = $map.PSObject.Properties[$key]
                if ($prop -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)) { return [string]$prop.Value }
            }
        } catch { }
    }
    $name = [string]$Account.token_secret
    if ([string]::IsNullOrWhiteSpace($name)) { return '' }
    $item = Get-Item -Path ("Env:" + $name) -ErrorAction SilentlyContinue
    if (-not $item) { return '' }
    return [string]$item.Value
}

# 统一的 GitHub REST 调用（GET/POST/...）。失败抛异常，由调用方兜。
function Invoke-GhApi {
    param(
        [string]$Token,
        [string]$Method = 'GET',
        [string]$Path,
        [object]$Body = $null,
        [string]$ApiBaseUri = 'https://api.github.com',
        [int]$TimeoutSec = 30
    )
    $headers = @{
        Accept                 = 'application/vnd.github+json'
        'User-Agent'           = 'cloud-rdp-pool'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    if (-not [string]::IsNullOrWhiteSpace($Token)) { $headers['Authorization'] = "Bearer $Token" }
    $uri = ($ApiBaseUri.TrimEnd('/')) + $Path
    $params = @{ Uri = $uri; Method = $Method; Headers = $headers; TimeoutSec = $TimeoutSec }
    if ($null -ne $Body) {
        $params['ContentType'] = 'application/json'
        $params['Body']        = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 8))
    }
    return Invoke-RestMethod @params
}

# 列某账号 fork 的「在跑机」（in_progress / queued / waiting / requested）。
function Get-AccountAliveRuns {
    param(
        $Account,
        [string]$Token,
        [string]$Workflow = 'windows-rdp.yml',
        [string]$ApiBaseUri = 'https://api.github.com',
        [int]$PerPage = 20
    )
    if ([string]::IsNullOrWhiteSpace($Token)) {
        return @{ ok = $false; error = "缺 token（Secret $($Account.token_secret) 未配置）"; runs = @() }
    }
    $path = "/repos/$($Account.owner)/$($Account.repo)/actions/workflows/$Workflow/runs?per_page=$PerPage"
    try {
        $resp = Invoke-GhApi -Token $Token -Path $path -ApiBaseUri $ApiBaseUri
    } catch {
        return @{ ok = $false; error = $_.Exception.Message; runs = @() }
    }
    $alive = @()
    foreach ($r in @($resp.workflow_runs)) {
        if ($r.status -in @('in_progress', 'queued', 'waiting', 'requested', 'pending')) {
            $alive += [pscustomobject]@{
                account = [string]$Account.id
                owner   = [string]$Account.owner
                repo    = [string]$Account.repo
                run_id  = $r.id
                status  = [string]$r.status
                started = $(if ($r.run_started_at) { $r.run_started_at } else { $r.created_at })
                created = $r.created_at
                event   = [string]$r.event
                url     = [string]$r.html_url
            }
        }
    }
    return @{ ok = $true; error = ''; runs = $alive }
}

# 触发某账号 fork 的 workflow_dispatch。
function Invoke-WorkflowDispatch {
    param(
        $Account,
        [string]$Token,
        [string]$Workflow,
        [string]$Ref,
        [hashtable]$Inputs,
        [string]$ApiBaseUri = 'https://api.github.com'
    )
    if ([string]::IsNullOrWhiteSpace($Token)) {
        return @{ ok = $false; error = "缺 token（Secret $($Account.token_secret) 未配置）" }
    }
    $path = "/repos/$($Account.owner)/$($Account.repo)/actions/workflows/$Workflow/dispatches"
    $body = @{ ref = $Ref; inputs = $Inputs }
    try {
        Invoke-GhApi -Token $Token -Method 'POST' -Path $path -Body $body -ApiBaseUri $ApiBaseUri | Out-Null
        return @{ ok = $true; error = '' }
    } catch {
        $detail = ''
        if ($_.Exception.Response) {
            try {
                $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $detail = $sr.ReadToEnd(); $sr.Close()
            } catch { }
        }
        return @{ ok = $false; error = ("$($_.Exception.Message) $detail").Trim() }
    }
}

# 角色决策：primary = 最老的在跑机；其余 standby。
function Resolve-PoolRoles {
    param([object[]]$Alive)
    $sorted = @($Alive | Sort-Object -Property @{ Expression = {
        $s = if ($_.started) { $_.started } else { $_.created }
        try { [datetime]$s } catch { [datetime]'2999-01-01' }
    } })
    $primary = $null
    if ($sorted.Count -gt 0) { $primary = $sorted[0] }
    return [pscustomobject]@{
        primary = $primary
        standby = @($sorted | Select-Object -Skip 1)
        alive   = $sorted
    }
}

# 构造池状态对象（写进 hub 的 pool-state 分支；spoke 读它决定角色）。
function Build-PoolState {
    param($Config, [object[]]$Alive, [int]$TargetMachines = 0)
    if ($TargetMachines -le 0) { $TargetMachines = [int]$Config.target_machines }
    $roles = Resolve-PoolRoles -Alive $Alive
    function ConvOne($m) {
        if (-not $m) { return $null }
        return [ordered]@{
            account = $m.account
            owner   = $m.owner
            repo    = $m.repo
            run_id  = $m.run_id
            since   = $(if ($m.started) { $m.started } else { $m.created })
        }
    }
    $state = [ordered]@{
        version         = 1
        pool_id         = [string]$Config.pool_id
        updated_utc     = (Get-Date).ToUniversalTime().ToString('o')
        target_machines = $TargetMachines
        primary         = (ConvOne $roles.primary)
        standby         = @($roles.standby | ForEach-Object { ConvOne $_ })
    }
    return $state
}

# spoke 侧：从 hub 的 raw 地址读池状态（公开仓库免认证）。读不到返回 $null。
function Get-PoolState {
    param(
        [string]$HubOwner,
        [string]$HubRepo,
        [string]$StateBranch,
        [string]$StatePath,
        [string]$RawBaseUri = 'https://raw.githubusercontent.com',
        [int]$TimeoutSec = 20
    )
    $url = "$($RawBaseUri.TrimEnd('/'))/$HubOwner/$HubRepo/$StateBranch/$StatePath"
    try {
        $txt = Invoke-RestMethod -Uri $url -TimeoutSec $TimeoutSec -Headers @{ 'User-Agent' = 'cloud-rdp-pool' }
        if ($txt -is [string]) { return ($txt | ConvertFrom-Json) }
        return $txt
    } catch {
        return $null
    }
}

# ---------------------------------------------------------------- 决策核心
# 输入：配置 + 当前在跑机列表 + 现在时间
# 输出：{ dispatch = @( {account, role, reason} ); desiredOwners = @(...); reason = '...' }
function Get-PoolPlan {
    param($Config, [object[]]$Alive, [datetime]$Now)

    $target   = [int]$Config.target_machines
    $life     = [int]$Config.machine.lifetime_minutes
    $lead     = [int]$Config.machine.rotate_lead_minutes
    $accounts = @($Config.accounts | Where-Object { $_.enabled -ne $false })
    $alive    = @($Alive)
    $nowUtc   = $Now.ToUniversalTime()

    $busy   = @($alive | ForEach-Object { [string]$_.owner })
    # 注意：用 ::new() 而非 New-Object —— Windows PowerShell 5.1 下
    # 「New-Object 建的 List[object]」被 @() 包住会抛 ArgumentException（参数类型不匹配）。
    $plan   = [System.Collections.Generic.List[object]]::new()

    # 选一个「没被占用」的账号；可排除某个 owner（轮换时排除被替换者）
    $pickFree = {
        param([string]$excludeOwner)
        foreach ($a in $accounts) {
            if ($busy -contains [string]$a.owner) { continue }
            if ($a.owner -eq $excludeOwner) { continue }
            return $a
        }
        return $null
    }

    # ① 补足数量
    $shortage = $target - $alive.Count
    for ($i = 0; $i -lt $shortage; $i++) {
        $a = & $pickFree ''
        if (-not $a) { break }
        $plan.Add([pscustomobject]@{ account = $a; role = ''; reason = 'fill' }) | Out-Null
        $busy += [string]$a.owner
    }

    # ② 轮换：到寿命阈值就提前派替补（不同账号）
    foreach ($m in $alive) {
        $s = if ($m.started) { $m.started } else { $m.created }
        $age = 0.0
        try { $age = ($nowUtc - ([datetime]$s).ToUniversalTime()).TotalMinutes } catch { }
        if ($age -ge ($life - $lead)) {
            $a = & $pickFree ([string]$m.owner)
            if ($a) {
                $plan.Add([pscustomobject]@{ account = $a; role = ''; reason = ('rotate ' + $m.owner) }) | Out-Null
                $busy += [string]$a.owner
            }
        }
    }

    # ③ 角色：把 alive + 新派发合起来，最老的 owner = primary
    $merged = [System.Collections.Generic.List[object]]::new()
    foreach ($m in $alive) {
        $s = if ($m.started) { $m.started } else { $m.created }
        $merged.Add([pscustomobject]@{ owner = [string]$m.owner; started = $s }) | Out-Null
    }
    foreach ($p in $plan) {
        $merged.Add([pscustomobject]@{ owner = [string]$p.account.owner; started = $nowUtc.ToString('o') }) | Out-Null
    }
    $sorted = @($merged | Sort-Object -Property @{ Expression = { try { [datetime]$_.started } catch { [datetime]'2999-01-01' } } })
    $primaryOwner = ''
    if ($sorted.Count -gt 0) { $primaryOwner = [string]$sorted[0].owner }
    foreach ($p in $plan) {
        if ([string]$p.account.owner -eq $primaryOwner) { $p.role = 'primary' } else { $p.role = 'standby' }
    }

    return [pscustomobject]@{
        dispatch     = $plan.ToArray()
        primaryOwner = $primaryOwner
        aliveCount   = $alive.Count
        target       = $target
        reason       = "alive=$($alive.Count)/$target plan=$($plan.Count)"
    }
}

# 把池状态写成 JSON 文本（供 workflow 落盘到 pool-state 分支）
function ConvertTo-PoolStateJson {
    param($State)
    return ($State | ConvertTo-Json -Depth 8)
}
