# Vera Media Manager — 性能基准测量公共模块
# 用途：进程树归属(BFS 父链 + 命令行标记并集)、资源采样循环、环境快照、统计工具
#       供 run-scenarios.ps1 / run-startup.ps1 / summarize.ps1 共用
#
# 设计要点(方法论与官网 /perf 页披露一致,改动须同步文档):
#   - 内存主口径 = 树内 PrivateMemorySize64 求和(私有提交字节);
#     副口径 WorkingSet64 同记(WorkingSet 求和会重复计 WebView2 共享页,对多进程架构不公平)
#   - CPU% = ΔTotalProcessorTime / (Δt × 逻辑处理器数) × 100,与任务管理器归一化一致
#   - GPU% = CIM Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine,
#     实例名 pid_(\d+)_ 提 pid,树内全部引擎类型利用率求和(类名不本地化,任何语言系统可用)
#   - 每 tick 用候选名过滤的 CIM 单查询重建进程树(子进程动态生灭,ppid 会复用,不能缓存)
#   - 采样自身开销控制:CIM 查询限定候选进程名,避免全表枚举污染数据

Set-StrictMode -Version 2.0

$script:PerfScriptVersion = "1.0.0-20260904"

# ═══════════════════════════════════════════════
# 配置
# ═══════════════════════════════════════════════

function Get-PerfConfig {
    param([string]$Path = "$PSScriptRoot\perf-config.json")
    if (-not (Test-Path $Path)) {
        throw "配置不存在: $Path (先复制 perf-config.example.json 为 perf-config.json 并按本机路径修改)"
    }
    $cfg = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    return $cfg
}

# 应用树定义:候选进程名 / 根进程名 / 命令行包含标记 / 命令行排除标记
# Vera:  WebView2 子进程按 user-data-dir 路径段 com.scm-think.vera-mm 归属(多窗口天然覆盖,排除他应用 WebView2)
# WE:    v2.8 结构根在 distribution\wallpaper64.exe;UI 为内嵌 Chromium(wallpaperui.exe 子进程);
#        Web 壁纸走 Edge WebView2(edgewallpaper64.exe),按 wallpaper_engine 路径标记归属
# PotPlayer: 单进程
function Get-AppTreeDef {
    param([Parameter(Mandatory=$true)][string]$App, [Parameter(Mandatory=$true)]$Config)

    switch ($App) {
        "vera" {
            return @{
                Label       = "vera"
                RootName    = "vera-media-manager.exe"
                RootPathHint= $Config.vera.exe
                Names       = @("vera-media-manager.exe", "msedgewebview2.exe")
                IncludeMarker = "com.scm-think.vera-mm"
                ExcludeMarker = $null
            }
        }
        "we" {
            # Steam 启动的引擎在安装根目录,直启/distribution 副本在 distribution\ ——按安装目录匹配两处都覆盖
            return @{
                Label       = "we"
                RootName    = "wallpaper64.exe"
                RootPathHint= (Split-Path $Config.we.exe)
                Names       = @("wallpaper64.exe", "wallpaper32.exe", "wallpaperui.exe",
                                "wallpaperservice64.exe", "edgewallpaper64.exe", "msedgewebview2.exe")
                IncludeMarker = "wallpaper_engine"
                ExcludeMarker = "com.scm-think.vera-mm"
            }
        }
        "potplayer" {
            return @{
                Label       = "potplayer"
                RootName    = @("PotPlayerMini64.exe")
                RootPathHint= $Config.potplayer.exe
                Names       = @("PotPlayerMini64.exe", "PotPlayerMini.exe", "PotPlayer64.exe")
                IncludeMarker = $null
                ExcludeMarker = $null
            }
        }
        "westack" {
            # S3 对照组栈:WE + PotPlayer 合并为一个树整体采样
            return @{
                Label       = "westack"
                RootName    = @("wallpaper64.exe", "PotPlayerMini64.exe")
                RootPathHint= $null
                Names       = @("wallpaper64.exe", "wallpaper32.exe", "wallpaperui.exe",
                                "wallpaperservice64.exe", "edgewallpaper64.exe", "msedgewebview2.exe",
                                "PotPlayerMini64.exe", "PotPlayerMini.exe", "PotPlayer64.exe")
                IncludeMarker = $null
                ExcludeMarker = "com.scm-think.vera-mm"
            }
        }
        default { throw "未知应用: $App (vera/we/potplayer/westack)" }
    }
}

