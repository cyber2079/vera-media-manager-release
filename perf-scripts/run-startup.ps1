# Vera Media Manager — 性能基准:冷/热启动计时
# 用途:同一方法测量两侧启动速度,保证公平:
#   T_visible = Start-Process 起,轮询树内任一进程 MainWindowHandle != 0(50ms 间隔)
#               (Vera = 主窗口;WE = wallpaperui 浏览器窗口,无 UI 启动时记 null)
#   T_settled = T_visible 后树合计 CPU 连续 3 个 1s 采样 < 2%(30s 封顶)
#               (捕捉 Vera 前端完整性校验/SQLite/.nvtp 全量解密的初始化尾巴)
#
# 用法(npm 快捷方式见 package.json "perf:startup"):
#   powershell -File scripts/perf/run-startup.ps1 -Mode hot            # 热启动 ×10(默认)
#   powershell -File scripts/perf/run-startup.ps1 -Mode cold           # 冷启动流程(首次:初始化状态并测第 1 次)
#   powershell -File scripts/perf/run-startup.ps1 -Mode cold -ContinueAfterReboot   # 每次重启登录后执行
#   powershell -File scripts/perf/run-startup.ps1 -Mode hot -Smoke     # 冒烟:单次
#
# 冷启动铁则:必须用「重启」推进,不能用「关机+开机」——
# Windows Fast Startup 会让关机变成内核缓存保留的假冷启动。

param(
    [string]$ConfigPath = "$PSScriptRoot\perf-config.json",
    [ValidateSet("hot", "cold")]
    [string]$Mode = "hot",
    [int]$Count = 0,
    [switch]$ContinueAfterReboot = $false,
    [switch]$Smoke = $false
)

$ErrorActionPreference = "Stop"
Import-Module "$PSScriptRoot\perf-common.psm1" -Force

$cfg = Get-PerfConfig -Path $ConfigPath
$appKeys = @("vera", "we")

# ═══════════════════════════════════════════════
# 单次启动测量
# ═══════════════════════════════════════════════

function Start-SteamIfNeeded {
    param([string]$SteamExe)
    if (Get-Process -Name "steam" -ErrorAction SilentlyContinue) { return }
    if ($SteamExe -and (Test-Path $SteamExe)) {
        Write-Host "  启动 steam.exe -silent 并等待 ..." -ForegroundColor Gray
        Start-Process -FilePath $SteamExe -ArgumentList "-silent" | Out-Null
        $deadline = (Get-Date).AddSeconds(45)
        while ((Get-Date) -lt $deadline) {
            if (Get-Process -Name "steam" -ErrorAction SilentlyContinue) { return }
            Start-Sleep -Milliseconds 500
        }
        Write-Host "  [警告] steam.exe 45s 内未就绪,WE 可能无法启动" -ForegroundColor Yellow
    }
}

