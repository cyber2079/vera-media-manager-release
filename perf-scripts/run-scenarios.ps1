# Vera Media Manager — 性能基准:场景矩阵测量
# 用途:按场景矩阵对 Vera / Wallpaper Engine(+PotPlayer) 两侧做资源占用采样
#
# 用法(npm 快捷方式见 package.json "perf"):
#   npm run perf                                          # 全场景(S0 本底 + S1 静态 + S2 视频壁纸 + S3 合并负载) ×3 次
#   npm run perf -- -Scenarios S2,S3                      # 只跑指定场景
#   powershell -File scripts/perf/run-scenarios.ps1 -Smoke        # 20s 单场景冒烟自检
#   powershell -File scripts/perf/run-scenarios.ps1 -IncludeDisk  # 附带磁盘 IO(默认关)
#
# 半自动协议:每个场景每侧开始前,脚本提示所需应用状态,操作者就绪后回车,
# 之后 稳定期(默认 15s 丢弃) + 采样期(默认 60s @1Hz) × N 次 全自动。
# 结果:scripts/perf/results/run-<时间戳>/ 下逐 tick CSV + env.json + scenario-index.json

param(
    [string]$ConfigPath = "$PSScriptRoot\perf-config.json",
    [string[]]$Scenarios = @("S0", "S1", "S2", "S3"),
    [int]$Runs = 0,
    [int]$DurationSeconds = 0,
    [int]$SettleSeconds = 0,
    [switch]$Smoke = $false,
    [switch]$IncludeDisk = $false,
    # readhost = 提示后回车确认(手动终端,默认);countdown = 提示后倒计时自动继续(适合非交互终端驱动)
    [ValidateSet("readhost", "countdown")]
    [string]$PromptMode = "readhost",
    [int]$CountdownSeconds = 60
)

function Wait-OperatorReady {
    param([string]$Message)
    if ($PromptMode -eq "readhost") {
        Read-Host "  $Message"
    } else {
        Write-Host "  $Message" -ForegroundColor Yellow
        for ($i = $CountdownSeconds; $i -ge 1; $i--) {
            Write-Progress -Activity "等待操作者准备" -Status "$Message ($i s)" -PercentComplete ((($CountdownSeconds - $i) / $CountdownSeconds) * 100)
            Start-Sleep -Seconds 1
        }
        Write-Progress -Activity "等待操作者准备" -Completed
    }
}

$ErrorActionPreference = "Stop"
Import-Module "$PSScriptRoot\perf-common.psm1" -Force

# ═══════════════════════════════════════════════
# 配置与场景定义
# ═══════════════════════════════════════════════

$cfg = Get-PerfConfig -Path $ConfigPath
$defaultRuns = if ($Runs -gt 0) { $Runs } else { [int]$cfg.sampling.runs }
$duration = if ($DurationSeconds -gt 0) { $DurationSeconds } else { [int]$cfg.sampling.durationSeconds }
$settle = if ($SettleSeconds -gt 0) { $SettleSeconds } else { [int]$cfg.sampling.settleSeconds }
$interval = [int]$cfg.sampling.intervalSeconds

if ($Smoke) {
    $Scenarios = @("S2")
    $defaultRuns = 1
    $duration = 20
    $settle = 5
}

$mp4Wall = $cfg.media.wallpaperVideo
$mp4Play = $cfg.media.playbackVideo
$imgStatic = $cfg.media.staticImage

$scenarioDefs = @{
    S1 = @{
        title = "S1 静态壁纸 · 空闲"
        sides = @(
            @{ app = "vera"; state = "启动 Vera,静态壁纸设为 $imgStatic,窗口可见,不做任何交互" }
            @{ app = "we";   state = "启动 WE(自动为其应用静态图 $imgStatic),关闭 WE 浏览器窗口只留引擎常驻"; weWallpaper = $imgStatic }
        )
    }
    S2 = @{
        title = "S2 视频壁纸"
        sides = @(
            @{ app = "vera"; state = "Vera 动态壁纸设为 $mp4Wall,窗口可见,不做任何交互" }
            @{ app = "we";   state = "启动 WE(脚本自动为其应用视频壁纸 $mp4Wall),关闭 WE 浏览器窗口只留引擎常驻"; weWallpaper = $mp4Wall }
        )
    }
    S3 = @{
        title = "S3 合并负载 · 视频壁纸 + 播片(头条场景)"
        sides = @(
            @{ app = "vera"; state = "Vera: 动态壁纸 = $mp4Wall,且用内置播放器循环播放 $mp4Play" }
            @{ app = "westack"; state = "WE(脚本自动应用视频壁纸 $mp4Wall)且 PotPlayer 循环播放 $mp4Play(开启循环,窗口默认大小)"; weWallpaper = $mp4Wall }
        )
    }
}

# ═══════════════════════════════════════════════
# 开始
# ═══════════════════════════════════════════════

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  Vera 性能基准 · 场景测量" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  场景: $($Scenarios -join ', ')  次数: $defaultRuns  采样: ${duration}s @${interval}s  稳定期: ${settle}s(丢弃)" -ForegroundColor Gray
if ($Smoke) { Write-Host "  [冒烟模式] 20s 单场景" -ForegroundColor Yellow }
Write-Host ""

$runDir = New-RunDir
Write-Host "  结果目录: $runDir" -ForegroundColor Gray