# ═══════════════════════════════════════════════
# 进程树归属
# ═══════════════════════════════════════════════

# 单 tick 解析进程树,返回 CIM 进程对象数组(已归属)
# 归属 = 从根进程 BFS 父链命中的候选 ∪ 命令行含 IncludeMarker 的候选 − 命令行含 ExcludeMarker 的候选
function Resolve-AppTree {
    param([Parameter(Mandatory=$true)]$TreeDef)

    $nameFilter = ($TreeDef.Names | ForEach-Object { "Name='$_'" }) -join " OR "
    $cands = @(Get-CimInstance Win32_Process -Filter $nameFilter -ErrorAction SilentlyContinue)
    if ($cands.Count -eq 0) { return @() }

    # 1. 定位根:进程名(数组,多根栈支持) + 可执行路径提示(防同名误捕;路径提示为空则退化为仅按名)
    #    提示路径统一归一为反斜杠再比较(config 用正斜杠,Win32_Process ExecutablePath 是反斜杠)
    $rootNames = @($TreeDef.RootName)
    $hint = $null
    if ($TreeDef.RootPathHint) { $hint = ($TreeDef.RootPathHint -replace '/', '\') }
    $roots = @($cands | Where-Object {
        $rootNames -contains $_.Name -and
        (-not $hint -or -not $_.ExecutablePath -or ($_.ExecutablePath -like "*$hint*"))
    })
    if ($roots.Count -eq 0) { return @() }

    # 2. BFS 父链
    $byParent = @{}
    foreach ($p in $cands) {
        $pp = [uint32]$p.ParentProcessId
        if (-not $byParent.ContainsKey($pp)) { $byParent[$pp] = @() }
        $byParent[$pp] += $p
    }
    $hit = @{}
    $queue = New-Object System.Collections.Queue
    foreach ($r in $roots) { $queue.Enqueue($r); $hit[[uint32]$r.ProcessId] = $true }
    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        $cpid = [uint32]$cur.ProcessId
        if ($byParent.ContainsKey($cpid)) {
            foreach ($child in $byParent[$cpid]) {
                if (-not $hit.ContainsKey([uint32]$child.ProcessId)) {
                    $hit[[uint32]$child.ProcessId] = $true
                    $queue.Enqueue($child)
                }
            }
        }
    }

    # 3. 标记并集(链断裂兜底) + 排除标记
    $result = @($cands | Where-Object {
        $inTree = $hit.ContainsKey([uint32]$_.ProcessId)
        $inMarker = $false
        if ($TreeDef.IncludeMarker -and $_.CommandLine -and $_.CommandLine -like "*$($TreeDef.IncludeMarker)*") { $inMarker = $true }
        $excluded = $false
        if ($TreeDef.ExcludeMarker -and $_.CommandLine -and $_.CommandLine -like "*$($TreeDef.ExcludeMarker)*") { $excluded = $true }
        (-not $excluded) -and ($inTree -or $inMarker)
    })
    return $result
}

# 树内是否还有存活进程(用于停止确认)
function Test-AppTreeAlive {
    param([Parameter(Mandatory=$true)][string]$App, [Parameter(Mandatory=$true)]$Config)
    $def = Get-AppTreeDef -App $App -Config $Config
    return @((Resolve-AppTree -TreeDef $def)).Count -gt 0
}

# 停止整棵进程树(逐 pid Stop-Process;不用 taskkill /im 全局按名杀,防误杀他应用同名进程)
function Stop-AppTree {
    param([Parameter(Mandatory=$true)][string]$App, [Parameter(Mandatory=$true)]$Config,
          [int]$WaitSeconds = 10)
    $def = Get-AppTreeDef -App $App -Config $Config
    $procs = @(Resolve-AppTree -TreeDef $def)
    if ($procs.Count -eq 0) { return $true }
    foreach ($p in $procs) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-AppTreeAlive -App $App -Config $Config)) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return (-not (Test-AppTreeAlive -App $App -Config $Config))
}

