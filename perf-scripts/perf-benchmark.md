# 性能基准测量手册（perf benchmark）

> 官网 [/perf 报告页](https://scm-think.cn/perf) 的数据来源与复现方法。脚本位于 `scripts/perf/`（同步副本在 release 公开仓 `perf-scripts/`）。
> 首次制定：2026-09-04。改动口径须同步更新本页与官网方法论区。

## 目的与范围

对 Vera Media Manager 与 Wallpaper Engine(+PotPlayer) 做**同机同方法**的资源占用与启动速度实测：

- 资源占用：内存（私有提交字节为主口径 / 工作集为副口径）、CPU%、GPU%（引擎利用率合计）、磁盘 IO（可选）
- 响应速度：热启动 / 冷启动（T_visible 窗口出现 + T_settled CPU 平息）

**品类口径声明**：Vera 的动态壁纸渲染在应用窗口内（WebView 背景层），Wallpaper Engine 渲染在真实桌面。两者不是同品类软件，对比框架是「桌面娱乐中心」——达成同样的「动态壁纸 + 看片/听歌」体验，Vera 单进程树 vs WE + 播放器多进程常驻合计。**不以「桌面壁纸软件」框架对比，不碰价格维度**（Vera 动态壁纸是订阅制会员功能，WE ¥22.9 买断）。

## 测量口径（脚本已固化，勿手工改数）

| 项 | 口径 | 理由 |
|---|---|---|
| 进程树归属 | BFS 父链 + 命令行标记并集 | Vera：`com.scm-think.vera-mm`（WebView2 user-data-dir 路径段）；WE：`wallpaper_engine` 路径标记 + 多根（wallpaper64 + 其 UI/服务/WebView2 子进程）。两软件同时存在 msedgewebview2.exe 时靠各自标记互斥 |
| 内存主口径 | 树内 PrivateMemorySize64 求和 | WorkingSet 求和会重复计多进程共享页（DLL/纹理），对进程数不同的架构不公平；私有字节 = 真实 RAM/页面文件压力，最接近任务管理器默认列 |
| 内存副口径 | 树内 WorkingSet64 求和 | 同记同发布 |
| CPU% | ΔTotalProcessorTime / (Δt × 逻辑核数) × 100 | 与任务管理器归一化一致 |
| GPU% | CIM `Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine`，Name 属性提 pid，全部引擎类型利用率求和 | WMI 类名不本地化（任何语言系统可用）；按 pid 过滤规避虚拟显卡（MuMu 等）串扰；Get-Counter 作交叉验证通道 |
| 不计入 | steam.exe（Steam 客户端本就常驻，对 WE 从宽）、configurator | 方法论披露 |
| 采样参数 | 每场景：稳定 15s（丢弃）→ 60s @1Hz → ×3 取中位数（附 min-max） | 结果目录 CSV 可溯源 |
| 环境本底 | 每轮先测 30s 系统 CPU/可用内存，只披露不扣减 | — |

### 场景矩阵

| ID | 场景 | Vera 侧 | 对照侧 |
|---|---|---|---|
| S0 | 环境本底 | 两侧均不运行 | — |
| S1 | 静态壁纸空闲 | 默认静态壁纸，窗口可见无交互 | WE + 同一张静态图，只留引擎 |
| S2 | 视频壁纸 | 动态壁纸 = city-drive-sunset.mp4 | WE 加载同一 mp4 |
| S3 | **合并负载（头条）** | S2 + 内置播放器循环播 the-ride.mp4 | WE + PotPlayer 循环播同一文件 |
| S4 | 音乐播放（可选） | 音频 + 频谱可视化 | WE + PotPlayer 纯音频 |

### 启动协议

- 同一方法测两侧：T_visible = 树内任一进程 MainWindowHandle ≠ 0（50ms 轮询）；T_settled = T_visible 后树合计 CPU 连续 3 个 1s 采样 < 2%（30s 封顶）
- 热启动：杀树 → 清零确认 → 5s → 重启，×10 取中位数
- 冷启动：**必须「重启」不是「关机+开机」**（Windows Fast Startup 会让关机变成假冷启）。跨重启状态机：`results/startup-cold-state.json` 记剩余次数，每次开机登录后 `run-startup.ps1 -Mode cold -ContinueAfterReboot`，×5；两侧测量顺序逐次交替
- 防干扰清单：双方自启动关、电源计划固定、Steam 静默常驻、安装后先启动一次让 Defender 完成首扫、测试期间关闭浏览器等大负载

## 机器准备清单（Phase 0 复刻）

1. Steam 安装 Wallpaper Engine（正版）；完成首启欢迎流程（欢迎对话框卡着时 `-control` 不生效）
2. 安装 PotPlayer（`winget install Daum.PotPlayer`）
3. 从 GitHub Release / 官网下载安装 Vera 发行版（基准用公开发行版，不用开发构建——发行版含前端完整性校验与 .nvtp 全量解密，是真实用户路径）
4. Vera 完成引导 + 激活会员（动态壁纸是会员功能）+ 配置动态壁纸与内置播放器
5. 测试媒体：`public/videos/car-bg/`（city-drive-sunset.mp4 / the-ride.mp4）+ 静态图；两软件用**同一文件**
6. `Copy-Item scripts/perf/perf-config.example.json scripts/perf/perf-config.json` 按本机路径修改

## 执行

```powershell
npm run perf                     # 场景矩阵(半自动:提示应用状态,就绪回车)
npm run perf:startup             # 热启动 ×10(默认)
# 冷启动见「启动协议」
npm run perf:summary             # 汇总 summary.md/json
```

## 审计清单（过不了不发）

1. 归属 sanity：脚本树进程清单 vs 任务管理器手动对数
2. GPU 双通道交叉验证（CIM vs Get-Counter），偏差 > ±20% 查因
3. 任一 run 间 CV > 20% 追加 2 次
4. 页面每个数字可溯源到 CSV + 日期 + 软件版本

## 发布决策门（先测后发）

- **/perf 页 = 全量披露**：相关场景占优与劣势指标同表列出，指标级挑拣禁止；只允许场景级省略（如冷启动、S4），且方法论必须列「已测场景全集」+ 原始数据链接（冻结快照 `docs/development/perf-results/<日期>/` + release 仓）
- **首页卡片 = 精选子集**：仅放占优或打平（±10% 内标「相当」）指标，必须链接 /perf 全量报告
- **熔断线**：S3 合并负载 Vera 不占优 → 竞品对比叙事整体不上线，只留功能广度叙事
- WE 占优的指标按「如实展示博可信 or 场景级省略」规则处理，绝不修饰数据

## 结果归档

- 原始数据：`scripts/perf/results/run-<时间戳>/`（不进 Git）
- 冻结快照：`docs/development/perf-results/<测试日期>/`（summary.md + env.json + 全部 CSV，进 Git，兜底公开）
- 页面数字从 summary 人工誊抄排版；每次重测新建快照目录，不覆盖旧数据
