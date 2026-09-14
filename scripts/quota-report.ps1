<#
.SYNOPSIS
  估算本月 GitHub Actions 额度消耗（账号级），并在剩余偏低时告警。
.NOTES
  优先数据源：官方 Billing API
    GET /users/{owner}/settings/billing/usage?year=YYYY&month=M
    需要 user scope 的令牌（放在 Secret: GH_BILLING_TOKEN）
    口径实测：quantity 为「原始分钟」，免费额度 2000 分钟按原始分钟抵扣，不乘 OS 倍率。
  回退数据源：本仓库 run 历史（GITHUB_TOKEN + actions: read）
    Σ(墙钟分钟) —— 只统计本仓库，不含其它仓库。
  输出：GITHUB_ENV 写 QUOTA_LEFT_PCT / QUOTA_LEFT_MIN / QUOTA_SOURCE
  永不返回非 0。
#>

param(
    [int]$MonthlyQuota = 2000,
    [int]$WarnPercent  = 20
)

$ErrorActionPreference = "Continue"

function Set-GhEnv([string]$kv) {
    if ($env:GITHUB_ENV) { $kv | Out-File $env:GITHUB_ENV -Append -Encoding ascii }
}

$owner = $env:GITHUB_REPOSITORY_OWNER
$repo  = $env:GITHUB_REPOSITORY
$now   = (Get-Date).ToUniversalTime()
$y     = $now.Year
$m     = $now.Month

$used   = -1
$source = "none"

# ---------- ① 官方 Billing API（账号级）----------
$billTok = $env:GH_BILLING_TOKEN
if (-not [string]::IsNullOrWhiteSpace($billTok) -and -not [string]::IsNullOrWhiteSpace($owner)) {
    $url = "https://api.github.com/users/$owner/settings/billing/usage?year=$y&month=$m"
    $headers = @{
        Authorization = "Bearer $billTok"
        Accept        = "application/vnd.github+json"
        "User-Agent"  = "cloud-rdp-quota"
    }
    try {
        $resp  = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 30
        $items = @($resp.usageItems | Where-Object { $_.product -eq "actions" })
        if ($items.Count -gt 0) {
            $sum = 0.0
            foreach ($i in $items) { $sum += [double]$i.quantity }
            $used   = [int][math]::Round($sum)
            $source = "billing-api"
            Write-Host ("[quota] 官方 Billing API：本月 actions 用量 {0} 分钟（{1} 条，账号级）" -f $used, $items.Count)
        } else {
            $used   = 0
            $source = "billing-api"
            Write-Host "[quota] 官方 Billing API：本月暂无 actions 用量"
        }
    } catch {
        Write-Host "[quota] Billing API 调用失败（$($_.Exception.Message)），回退到 run 历史估算"
    }
}

# ---------- ② 回退：本仓库 run 历史 ----------
if ($used -lt 0) {
    if ([string]::IsNullOrWhiteSpace($repo) -or [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        Write-Host "[quota] 无可用数据源（缺 GH_BILLING_TOKEN / GITHUB_TOKEN），跳过额度估算"
        exit 0
    }
    $monthStart = $now.ToString("yyyy-MM-01")
    $headers = @{
        Authorization = "Bearer $($env:GITHUB_TOKEN)"
        Accept        = "application/vnd.github+json"
        "User-Agent"  = "cloud-rdp-quota"
    }
    $url = "https://api.github.com/repos/$repo/actions/runs?created=%3E=$monthStart&per_page=100"
    try {
        $resp = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 30
    } catch {
        Write-Host "[quota] 查询 run 历史也失败：$($_.Exception.Message)"
        exit 0
    }
    $sum = 0.0
    $cnt = 0
    foreach ($r in $resp.workflow_runs) {
        $start = [datetime]::Parse($r.run_started_at).ToUniversalTime()
        if ($r.status -eq "completed") {
            $end = [datetime]::Parse($r.updated_at).ToUniversalTime()
        } else {
            $end = $now
        }
        $mins = ($end - $start).TotalMinutes
        if ($mins -gt 0) { $sum += $mins; $cnt++ }
    }
    $used   = [int][math]::Round($sum)
    $source = "run-history"
    Write-Host ("[quota] 回退估算：本仓库本月 {0} 次 run，墙钟合计 {1} 分钟（不含其它仓库）" -f $cnt, $used)
}

# ---------- 汇总 ----------
$left = $MonthlyQuota - $used
if ($left -lt 0) { $left = 0 }
if ($MonthlyQuota -gt 0) {
    $pct = [int][math]::Round(100.0 * $left / $MonthlyQuota)
} else {
    $pct = 0
}

Write-Host ("[quota] 本月已用 {0}/{1} 分钟，剩余 {2} 分钟（{3}%）  来源={4}" -f `
    $used, $MonthlyQuota, $left, $pct, $source)

if ($pct -le $WarnPercent) {
    $runsLeft = [int][math]::Floor($left / 360)
    if ($runsLeft -ge 1) {
        Write-Warning ("[quota] 额度告急！只剩 {0} 分钟（{1}%）。跑满约 {2} 次后，定时任务会静默停摆，次月 1 号才重置。" -f `
            $left, $pct, $runsLeft)
    } else {
        Write-Warning ("[quota] 额度告急！只剩 {0} 分钟（{1}%），已不足一次满时长运行。定时任务随时会静默停摆，次月 1 号才重置。" -f `
            $left, $pct)
    }
}

Set-GhEnv "QUOTA_LEFT_PCT=$pct"
Set-GhEnv "QUOTA_LEFT_MIN=$left"
Set-GhEnv "QUOTA_SOURCE=$source"
exit 0