# ═══════════════════════════════════════════════
# 资源采样
# ═══════════════════════════════════════════════

# GPU 引擎利用率:返回 hashtable pid -> 利用率合计(全部引擎类型求和)
# CIM 格式化类实例标识在 Name 属性(pid_<pid>_luid_..._engtype_3D),值在 UtilizationPercentage
function Get-TreeGpuUsage {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][int[]]$Pids)

    if ($Pids.Count -eq 0) { return @{} }
    $pidSet = @{}
    foreach ($p in $Pids) { $pidSet[[int]$p] = $true }

    $engines = @(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction SilentlyContinue)
    if ($engines.Count -eq 0) { return @{} }

    $acc = @{}
    foreach ($e in $engines) {
        if ($e.Name -match 'pid_(\d+)_') {
            $p = [int]$Matches[1]
            if ($pidSet.ContainsKey($p)) {
                if (-not $acc.ContainsKey($p)) { $acc[$p] = [double]0 }
                $acc[$p] += [double]$e.UtilizationPercentage
            }
        }
    }
    return $acc
}

# 交叉验证通道:Get-Counter 方式(GPU Engine 计数器,用于与 CIM 主通道比对)
function Get-TreeGpuUsageByCounter {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][int[]]$Pids)
    $samples = Get-Counter '\GPU Engine(*)\Utilization Percentage' -SampleInterval 1 -MaxSamples 1 -ErrorAction SilentlyContinue
    if (-not $samples) { return @{} }
    $pidSet = @{}
    foreach ($p in $Pids) { $pidSet[[int]$p] = $true }
    $acc = @{}
    foreach ($s in $samples.CounterSamples) {
        if ($s.InstanceName -match 'pid_(\d+)') {
            $p = [int]$Matches[1]
            if ($pidSet.ContainsKey($p)) {
                if (-not $acc.ContainsKey($p)) { $acc[$p] = [double]0 }
                $acc[$p] += [double]$s.CookedValue
            }
        }
    }
    return $acc
}