function Measure-OneStartup {
    param([Parameter(Mandatory=$true)][string]$App, [Parameter(Mandatory=$true)]$Config)

    $def = Get-AppTreeDef -App $App -Config $Config
    $exe = $Config.$App.exe
    $workDir = Split-Path $exe -Parent
    if (-not (Test-Path $exe)) { throw "可执行不存在: $exe" }

    if ($App -eq "we") { Start-SteamIfNeeded -SteamExe $Config.we.steamExe }

    # 确保未运行
    if (Test-AppTreeAlive -App $App -Config $Config) {
        Write-Host "  [$App] 已在运行,先停止" -ForegroundColor Gray
        Stop-AppTree -App $App -Config $Config | Out-Null
        Start-Sleep -Seconds 3
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Start-Process -FilePath $exe -WorkingDirectory $workDir | Out-Null

    # T_visible:树内任一进程出现主窗口
    $tVisibleMs = $null
    $visibleDeadline = 60000
    while ($sw.Elapsed.TotalMilliseconds -lt $visibleDeadline) {
        $tree = @(Resolve-AppTree -TreeDef $def)
        $sawWindow = $false
        foreach ($p in $tree) {
            try {
                $gp = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
                if ($gp -and $gp.MainWindowHandle -ne [IntPtr]::Zero) { $sawWindow = $true; break }
            } catch { }
        }
        if ($sawWindow) { $tVisibleMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 0); break }
        Start-Sleep -Milliseconds 50
    }

    # T_settled:树合计 CPU 连续 3 个 1s 采样 < 2%(T_visible 后 30s 封顶;无窗口则从启动起 60s 封顶)
    $tSettledMs = $null
    $settleBaseMs = if ($tVisibleMs) { $tVisibleMs } else { 0 }
    $settleCapMs = $settleBaseMs + 30000
    $coreCount = [Environment]::ProcessorCount
    $prevCpu = @{}
    $calmStreak = 0
    while ($sw.Elapsed.TotalMilliseconds -lt $settleCapMs) {
        $tree = @(Resolve-AppTree -TreeDef $def)
        $seen = @{}
        foreach ($p in $tree) {
            try {
                $gp = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
                if ($gp) { $seen[[int]$gp.Id] = $gp.TotalProcessorTime.TotalSeconds }
            } catch { }
        }
        $dCpu = [double]0
        $havePrev = $false
        foreach ($k in $seen.Keys) {
            if ($prevCpu.ContainsKey($k)) { $dCpu += ($seen[$k] - $prevCpu[$k]); $havePrev = $true }
        }
        if ($havePrev) {
            $cpuPct = ($dCpu / (1.0 * $coreCount)) * 100
            if ($cpuPct -lt 2) { $calmStreak++ } else { $calmStreak = 0 }
            if ($calmStreak -ge 3) { $tSettledMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 0); break }
        }
        $prevCpu = $seen
        Start-Sleep -Seconds 1
    }
    if (-not $tSettledMs) { $tSettledMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 0) }

    $spawnCount = @((Resolve-AppTree -TreeDef $def)).Count

    return @{
        app          = $App
        tVisibleMs   = $tVisibleMs
        tSettledMs   = $tSettledMs
        sawUi        = ($null -ne $tVisibleMs)
        procCountAtSettle = $spawnCount
        startedAt    = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
    }
}

function Stop-AfterMeasure {
    param([string]$App, $Config)
    Stop-AppTree -App $App -Config $Config | Out-Null
}

# ═══════════════════════════════════════════════
# 热启动
# ═══════════════════════════════════════════════

if ($Mode -eq "hot") {
    $n = if ($Count -gt 0) { $Count } elseif ($Smoke) { 1 } else { 10 }

    Write-Host ""
    Write-Host "================================================" -ForegroundColor Cyan
    Write-Host "  Vera 性能基准 · 热启动 ×$n" -ForegroundColor Cyan
    Write-Host "================================================" -ForegroundColor Cyan
    Write-Host "  前置:安装后至少启动过一次(Defender 首扫完成),测试期间关闭无关大负载程序" -ForegroundColor Gray
    Write-Host ""

    $runDir = New-RunDir
    foreach ($app in $appKeys) {
        $runs = @()
        for ($i = 1; $i -le $n; $i++) {
            Write-Host "  [$app] 第 $i/$n 次 ..." -ForegroundColor Gray
            $r = Measure-OneStartup -App $app -Config $cfg
            $runs += $r
            Write-Host ("    T_visible={0}ms  T_settled={1}ms  进程数={2}" -f $r.tVisibleMs, $r.tSettledMs, $r.procCountAtSettle) -ForegroundColor White
            Stop-AfterMeasure -App $app -Config $cfg
            Start-Sleep -Seconds 5
        }
        $vis = @($runs | Where-Object { $_.sawUi } | ForEach-Object { [double]$_.tVisibleMs })
        $set = @($runs | ForEach-Object { [double]$_.tSettledMs })
        $out = @{
            mode = "hot"
            app = $app
            n = $n
            tVisibleMs = (Get-Stats -Values $vis)
            tSettledMs = (Get-Stats -Values $set)
            runs = $runs
        }
        $out | ConvertTo-Json -Depth 5 | Out-File (Join-Path $runDir "startup_hot_$app.json") -Encoding utf8
        Write-Host "  [$app] 热启动完成 -> startup_hot_$app.json" -ForegroundColor Green
    }
    Write-Host ""
    Write-Host "  [OK] 热启动测量完成: $runDir" -ForegroundColor Green
    exit 0
}

