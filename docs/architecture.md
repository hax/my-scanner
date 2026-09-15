# my-scanner 架构总览

本文回答四个问题：当前架构长什么样、它为什么长这样（决策史）、
两阶段/单阶段的本质 trade-off（含第三形态设想）、以及多架构并行
演化与 CI 对比的机制。性能数字见 README 基准表与 bench-reports
分支趋势页；实验细节见各专题文档。

## 当前架构：两阶段

```
src ──► 阶段 1 classifyTokenStarts（纯 SIMD，无分支）──► masks[]（每 32B 块一个 u32）
        ws/ident 平面 → ID 连接 → 候选起点位图                + line_breaks[]（换行位图）
        + Unicode whitespace 修正（19 码点）                     + newlines（行数）
        + 逻辑换行（\n、孤立 \r、U+2028/29、CRLF 单计）

masks[] ──► 阶段 2 consume（标量循环 + SIMD 贪心）──► tokens[]
            块内 m &= m-1 迭代候选位
            每个起点：dispatch_table[首字节]（comptime 256 项类别码表）
              → punct_single 快路径（{}();,:~@ 直接构造，零调用）
              → scanIdentifier / scanNumber / scanPunct …（贪心到 token 终点）
            整块被上一 token 覆盖 → 块级 continue
            token 终点即下一次迭代位置（假候选被 pos 越过）
```

关键数据结构：

- `Token { kind, start: u32, end: u32 }`（12B，无行号——行号按需查 LineIndex，
  避免写带宽翻倍）
- `LineIndex { breaks: []u32, prefix: []u32 }`：O(1) `lineAt(offset)`，
  由换行位图 + 块前缀和构成
- 阶段 2 的全部状态（pos/prev）是循环局部变量——扫描函数全是纯函数，
  无隐藏 store/load 链（数据流化改造，+5-9%）

## 热路径向量化手法一览

所有向量化集中在 [src/simd.zig](../src/simd.zig)：用 Zig 的 `@Vector`
表达，由编译器按目标平台自动降到 AVX2 / NEON，不写 intrinsics。
阶段 1 的核心是纯位运算推导候选起点掩码：

```
candidate[i] = !whitespace[i] & !(ident_part[i] & ident_part[i-1])
```

即"非空白，且不是标识符的中间字节"，跨块用 carry 位衔接。字符串/
注释/正则内部的字节同样命中候选（阶段 1 不做范围剔除），由阶段 2
的 pos 跳过兜底（见上图）。多个分类平面可经"矩阵旋转"（`packClasses`）
打包成每字节一个 u8 类别码（`Class`），后续平面继续叠位。

| 环节 | 手法 |
| --- | --- |
| 跳空白 | ~~逐 token 重扫~~ 两阶段：候选位图 + `@ctz` 一步到下一个 token 起点 |
| 标识符 | 范围比较合成 `[A-Za-z0-9_$]` 掩码，`@ctz(~mask)` 直接得到结尾偏移 |
| 字符串 / 模板 | 掩码定位 `引号 \| 反斜杠 \| 换行`，转义对直接跳 2 字节；模板另加 `$`（`${`）|
| 块注释 | `slash_mask & (star_mask << 1)` 一条位逻辑同时探测 32 个位置的 `*/`，跨块用 carry 位衔接 |
| 行数统计 | 阶段 1 的 `@popCount(newline_mask)` 一趟算完 |

数字、正则、punctuator 目前是标量：数字 token 平均只有几字节，
punctuator 是 O(1) 的首字符前缀树，先求正确，等 profile 说话再决定
是否向量化。

## 为什么长这样：决策史（带数字的演进）

| 阶段 | typescript.js | 关键决策 |
| --- | --- | --- |
| 单阶段起步 | 34.6 Mtok/s | 平面合成 + 逐 token 前进 |
| 两阶段分类 | 56.6 | classify pass 产候选位图，阶段 2 ctz 迭代 |
| 块内迭代 + 快路径 | 75.8 | 块内 m&=m-1、ident 标量快路径、关键字两级判别 |
| 数据流化 + 冷路径 | 80.1 | 纯函数扫描、寄存器驻留状态、@branchHint |
| 类别码分发 | 96.5 | 256 项 dispatch 表 + 单字节 punct 零调用快路径 |
| boundary v2 语义 | 84.2 | ID 连接 + Unicode ws/逻辑换行（-13% 换正确性） |
| 整块跳过 | ~82* | 长 token 覆盖的块直接 continue |