# 采样循环:Seconds 秒 @Interval 间隔,逐 tick 写 CSV
# CSV 列: tick,ts,pid,name,wsMB,privMB,cpuPct,gpuPct
# 每 tick 额外写一行树合计(pid=0,name=__TOTAL__)
# prevCpu: hashtable pid -> @{t=时间戳; cpu=TotalProcessorTime 秒}(跨 tick 差分,函数内维护)
function Invoke-TreeSampling {
    param(
        [Parameter(Mandatory=$true)][string]$App,
        [Parameter(Mandatory=$true)]$Config,
        [Parameter(Mandatory=$true)][string]$OutCsv,
        [int]$Seconds = 60,
        [int]$Interval = 1,
        [switch]$IncludeDisk
    )

    $def = Get-AppTreeDef -App $App -Config $Config
    $coreCount = [Environment]::ProcessorCount
    $prevCpu = @{}   # pid -> @{ t=采样秒; cpu=累计 CPU 秒 }

    $dir = Split-Path $OutCsv -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $header = "tick,ts,pid,name,wsMB,privMB,cpuPct,gpuPct"
    if ($IncludeDisk) { $header += ",readMB,wroteMB" }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($header)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $tick = 0

    while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
        $tickStart = $sw.Elapsed.TotalSeconds
        $tick++

        $tree = @(Resolve-AppTree -TreeDef $def)
        $pids = @($tree | ForEach-Object { [int]$_.ProcessId })
        $gpu = Get-TreeGpuUsage -Pids $pids

        # Get-Process 取内存/CPU 时间(小集合,开销低)
        $gprocs = @{}
        if ($pids.Count -gt 0) {
            foreach ($gp in (Get-Process -Id $pids -ErrorAction SilentlyContinue)) { $gprocs[[int]$gp.Id] = $gp }
        }

        $now = $sw.Elapsed.TotalSeconds
        $ts = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fff")
        $totWs = [double]0; $totPriv = [double]0; $totCpu = [double]0; $totGpu = [double]0
        $totRead = [double]0; $totWrote = [double]0

        foreach ($p in $tree) {
            $procId = [int]$p.ProcessId
            $wsMB = [double]0; $privMB = [double]0; $cpuPct = [double]0
            $readMB = [double]0; $wroteMB = [double]0

            if ($gprocs.ContainsKey($procId)) {
                $gp = $gprocs[$procId]
                try {
                    $wsMB = [math]::Round($gp.WorkingSet64 / 1MB, 1)
                    $privMB = [math]::Round($gp.PrivateMemorySize64 / 1MB, 1)
                    $cpuSec = $gp.TotalProcessorTime.TotalSeconds
                    if ($prevCpu.ContainsKey($procId)) {
                        $dCpu = $cpuSec - $prevCpu[$procId].cpu
                        $dT = $now - $prevCpu[$procId].t
                        if ($dT -gt 0.05) { $cpuPct = [math]::Round(($dCpu / ($dT * $coreCount)) * 100, 2) }
                    }
                    $prevCpu[$procId] = @{ t = $now; cpu = $cpuSec }
                } catch { $wsMB = [double]0; $privMB = [double]0 }
                if ($IncludeDisk) {
                    try {
                        $readMB = [math]::Round(([uint64]$p.ReadTransferCount) / 1MB, 1)
                        $wroteMB = [math]::Round(([uint64]$p.WriteTransferCount) / 1MB, 1)
                    } catch { $readMB = [double]0; $wroteMB = [double]0 }
                }
            }

            $gpuPct = [double]0
            if ($gpu.ContainsKey($procId)) { $gpuPct = [math]::Round($gpu[$procId], 2) }

            $totWs += $wsMB; $totPriv += $privMB; $totCpu += $cpuPct; $totGpu += $gpuPct
            $totRead += $readMB; $totWrote += $wroteMB

            $row = "$tick,$ts,$procId,$($p.Name),$wsMB,$privMB,$cpuPct,$gpuPct"
            if ($IncludeDisk) { $row += ",$readMB,$wroteMB" }
            $lines.Add($row)
        }

        $totRow = "$tick,$ts,0,__TOTAL__," + [math]::Round($totWs,1) + "," + [math]::Round($totPriv,1) + "," + [math]::Round($totCpu,2) + "," + [math]::Round($totGpu,2)
        if ($IncludeDisk) { $totRow += "," + [math]::Round($totRead,1) + "," + [math]::Round($totWrote,1) }
        $lines.Add($totRow)

        # 保节奏:按已耗时间扣减睡眠,防止 tick 漂移
        $elapsedThisTick = $sw.Elapsed.TotalSeconds - $tickStart
        $sleepMs = [int](($Interval - $elapsedThisTick) * 1000)
        if ($sleepMs -gt 20) { Start-Sleep -Milliseconds $sleepMs }
    }

    [System.IO.File]::WriteAllLines($OutCsv, $lines)
    return $OutCsv
}

# ═══════════════════════════════════════════════
# 环境快照
# ═══════════════════════════════════════════════