# ═══════════════════════════════════════════════
# 冷启动(跨重启状态机)
# ═══════════════════════════════════════════════

$stateFile = "$PSScriptRoot\results\startup-cold-state.json"
$stateDir = Split-Path $stateFile -Parent
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }

$totalCold = if ($Count -gt 0) { $Count } else { 5 }

if (-not (Test-Path $stateFile)) {
    if (-not $ContinueAfterReboot) {
        # 初始化:本次就是第 1 次冷启动窗口
        $state = @{ remaining = $totalCold; bootIndex = 0; results = @{ vera = @(); we = @() } }
    } else {
        Write-Host "[错误] 状态文件不存在,-ContinueAfterReboot 仅在已初始化的冷启动流程中使用" -ForegroundColor Red
        exit 1
    }
} else {
    $state = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
}

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  Vera 性能基准 · 冷启动(第 $(($totalCold - $state.remaining) + 1)/$totalCold 次开机窗口)" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan

# 开机后稳定期:60s(登录后系统服务/自启动平息)
Write-Host "  开机稳定期 60s(期间请勿操作)..." -ForegroundColor Gray
Start-Sleep -Seconds 60

# 交替顺序:偶数窗口 vera 先测,奇数 we 先测(抵消「窗口内后续启动偏热」的次序偏差)
$order = if ($state.bootIndex % 2 -eq 0) { $appKeys } else { @("we", "vera") }
foreach ($app in $order) {
    Write-Host "  [$app] 冷启动测量 ..." -ForegroundColor Gray
    $r = Measure-OneStartup -App $app -Config $cfg
    Write-Host ("    T_visible={0}ms  T_settled={1}ms" -f $r.tVisibleMs, $r.tSettledMs) -ForegroundColor White
    $state.results.$app += $r
    Stop-AfterMeasure -App $app -Config $cfg
    Start-Sleep -Seconds 5
}

$state.remaining = [int]$state.remaining - 1
$state.bootIndex = [int]$state.bootIndex + 1
$state | ConvertTo-Json -Depth 6 | Out-File $stateFile -Encoding utf8

if ($state.remaining -gt 0) {
    Write-Host ""
    Write-Host "  剩余冷启动窗口: $($state.remaining) 次" -ForegroundColor Yellow
    Write-Host "  确认后将重启电脑;重启登录后运行:" -ForegroundColor Yellow
    Write-Host "    powershell -File scripts/perf/run-startup.ps1 -Mode cold -ContinueAfterReboot" -ForegroundColor White
    $confirm = Read-Host "  现在重启吗?(y=重启 / 其他=稍后手动重启)"
    if ($confirm -eq "y") { Restart-Computer -Force }
    exit 0
}

# 收尾:汇总
$runDir = New-RunDir
foreach ($app in $appKeys) {
    $vis = @($state.results.$app | Where-Object { $_.sawUi } | ForEach-Object { [double]$_.tVisibleMs })
    $set = @($state.results.$app | ForEach-Object { [double]$_.tSettledMs })
    $out = @{
        mode = "cold"
        app = $app
        n = $set.Count
        tVisibleMs = (Get-Stats -Values $vis)
        tSettledMs = (Get-Stats -Values $set)
        runs = $state.results.$app
    }
    $out | ConvertTo-Json -Depth 5 | Out-File (Join-Path $runDir "startup_cold_$app.json") -Encoding utf8
    Write-Host "  [$app] 冷启动完成 -> startup_cold_$app.json" -ForegroundColor Green
}
Remove-Item $stateFile -Force
Write-Host ""
Write-Host "  [OK] 冷启动全部完成: $runDir" -ForegroundColor Green