（*不同语料差异大：minified 端 ~84-96，注释密集端 ~65-83；
当前对 yuku-main：minified +6~9%，注释密集 -8~-29%）

被数据否决的分支（详见 roadmap 各条目）：阶段融合（-3~12%）、
block_size=16（-9%）、完整四位连接 OP/ESC（-25~30%）、whitespace 查表
（JS 空白连续区间，范围比较已最优）、单字节 punct 批量块（纯块率仅
4-7%）、跳跃驱动分类（零净收益，见专题文档）。

## 两阶段 vs 单阶段：本质 trade-off

**单阶段**（yuku 的形态）：一条直线走到底，每产一个 token 完成
"发现起点 → 扫到终点"。关键特性是**每个字节只被触碰一次**；上下文天然
完整（正则/除号歧义、字符串范围都由位置决定）。代价是每前进一步都要
做决定——minified 代码每 ~7 字节一个 token，逐字节决策成本被放大。

**两阶段**（我们的形态）：先用一趟无分支 SIMD 扫描画"地图"（哪些位置
可能是 token 起点），再按图行军——只在起点降落，token 中间和空白完全
跳过。代价有三：字节读两遍、位图数组的写读、阶段 1 无上下文产生的
假候选（字符串/注释内部字节也是候选，靠阶段 2 的 pos 跳过兜底）。

一句话：**两阶段用"多读一遍 + 一张位图"的固定成本，换"跳过所有
非决策点"的收益；token 越密越划算，token 越稀越亏**。

- minified 端（typescript.js，137 tok/KB）：+6~9%
- 注释密集端（lib.dom.d.ts，62 tok/KB；line-comments.js）：cls 占总时间
  21-31%，而单阶段没有这一趟 → -8~29%

两次试图治"注释密集端"的实验失败于同一根因：

1. **阶段融合**（classify+consume 逐块交织、消灭位图数组）：-3~12%。
   两趟分开时阶段 1 是无依赖的向量流水线、位图驻留 L1；交织后 SIMD
   与标量互相打断。
2. **跳跃前移**（字符串/注释终点判定进阶段 1，见
   [跳跃驱动实验](jump-driven-classify-experiment.md)）：正确性做成
   （7 语料差分全绿），但 line-comments 账本显示 cls +0.27ms / 阶段 2
   -0.27ms——**工作等量搬迁，零净收益**。yuku 跳跃便宜的本质不是
   跳跃在哪个阶段做，而是单阶段字节只触一次。

## 第三形态设想（未实施）

两阶段的真正成本不是"两趟"本身，而是**趟间物化**（全文件 masks 数组）
与**重叠触碰**（跳跃区间被块循环和跳跃函数都摸一遍）。设想：
**单阶段驱动 + 按块候选缓冲**——每个 32 字节块先在寄存器里产出候选
掩码、立即就地消费、然后丢弃，不落盘全文件数组。字节只读一遍
（单阶段的优点），起点跳跃靠 SIMD 位图（两阶段的优点）。这是下一个
架构级候选，需从头设计块间的 carry 与上下文传递。

## 架构矩阵：并行演化机制

历史教训：被局部优化数据否决的方向，可能只是那条线还没优化到位。
为此架构不再"一条主线改到底"，而是**多架构共存于一个代码库，各自
演化、同一 CI 对比**：

- **共享语义层**（`scanner.zig`）：token 语义、数字/标点/正则/关键字/
  Unicode 表、dispatch 表。语义修复单点生效。
- **架构层**（`src/variants/`，每架构一个文件，驱动循环与跳跃策略自治）：