function Get-FileVersionString {
    param([string]$Path)
    if ($Path -and (Test-Path $Path)) {
        $vi = (Get-Item $Path).VersionInfo
        $v = $vi.ProductVersion
        if (-not $v -or $v.Trim() -eq "") { $v = $vi.FileVersion }
        return $v
    }
    return $null
}

function New-EnvSnapshot {
    param([Parameter(Mandatory=$true)]$Config)

    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $gpus = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name })
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $mainGpu = $gpus | Where-Object { $_.Name -notmatch 'Virtual|Basic Display' } | Select-Object -First 1

    $env = [ordered]@{
        capturedAt    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        scriptVersion = $script:PerfScriptVersion
        cpu           = $cpu.Name.Trim()
        cores         = [int]$cpu.NumberOfLogicalProcessors
        ramGB         = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        os            = "$($os.Caption) build $($os.BuildNumber)"
        display       = "$($mainGpu.CurrentHorizontalResolution)x$($mainGpu.CurrentVerticalResolution)"
        gpuAdapters   = @($gpus | ForEach-Object { "$($_.Name) (driver $($_.DriverVersion))" })
        powerScheme   = (powercfg /getactivescheme) -join " "
        veraVersion   = $(if (Get-FileVersionString $Config.vera.exe) { Get-FileVersionString $Config.vera.exe } else { $Config.vera.version })
        weVersion     = $(if (Get-FileVersionString ($Config.we.exe -replace 'wallpaper64\.exe$', 'launcher.exe')) { Get-FileVersionString ($Config.we.exe -replace 'wallpaper64\.exe$', 'launcher.exe') } else { $Config.we.version })
        potplayerVersion = $(if (Get-FileVersionString $Config.potplayer.exe) { Get-FileVersionString $Config.potplayer.exe } else { "installed" })
        noted         = @()
    }
    if (Get-Process -Name 'steam' -ErrorAction SilentlyContinue) { $env.noted += "steam.exe resident during test" }
    if (Get-Process -Name 'Steam++' -ErrorAction SilentlyContinue) { $env.noted += "Steam++(Watt Toolkit) resident during test" }
    return $env
}

# ═══════════════════════════════════════════════
# 统计工具
# ═══════════════════════════════════════════════

function Get-Median {
    param([Parameter(Mandatory=$true)][double[]]$Values)
    $sorted = @($Values | Sort-Object)
    $n = $sorted.Count
    if ($n -eq 0) { return 0 }
    if ($n % 2 -eq 1) { return [double]$sorted[[int](($n - 1) / 2)] }
    return ([double]$sorted[[int]($n / 2 - 1)] + [double]$sorted[[int]($n / 2)]) / 2.0
}

function Get-Stats {
    param([Parameter(Mandatory=$true)][double[]]$Values)
    if ($Values.Count -eq 0) { return @{ median = 0; min = 0; max = 0; mean = 0 } }
    $mean = ($Values | Measure-Object -Average).Average
    return @{
        median = Get-Median -Values $Values
        min    = ($Values | Measure-Object -Minimum).Minimum
        max    = ($Values | Measure-Object -Maximum).Maximum
        mean   = [math]::Round($mean, 2)
    }
}

# ═══════════════════════════════════════════════
# 结果目录
# ═══════════════════════════════════════════════

function New-RunDir {
    param([string]$Base = "$PSScriptRoot\results")
    if (-not (Test-Path $Base)) { New-Item -ItemType Directory -Path $Base -Force | Out-Null }
    $dir = Join-Path $Base ("run-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

Export-ModuleMember -Function `
    Get-PerfConfig, Get-AppTreeDef, Resolve-AppTree, Test-AppTreeAlive, Stop-AppTree,
    Get-TreeGpuUsage, Get-TreeGpuUsageByCounter, Invoke-TreeSampling,
    Get-FileVersionString, New-EnvSnapshot,
    Get-Median, Get-Stats, New-RunDir
