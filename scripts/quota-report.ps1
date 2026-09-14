<#
.SYNOPSIS
  估算本月 GitHub Actions 额度消耗，并在剩余偏低时告警。
.NOTES
  数据源：本仓库本月的 workflow run 历史（GET /repos/{repo}/actions/runs）。
  计费口径：额度 = Σ(墙钟分钟) × Windows 倍率(2)。
  注意：只统计「本仓库」的消耗；账号下其它仓库若也跑 Actions 不会计入。
  依赖环境变量：GITHUB_REPOSITORY、GITHUB_TOKEN（需 actions: read）。
  输出：GITHUB_ENV 里写 QUOTA_LEFT_PCT / QUOTA_LEFT_MIN，供后续步骤展示。
  永不返回非 0（额度查询失败不影响开机）。
#>

param(
    [int]$MonthlyQuota    = 2000,
    [int]$WindowsMultiplier = 2,
    [int]$WarnPercent     = 20,
    [int]$MinutesPerRun   = 700
)

$ErrorActionPreference = "Continue"

function Set-GhEnv([string]$kv) {
    if ($env:GITHUB_ENV) { $kv | Out-File $env:GITHUB_ENV -Append -Encoding ascii }
}

$repo = $env:GITHUB_REPOSITORY
$tok  = $env:GITHUB_TOKEN
if ([string]::IsNullOrWhiteSpace($repo) -or [string]::IsNullOrWhiteSpace($tok)) {
    Write-Host "[quota] 缺少 GITHUB_REPOSITORY / GITHUB_TOKEN，跳过额度估算"
    exit 0
}

$monthStart = (Get-Date).ToUniversalTime().ToString("yyyy-MM-01")
$headers = @{
    Authorization = "Bearer $tok"
    Accept        = "application/vnd.github+json"
    "User-Agent"  = "cloud-rdp-quota"
}
$url = "https://api.github.com/repos/$repo/actions/runs?created=%3E=$monthStart&per_page=100"

try {
    $resp = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 30
} catch {
    Write-Host "[quota] 查询 run 历史失败：$($_.Exception.Message)"
    exit 0
}

$now       = (Get-Date).ToUniversalTime()
$totalWall = 0.0
$count     = 0
foreach ($r in $resp.workflow_runs) {
    $start = [datetime]::Parse($r.run_started_at).ToUniversalTime()
    if ($r.status -eq "completed") {
        $end = [datetime]::Parse($r.updated_at).ToUniversalTime()
    } else {
        $end = $now
    }
    $mins = ($end - $start).TotalMinutes
    if ($mins -gt 0) { $totalWall += $mins; $count++ }
}

$used = [int][math]::Round($totalWall * $WindowsMultiplier)
$left = $MonthlyQuota - $used
if ($left -lt 0) { $left = 0 }
if ($MonthlyQuota -gt 0) {
    $pct = [int][math]::Round(100.0 * $left / $MonthlyQuota)
} else {
    $pct = 0
}
$runsLeft = [int][math]::Floor($left / $MinutesPerRun)

Write-Host ("[quota] 本月已用 ≈ {0} 额度（{1} 次运行 / 墙钟 {2:N0} 分钟 / ×{3}）" -f `
    $used, $count, $totalWall, $WindowsMultiplier)
Write-Host ("[quota] 剩余 ≈ {0} 额度（{1}%），按 700/次 估算还能开 {2} 次" -f $left, $pct, $runsLeft)

if ($pct -le $WarnPercent) {
    Write-Warning ("[quota] 额度告急！剩余仅 {0}%（≈{1} 额度）。跑满约 {2} 次后定时就会静默停摆，次月 1 号才重置。" -f $pct, $left, $runsLeft)
}

Set-GhEnv "QUOTA_LEFT_PCT=$pct"
Set-GhEnv "QUOTA_LEFT_MIN=$left"
exit 0