# 环境快照
$envSnap = New-EnvSnapshot -Config $cfg
$envSnap | ConvertTo-Json -Depth 4 | Out-File (Join-Path $runDir "env.json") -Encoding utf8
Write-Host "  环境: $($envSnap.cpu) / $($envSnap.ramGB)GB / $($envSnap.os)" -ForegroundColor Gray
Write-Host ""

$index = @()

# ═══════════════════════════════════════════════
# S0 环境本底(两侧均不运行;只记录不扣减)
# ═══════════════════════════════════════════════

if ($Scenarios -contains "S0") {
    Write-Host "--- S0 环境本底(请确认 Vera / WE / PotPlayer 均未运行) ---" -ForegroundColor Cyan
    Wait-OperatorReady "就绪后开始 30s 本底采样"
    $ambCsv = Join-Path $runDir "scenario_S0_ambient_run1.csv"
    $ambLines = New-Object System.Collections.Generic.List[string]
    $ambLines.Add("tick,ts,sysCpuPct,availMB")
    for ($i = 1; $i -le 30; $i++) {
        $c = Get-Counter '\Processor(_Total)\% Processor Time', '\Memory\Available MBytes' -SampleInterval 1 -MaxSamples 1 -ErrorAction SilentlyContinue
        $cpuV = [math]::Round($c.CounterSamples[0].CookedValue, 2)
        $memV = [math]::Round($c.CounterSamples[1].CookedValue, 0)
        $ambLines.Add("$i,$((Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')),$cpuV,$memV")
        Write-Progress -Activity "S0 本底采样" -Status "$i/30" -PercentComplete ($i / 30 * 100)
    }
    Write-Progress -Activity "S0 本底采样" -Completed
    [System.IO.File]::WriteAllLines($ambCsv, $ambLines)
    $index += @{ scenario = "S0"; app = "ambient"; csv = "scenario_S0_ambient_run1.csv" }
    Write-Host "  本底完成: $ambCsv" -ForegroundColor Green
    Write-Host ""
}

# ═══════════════════════════════════════════════
# S1-S3 场景
# ═══════════════════════════════════════════════

foreach ($sid in $Scenarios) {
    if ($sid -eq "S0") { continue }
    $def = $scenarioDefs[$sid]
    if (-not $def) { Write-Host "  [跳过] 未知场景 $sid" -ForegroundColor Yellow; continue }

    foreach ($side in $def.sides) {
        Write-Host "--- $($def.title) | 侧: $($side.app) ---" -ForegroundColor Cyan
        Write-Host "  请将应用置于以下状态:" -ForegroundColor Yellow
        Write-Host "    $($side.state)" -ForegroundColor White

        # 起飞前检查:目标应用树必须活着,否则反复提示(防产生全 0 废数据)
        while ($true) {
            Wait-OperatorReady "就绪后进入 ${settle}s 稳定期"
            if ($side.app -eq "westack") {
                $weAlive = Test-AppTreeAlive -App "we" -Config $cfg
                $potAlive = Test-AppTreeAlive -App "potplayer" -Config $cfg
                if ($weAlive -and $potAlive) { break }
                Write-Host "  [未就绪] 检测不到: $(if (-not $weAlive) {'Wallpaper Engine'})$(if (-not $potAlive) {' PotPlayer'}) — 请确认已启动再回车" -ForegroundColor Red
            } else {
                if (Test-AppTreeAlive -App $side.app -Config $cfg) { break }
                Write-Host "  [未就绪] 检测不到 $($side.app) 的进程 — 请确认应用已启动再回车" -ForegroundColor Red
            }
        }

        # WE 侧壁纸自动化:直接发 -control 命令应用指定壁纸文件
        if ($side.weWallpaper) {
            Write-Host "  正在为 WE 应用壁纸: $($side.weWallpaper)" -ForegroundColor Gray
            & $cfg.we.exe -control openWallpaper -file $side.weWallpaper
            Start-Sleep -Seconds 5
        }

        for ($r = 1; $r -le $defaultRuns; $r++) {
            Write-Host "  [run $r/$defaultRuns] 稳定期 ${settle}s ..." -ForegroundColor Gray
            Start-Sleep -Seconds $settle
            $csvName = "scenario_${sid}_$($side.app)_run$r.csv"
            $csvPath = Join-Path $runDir $csvName
            Write-Host "  [run $r/$defaultRuns] 采样 ${duration}s @${interval}s -> $csvName" -ForegroundColor Gray
            Invoke-TreeSampling -App $side.app -Config $cfg -OutCsv $csvPath -Seconds $duration -Interval $interval -IncludeDisk:$IncludeDisk
            $index += @{ scenario = $sid; app = $side.app; run = $r; csv = $csvName }
            Write-Host "  [run $r/$defaultRuns] 完成" -ForegroundColor Green
        }

        # 侧之间切换时提示操作者停止当前侧应用,避免另一侧测量时残留干扰
        Write-Host "  本侧完成。继续前请关闭本侧相关应用(Vera 或 WE+PotPlayer)" -ForegroundColor Yellow
        Wait-OperatorReady "已关闭后继续"
        Write-Host ""
    }
}

# 索引与收尾
$index | ConvertTo-Json -Depth 4 | Out-File (Join-Path $runDir "scenario-index.json") -Encoding utf8

Write-Host "================================================" -ForegroundColor Green
Write-Host "  [OK] 场景测量完成" -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Green
Write-Host "  结果目录: $runDir" -ForegroundColor Gray
Write-Host "  下一步: powershell -File scripts/perf/summarize.ps1 -RunDir $runDir" -ForegroundColor Gray
Write-Host ""
