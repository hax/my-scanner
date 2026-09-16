# 基准：口径、数字与历史

性能相关的口径定义与历史数字都在本文。当前架构矩阵的基线与 CI 趋势页
机制见 [architecture.md](architecture.md)；本文数字为本地 M2 快照，
最新正式数字以 CI 趋势页（GitHub Pages:
<https://johnhax.net/my-scanner/>，源为 bench-reports 分支）为准。

## 对比口径

[bench.sh](../scripts/bench.sh) 通过
[prepare-baselines.sh](../scripts/prepare-baselines.sh) 把
[yuku](https://github.com/yuku-toolchain/yuku) 两版源码备到
`.bench-deps/`（gitignore）：**yuku-old 钉 v0.10.1 tag**（引入向量化
前，固定不更新）、**yuku-main 跟踪上游 HEAD**（clone 记 sha 标记，
ls-remote 探测到移动才重 clone）。然后同进程、同文件、同计时器跑各实现：
口径对称——产出的 token 都 append 到复用缓冲、读文件与初始化不计入，
N 轮取最优。yuku 纯 scanner 与 tsc 同款把正则/模板续扫推迟给 parser，
bench 里按 yuku parser 的方式调 `reScanAsRegex` /
`reScanTemplateContinuation` 对齐（正则决策与 my-scanner 完全一致，
模板用花括号平衡栈跟踪）。正则起点集合必须含模板 `${}` 内的正则——
模板拆片后它们全在主 lexeme 流，bench 直接过滤 `.regex` 收集
（旧模型模板整体一个 token，曾靠 `regex_starts` 旁路收集，漏收会让
yuku 在 typescript.min.js 24KB 处把 `\s` 当标识符转义报
InvalidUnicodeEscape，锚点整行失真）。

**第三方结果本地缓存**（仅本地迭代用）：yuku/swc/oxc 的计时结果缓存在
`.bench-deps/`，键含基线版本标记、语料 sha256、轮数与编译器版本，任一
变动自动失效；`--refresh-baselines`（zig bench）/`--refresh`（rs 链）
强制重跑。**CI 总是实跑**——runner 代际性能漂移，第三方必须与自家实现
同 run 实测，缓存的绝对值不能跨 run 复用。

已知系统偏差：各实现按固定顺序测量（自家 → yuku-old → yuku-main →
swc → oxc → oxc_bitmap），runner 频率漂移给后测者 ~3% 量级的系统性
劣势（CI 上 yuku_old/yuku_main 恒 ≈0.96-0.98 即由此）；解读第三方
相互差时留意，同族参照口径（位置相邻）受影响最小。

语料分 **real**（真实代码）与 **synthetic**（构造极端样本，microbench
专用）两类，唯一权威存储是 corpus 分支（check.sh/ci-bench.sh 自动
拉取校验）；谱系与 provenance 见 [corpus.md](corpus.md)。报告含
「变体 × 语料」矩阵与 real/synthetic 分组几何平均——不同架构在不同
语料上的胜负一眼可见，且构造数据不稀释真实结论。

## 对 yuku 的对比（本地 M2 快照）

M2 / ReleaseFast / 30 轮取最优。bench 同时驱动 yuku 两版本：引入向量化
前的基线快照（yuku-old）与上游主干 `perf(lexer)` 提交之后（yuku-main）。
采样时段系统负载 ~4.5，绝对值偏低约 10%，同进程比较不受影响。

| 文件 | my-scanner | yuku-old | yuku-main | yuku 向量化收益 | mine/yuku-main |
| --- | --- | --- | --- | --- | --- |
| typescript.js | 84.4 Mtok/s | 79.6 | 82.1 | 1.03x | **1.03x** |
| checker.ts | 78.5 | 76.6 | 76.6 | 1.00x | **1.03x** |
| react.js | 114.1 | 106.3 | 119.7 | 1.13x | 0.95x |
| lib.dom.d.ts | 73.5 | 67.1 | **96.5** | **1.44x** | **0.76x** |

yuku 主干的向量化覆盖四处：`findAnyPos`（@Vector 16/8 字节找命中字符
+ ctz）用于行注释/字符串/模板，块注释则是两段式（标量扫过首行后，
注释主体用 stars/slashes 双 mask 的 @Vector(16) 窗口搜 `*/`，窗口重叠
1 字节防跨窗漏检）。收益随注释/字符串密度变化：块注释密集的
lib.dom.d.ts +44%、react.js +13%，minified 的 typescript.js +3%、
checker.ts 持平。**lib.dom.d.ts 上 yuku-main 反超**——注释密集语料是
当时的明确短板，后续「整块跳过」优化已部分收敛（见 roadmap），剩余
差距的结构性分析见 architecture.md 的「横向权衡」一节。

## 架构矩阵与 CI

项目已转为多架构变体并行演化（scalar / jump_vec / two_phase），每次
push 到 main 由 CI 自动跑全变体差分 + 矩阵基准，报告归档到
bench-reports 分支并累积图表页（`index.html`，GitHub Pages 在线看：
<https://johnhax.net/my-scanner/>）。趋势折线以
「vs baseline 倍数」为主口径——基线（yuku v0.10.1 快照）固定不漂，相对
倍数跨 run、跨 runner 代际均可比（2026-09-16 自 yuku-main 切换，
历史点由 best_ns 全量重算，无断档）；「vs 同族参照」口径（scalar 对
baseline、jump_vec 对 yuku-main、two_phase 对 oxc_bitmap）衡量各族
自身成熟度。首批本地基线梯度与各层净贡献的拆解见
[architecture.md](architecture.md) 的「总览」一节。

## 历史演进（two_phase 主线）

单阶段 0.25-0.59 → 两阶段分类 0.41-1.05 → 块内迭代等微优化
0.55-1.07 → 数据流化 + 冷路径 + 打包 punct 0.59-1.13 → 类别码分发
0.71-1.35 GB/s（带数字的决策表见 architecture.md）。被数据否决的
尝试：阶段融合（-3~12%，两阶段分离的缓存行为更好）与
block_size=16（-9%）。

> 注：更早期 README 曾以「现状」名义给过一张 ~34.6 Mtok/s 的吞吐表，
> 那是单阶段主线的起点快照，已被上表与决策史取代，不要引用。

## 原语级 A/B 计量

bench 的常设输出（`--prim`、`cls-s` 行）用于把 SIMD 收益拆到原语层，
防止「整体 bench 赢/输但不知道赢/输在哪」：

- **分类 pass**：SIMD `classifyTokenStarts` = 标量参考实现
  （`classifyTokenStartsScalar`，经 200 轮随机字节流逐位交叉验证）
  的 **8.8-11.9x**（4.9 vs ~0.45 GB/s）。
- **identPartMask**：**19-24x**（16-17 vs 0.7-0.8 GB/s）；
  **stringStopMask**：**17-21x**（21.6 vs 1.0-1.25）；
  **whitespaceMask**：仅 **2.2x**（28.5 vs 12.9）——后者标量循环被
  LLVM 自动向量化到接近手写 SIMD，前两者的标量版因逐位打包
  （`m |= 1<<j` 的变量移位）阻止 autovectorize。
  教训：**标量基线的写法决定 A/B 的公平性**（详见
  [experiment-methodology.md](experiment-methodology.md)）。

## 瓶颈结论

Mtok/s 几乎恒定而 GB/s 随 token 密度反向变化——瓶颈是每 token 的固定
开销（分发 + emit + append），不是 SIMD 扫描本身。所以 roadmap 的下一
优先级长期是 token 批量产出（SoA 输出、token 簇融合）。

## 附：趋势页断档说明（yuku_old 固定 v0.10.1）

2026-09-16 之前，CI 上的 yuku_old 并非名义的「0.10.1 快照」：CI 每 run
从空 `.bench-deps` 出发，两个 yuku 目录都 fresh clone 上游 HEAD，
yuku_old 实为 yuku-main 的内容副本（差异仅 ~3% 的测量顺序偏差）。
自该日起 yuku_old 钉到 **v0.10.1 tag**（`3846715a`，向量化前，
`prepare-baselines.sh` 固定 clone 该 tag，不再漂移）——趋势页 yuku_old
线与 scalar 的「vs 同族参照」序列在此**断档跳变一次**：此前的值是
scalar 对 main 副本，此后才是真·对 v0.10.1。本地各快照（M2 表等）的
yuku-old 内容经 md5 核对本就是 v0.10.1，本地历史数字同样不受影响。

同日稍后，趋势页锚点自 yuku-main 切换为 **yuku-old（v0.10.1 固定快照）**：
yuku-main 跟踪上游 HEAD、本身会漂，不适合作锚；固定锚点的相对倍数
跨 run、跨 runner 代际均可比。update-index 一律由 data.json 的
best_ns 重算 ratio（弃用旧 vs_anchor 字段），历史点同步换算、口径
统一；唯固定生效前的 yuku_old 实为 main 副本（见上节），各倍数序列
在该日同有一次性语义跳变——与「vs 同族参照」断档同因同日。
GB/s 与「vs 同族参照」口径定义不变。

## 附：趋势页断档说明（swc/oxc 编译特性 + oxc_bitmap 进矩阵）

2026-09-16 起 CI（x86_64）对 lexbench-rs 统一开
`-C target-feature=+avx2,+bmi2`：oxc_bitmap 的 SIMD 核心此前提，
swc/oxc 两列同步受益——此前 Rust 侧按 baseline SSE2 编（zig 侧
native，口径不对称），故 swc/oxc 的绝对值与相对值在此**断档跳变
一次**（方向向上，幅度随语料）。同日起矩阵新增 **oxc_bitmap** 列
（oxc_lexer 多位图流水线实验 crate，two_phase 族第三方参照）：
歧义内部自决 + 全语料 spans 门禁、计时含 value lanes、仅 x86_64
SIMD 形态（其余平台 generic fallback 仅 smoke）——口径注记见
architecture.md 的「oxc_bitmap」一节与 report.md 头部。
