# 基准：口径、数字与历史

性能相关的口径定义与历史数字都在本文。当前架构矩阵的基线与 CI 趋势页
机制见 [architecture.md](architecture.md)；本文数字为本地 M2 快照，
最新正式数字以 CI 趋势页（GitHub Pages:
<https://johnhax.net/my-scanner/>，源为 bench-reports 分支）为准。

## 对比口径

[bench.sh](../scripts/bench.sh) 首次运行会把
[yuku](https://github.com/yuku-toolchain/yuku) 的源码 clone 到
`.bench-deps/`（gitignore），然后同进程、同文件、同计时器跑各实现：
口径对称——产出的 token 都 append 到复用缓冲、读文件与初始化不计入，
N 轮取最优。yuku 纯 scanner 与 tsc 同款把正则/模板续扫推迟给 parser，
bench 里按 yuku parser 的方式调 `reScanAsRegex` /
`reScanTemplateContinuation` 对齐（正则决策与 my-scanner 完全一致，
模板用花括号平衡栈跟踪）。正则起点集合必须含模板 `${}` 内的正则——
my-scanner 的模板整体算一个 token，主 token 流里没有内部正则，bench
用 scanner 的 `regex_starts` 选项旁路收集（曾漏收，yuku 在
typescript.min.js 24KB 处把 `\s` 当标识符转义报 InvalidUnicodeEscape，
锚点整行失真）。

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
bench-reports 分支并累积趋势页（`index.html`，GitHub Pages 在线看：
<https://johnhax.net/my-scanner/>）。趋势页以
「vs yuku-main 倍数」为主口径——绝对吞吐跨 runner 代际不可比，同 run
内相对值始终有效；「vs 同族参照」口径（scalar 对 yuku-old、jump_vec
对 yuku-main）衡量各族自身成熟度。首批本地基线梯度与各层净贡献的拆解见
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
