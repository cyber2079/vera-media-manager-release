# Vera Media Manager — 性能基准:汇总报告生成
# 用途:把 run-<时间戳>/ 下的逐 tick CSV 与 startup JSON 汇总为 summary.md + summary.json
#       (perf.html 页面数字由 summary 人工誊抄排版,脚本不直接生成页面)
#
# 用法:
#   powershell -File scripts/perf/summarize.ps1                      # 汇总最新一次 run
#   powershell -File scripts/perf/summarize.ps1 -RunDir <目录>       # 汇总指定 run

param(
    [string]$RunDir = ""
)

$ErrorActionPreference = "Stop"
Import-Module "$PSScriptRoot\perf-common.psm1" -Force

if (-not $RunDir) {
    $latest = Get-ChildItem "$PSScriptRoot\results" -Directory -Filter "run-*" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $latest) { throw "results/ 下没有 run-* 目录" }
    $RunDir = $latest.FullName
}
if (-not (Test-Path $RunDir)) { throw "目录不存在: $RunDir" }

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  Vera 性能基准 · 汇总: $RunDir" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan

$env2 = $null
if (Test-Path (Join-Path $RunDir "env.json")) {
    $env2 = Get-Content (Join-Path $RunDir "env.json") -Raw -Encoding UTF8 | ConvertFrom-Json
}

# ═══════════════════════════════════════════════
# 场景 CSV 汇总
# ═══════════════════════════════════════════════

$scenarioFiles = Get-ChildItem $RunDir -Filter "scenario_*.csv" | Sort-Object Name
$groups = @{}

foreach ($f in $scenarioFiles) {
    # scenario_<ID>_<app>_run<N>.csv / scenario_S0_ambient_run1.csv
    if ($f.Name -match '^scenario_(S\d+)_(.+)_run(\d+)\.csv$') {
        $sid = $Matches[1]; $app = $Matches[2]; $runN = [int]$Matches[3]
    } else { continue }

    $rows = Import-Csv $f.FullName
    $totals = @($rows | Where-Object { $_.name -eq "__TOTAL__" })
    if ($totals.Count -eq 0) { continue }

    # 每 tick 内存取均值;CPU/GPU 也取均值(采样期不含启动毛刺,稳定段均值即代表常驻占用)
    $runAgg = @{
        run    = $runN
        ticks  = $totals.Count
        wsMB   = [math]::Round((($totals | Measure-Object -Property wsMB -Average).Average), 1)
        privMB = [math]::Round((($totals | Measure-Object -Property privMB -Average).Average), 1)
        cpuPct = [math]::Round((($totals | Measure-Object -Property cpuPct -Average).Average), 2)
        gpuPct = [math]::Round((($totals | Measure-Object -Property gpuPct -Average).Average), 2)
        peakPrivMB = [math]::Round((($totals | Measure-Object -Property privMB -Maximum).Maximum), 1)
    }
    $key = "$sid|$app"
    if (-not $groups.ContainsKey($key)) { $groups[$key] = @() }
    $groups[$key] += $runAgg
}

$scenarioSummary = @()
foreach ($key in ($groups.Keys | Sort-Object)) {
    $parts = $key.Split("|")
    $runs = @($groups[$key])
    $s = @{
        scenario = $parts[0]
        app      = $parts[1]
        n        = $runs.Count
        privMB   = Get-Stats -Values (@($runs | ForEach-Object { [double]$_.privMB }))
        wsMB     = Get-Stats -Values (@($runs | ForEach-Object { [double]$_.wsMB }))
        cpuPct   = Get-Stats -Values (@($runs | ForEach-Object { [double]$_.cpuPct }))
        gpuPct   = Get-Stats -Values (@($runs | ForEach-Object { [double]$_.gpuPct }))
        peakPrivMB = Get-Stats -Values (@($runs | ForEach-Object { [double]$_.peakPrivMB }))
        runs     = $runs
    }
    $scenarioSummary += $s
}

# 环境本底(S0)
$ambient = $null
$ambFile = Join-Path $RunDir "scenario_S0_ambient_run1.csv"
if (Test-Path $ambFile) {
    $rows = Import-Csv $ambFile
    $ambient = @{
        sysCpuPct = [math]::Round((($rows | Measure-Object -Property sysCpuPct -Average).Average), 2)
        availMB   = [math]::Round((($rows | Measure-Object -Property availMB -Average).Average), 0)
        ticks     = $rows.Count
    }
}

