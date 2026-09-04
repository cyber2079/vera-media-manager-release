# scripts/perf — 性能基准测量

官网 /perf 报告页的数据来源。完整方法论、机器准备清单、冷启动跨重启流程、发布决策门规则见
[perf-benchmark.md](perf-benchmark.md)(本目录)与[官网报告页](https://scm-think.cn/perf)。

## 快速开始

```powershell
# 1. 复制配置模板并按本机路径修改(真实 config 不进 git)
Copy-Item scripts/perf/perf-config.example.json scripts/perf/perf-config.json

# 2. 场景测量(半自动:脚本提示应用状态,就绪回车后采样全自动)
powershell -ExecutionPolicy Bypass -File scripts/perf/run-scenarios.ps1

# 3. 启动计时
powershell -ExecutionPolicy Bypass -File scripts/perf/run-startup.ps1 -Mode hot

# 4. 汇总(生成 results/run-*/summary.md + summary.json)
powershell -ExecutionPolicy Bypass -File scripts/perf/summarize.ps1
```

## 文件

| 文件 | 职责 |
|---|---|
| perf-common.psm1 | 公共模块:进程树归属(BFS 父链 + 命令行标记并集)、采样循环、环境快照、统计 |
| run-scenarios.ps1 | 场景矩阵编排(S0 本底 / S1 静态 / S2 视频壁纸 / S3 合并负载) |
| run-startup.ps1 | 冷/热启动计时(冷启动含跨重启状态机) |
| summarize.ps1 | CSV/JSON 原始数据 → summary.md + summary.json |
| perf-config.example.json | 路径配置模板 |

## 冒烟自检

```powershell
powershell -ExecutionPolicy Bypass -File scripts/perf/run-scenarios.ps1 -Smoke   # 20s 单场景
```