| 实现名 | 架构族 | 驱动 | 跳跃 | 第三方参照 |
| --- | --- | --- | --- | --- |
| `scalar` | 全标量单阶段 | pos 循环 | 纯标量 | yuku-old（0.10.1） |
| `jump_vec` | 单阶段 + SIMD 长跳跃 | pos 循环 | SIMD 原语 | yuku-main；swc/oxc（待接入） |
| `two_phase` | 两阶段 SIMD（主线） | 位图 ctz 迭代 | SIMD 原语 | — |
| （未实施） | 单阶段 + 按块候选缓冲 | 块内产掩码即消费 | SIMD 原语 | — |

规则：任何语义修复/变更必须全变体差分全绿（`scripts/check.sh` 对
每个变体跑 tsc 差分）；各架构独立优化不许互相拉扯；`jump_vec` 是
第三形态的直接前驱（驱动一致，只差块内候选缓冲）。

首批本地基线（M2 / 8 轮快测，几何平均 vs yuku-main，正式数字以
CI 25 轮为准）：scalar 0.59x → jump_vec 0.72x → two_phase 0.82x。
梯度分离了各层的净贡献：跳跃向量化 +22%，两阶段化再 +14%。
cn-dense 上 jump_vec ≈ two_phase——中文密集语料两阶段无优势，
与"token 越稀两阶段越亏"的判断一致。

单阶段变体的行号口径：跳跃区间（字符串/模板/块注释等）产 token 后
补一趟标量逻辑换行计数（与 classify 位图语义逐条对齐：`\n`、孤立
`\r`、CRLF 单计、U+2028/29）。这是单阶段架构为行号付的成本，
计入计时（yuku 在 advance 循环里逐字符判断，殊途同归）。

## CI：每次 push 自动对比 + 趋势

`scripts/ci-bench.sh`（本地同样可跑）四步：

1. `zig build test` 单测；
2. **差分门禁**：3 变体 × 全 corpus 对拍 tsc，任一失败即红；
3. 架构矩阵基准（同进程 7 语料 × {scalar, jump_vec, two_phase,
   yuku-old, yuku-main}，N 轮取最优，正则/模板歧义点按同一决策集
   注入——yuku 走 `reScanAsRegex`/`reScanTemplateContinuation` 对拍）；
4. `scripts/make-report.mjs` 汇总成 `report.md` + `data.json`。

`.github/workflows/bench.yml`：push 到 main 触发，报告贴进 run
summary + artifact，并归档到 **bench-reports 分支**
（`scripts/publish-report.mjs` → `reports/<sha>.{md,json}`，
`scripts/update-index.mjs` 重建 `index.html` 趋势页）。趋势页以
"vs yuku-main 倍数"为主口径——绝对吞吐跨 runner 代际不可比，
同 run 内相对值始终有效，每条架构线一条独立曲线，随提交演化。

## TODO（接入 swc/oxc 的前置条件）

`tools/lexbench-rs` 已能编译计时（oxc 经 `benchmarking` feature 的
`Lexer::new_for_benchmarks`，swc 经 `unstable` Iterator），**但未接入
CI 对比**。根因：公平对比的前提是**歧义点决策可控**——第三方 lexer
必须能像 yuku 那样被指示"此 `/` 按正则重扫"（等价 `reScanAsRegex`
对拍）。实测坑（2026-09，lexbench-rs 0.1）：

- swc 独立 Iterator 内置"表达式位置 `/` 判正则"启发式，minified
  语料误判后吞并大段代码（typescript.js 仅产出 ~13 万 token，应为
  112 万）；词法错误返回 None 直接终止。
- oxc 同样在 `/^#!.*/` 处判正则失败后中途终止（~11% 处，23 个 error）。
- 正则中性化语料（`tools/prepare-lexbench.mjs`，等长替换）只治
  `/` 一症，lib.dom.d.ts 零正则仍提前终止——还有别的歧义/错误路径。

接入路径（择一）：
1. 给两者写决策注入驱动：my-scanner 预扫产出歧义决策集 → 驱动
   lexer 在决策点重扫（swc 需 `state.next_regexp` 类入口，oxc 需
   暴露 re-lex；不排除 fork patch）；
2. 或退一档：只在他们能完整扫完的语料子集上对比，报告标注口径。

在做到歧义点可控之前，swc/oxc 的吞吐数字没有进入矩阵的意义。