# ═══════════════════════════════════════════════
# 启动 JSON 汇总(直接拷贝统计段)
# ═══════════════════════════════════════════════

$startupSummary = @()
foreach ($f in (Get-ChildItem $RunDir -Filter "startup_*.json" -ErrorAction SilentlyContinue)) {
    $j = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $startupSummary += @{
        mode = $j.mode; app = $j.app; n = $j.n
        tVisibleMs = $j.tVisibleMs; tSettledMs = $j.tSettledMs; file = $f.Name
    }
}

# ═══════════════════════════════════════════════
# 输出
# ═══════════════════════════════════════════════

$json = @{
    runDir   = $RunDir
    env      = $env2
    ambient  = $ambient
    scenarios = $scenarioSummary
    startup  = $startupSummary
}
$json | ConvertTo-Json -Depth 6 | Out-File (Join-Path $RunDir "summary.json") -Encoding utf8

# summary.md
$md = New-Object System.Collections.Generic.List[string]
$md.Add("# 性能基准汇总")
$md.Add("")
$md.Add("- 结果目录: $RunDir")
if ($env2) {
    $md.Add("- 环境: $($env2.cpu) / $($env2.ramGB)GB / $($env2.os) / $($env2.gpuAdapters -join '; ')")
    $md.Add("- 版本: Vera $($env2.veraVersion) / Wallpaper Engine $($env2.weVersion) / PotPlayer $($env2.potplayerVersion)")
    $md.Add("- 采集时间: $($env2.capturedAt) / 脚本 $($env2.scriptVersion)")
}
$md.Add("")
if ($ambient) {
    $md.Add("## 环境本底(S0)")
    $md.Add("")
    $md.Add("| 指标 | 值 |")
    $md.Add("|---|---|")
    $md.Add("| 系统 CPU% | $($ambient.sysCpuPct) |")
    $md.Add("| 可用内存 MB | $($ambient.availMB) |")
    $md.Add("")
}
if ($scenarioSummary.Count -gt 0) {
    $md.Add("## 场景汇总(树合计,内存为采样期均值)")
    $md.Add("")
    $md.Add("| 场景 | 侧 | 次数 | 私有内存 MB 中位(min-max) | 工作集 MB 中位(min-max) | CPU% 中位(min-max) | GPU% 中位(min-max) | 峰值私有 MB |")
    $md.Add("|---|---|---|---|---|---|---|---|")
    foreach ($s in $scenarioSummary) {
        if ($s.app -eq "ambient") { continue }
        $md.Add(("| {0} | {1} | {2} | {3} ({4}-{5}) | {6} ({7}-{8}) | {9} ({10}-{11}) | {12} ({13}-{14}) | {15} |" -f `
            $s.scenario, $s.app, $s.n,
            $s.privMB.median, $s.privMB.min, $s.privMB.max,
            $s.wsMB.median, $s.wsMB.min, $s.wsMB.max,
            $s.cpuPct.median, $s.cpuPct.min, $s.cpuPct.max,
            $s.gpuPct.median, $s.gpuPct.min, $s.gpuPct.max,
            $s.peakPrivMB.median))
    }
    $md.Add("")
}
if ($startupSummary.Count -gt 0) {
    $md.Add("## 启动计时(ms)")
    $md.Add("")
    $md.Add("| 模式 | 应用 | 次数 | T_visible 中位(min-max) | T_settled 中位(min-max) |")
    $md.Add("|---|---|---|---|---|")
    foreach ($s in $startupSummary) {
        $vis = if ($s.tVisibleMs -and $s.tVisibleMs.median) { "{0} ({1}-{2})" -f $s.tVisibleMs.median, $s.tVisibleMs.min, $s.tVisibleMs.max } else { "无 UI 窗口" }
        $md.Add(("| {0} | {1} | {2} | {3} | {4} ({5}-{6}) |" -f `
            $s.mode, $s.app, $s.n, $vis,
            $s.tSettledMs.median, $s.tSettledMs.min, $s.tSettledMs.max))
    }
    $md.Add("")
}
$md | Out-File (Join-Path $RunDir "summary.md") -Encoding utf8

Write-Host ""
Write-Host "  [OK] 已生成:" -ForegroundColor Green
Write-Host "    $(Join-Path $RunDir 'summary.md')"
Write-Host "    $(Join-Path $RunDir 'summary.json')"
Write-Host ""
Write-Host "  --- 预览 ---" -ForegroundColor Gray
Get-Content (Join-Path $RunDir "summary.md") | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
