# 实验：oxc_lexer 位图流水线移植到 Zig + NEON

状态：**第二轮完成**（2026-09-17；第一轮同日，口径已被 §10.1 修正）
分支：`exp/oxc-bitmap-neon`（起点 58d3e3c）
目标：**在 Apple Silicon（NEON）上达到 oxc_lexer（x86_64 AVX2+BMI2）相同的速度**。

**结论速览**：新变体 `bitmap`（`src/variants/bitmap.zig`，oxc 六趟位图
流水线 × my-scanner 语义层）check.sh 44/44 全绿（4 变体 × 11 语料
差分）；vs 本机 jump_vec 6 胜 5 负——胜负倾向与 oxc_bitmap 一致，
幅度普遍缩水。
名词：oxc_lexer 是 oxc 主仓孵化的位图流水线实验 crate（bench 矩阵列
名 oxc_bitmap，口径见 architecture.md「oxc_bitmap」节）；jump_vec 是
本仓库现有最快的单阶段 SIMD 变体；scalar 是标量基线。「架构性格」
指语料谱系上的胜负倾向。

**第二轮口径纠正（2026-09-17 晚，详见 §10）**：第一轮的「M3 vs CI
EPYC 绝对值对照」属跨机绝对值比较，不能作主要结论；「LUT 在
Zig+NEON 不可用」已被推翻——inline asm `%[name]` 可封装 vqtbl
（§10.2）。交付物对齐的对比已改走 oxc_lexer aarch64 后端
（§10.3-§10.5），**当前结论以 §10.6 为准**。

## 0. 问题定义

CI（EPYC x86_64，AVX2+BMI2）上 oxc_bitmap（oxc_lexer 六趟位图流水线）与
自家 jump_vec 的吞吐差距（2026-09-16 报告，GB/s）：

| 语料 | jump_vec | oxc_bitmap | bm/jv |
| --- | --- | --- | --- |
| typescript.js | 0.416 | 0.681 | 1.64 |
| typescript.min.js | 0.199 | 0.564 | 2.84 |
| checker.ts | 0.484 | 0.846 | 1.75 |
| lib.dom.d.ts | 1.039 | 1.036 | 1.00 |
| react.js | 0.693 | 1.068 | 1.54 |
| react.min.js | 0.226 | 0.761 | 3.37 |
| hanzi-chai.ts | 0.230 | 0.187 | 0.81 |
| mon-entreprise.ts | 0.495 | 0.679 | 1.37 |
| line-comments.js | 1.448 | 0.951 | 0.66 |
| strings.js | 0.547 | 0.683 | 1.25 |
| cn-dense.ts | 0.594 | 0.284 | 0.48 |

高 token 密度（minified）语料差距最大（2.8-3.4x）——per-token 固定成本
占主导时，oxc 的批量流水线碾压逐 token 主循环；低 token 密度（注释/中文）
语料 jump_vec 反超——跳跃主导时单阶段更便宜。

本机（M3 Pro）oxc_bitmap 只有 generic fallback（SIMD 核心仅 x86_64），
整体慢于 jump_vec。**它的速度完全来自没被移植到 arm64 的 SIMD 核心**。

## 1. oxc_lexer 为什么快（源码研究结论）

六趟 unfused 流水线（`pipeline/mod.rs:179-206`）：

```
classify → misc_pre → carve → coalesce → misc_post → compress
```

1. **classify（纯 SIMD，速度本源）**：每字节查一次分类（4×16B LUT +
   `pshufb` 伪完美哈希，`classify/avx2.rs`），一次产出 7 张每 64B 块的
   u64 位图（word/st/kwinit/opch/digit/dot/misc）+ 每字节 kind 数组
   （`kind[i]` = 「若 i 是 token start，它的 kind」）。语义：
   `st = ws_run首 | word_run首 | 其他全部字节`。
2. **carve**：SIMD `find_opener` 找 `" ' \` / < > { }`，只在 opener 处
   顺序处理字符串/模板/注释/正则，`bm_clear_range` 把字面量内部从 st
   清掉。ident/数字/标点完全不逐 token 处理。
3. **coalesce**：位并行算多字符操作符 run 起点 + keyword 候选（`kwc`），
   ctz 迭代处理事件：op2/op3 完美哈希合并 `===` 等、munch_walk 吃长
   opch run、数字粘合。
4. **compress**：st 位图批量压成 SoA（pos:u32[]/kind:u8[]）——每 16 位
   用 LUT（`pair_luts`）+ `pshufb` 一次抽 8 个位置，**不用 pext**。
   build_spans 相邻 pos 配对 + trivia 过滤（QCOMPACT/BCOMPACT LUT）。
5. **每 token 的路径极轻**：普通 token 从「主循环 dispatch + emit +
   append」变成「位图上的一位 + compress 批量搬运」。minified 语料
   （token 密度 ~350 tok/KB）收益最大。

关键工程事实：

- **AVX2 代码无 pext 依赖**（grep 全源码仅 `_bzhi_u64` 一处，trivial 可替）——
  compress 用 LUT+shuffle 而非位压缩，NEON `vqtbl` 可 1:1 等价。BMI2
  不是 NEON 硬伤。
- `movemask` 是唯一的真缺口：AVX2 1 条指令/32B，NEON 需合成（约 5-6 条
  /16B，或 SWAR 乘法 + GPR 搬运）。classify 每 64B 要 14 次 movemask，
  这是 NEON 版最大的结构性成本。
- 值 lanes（字符串 cooked、数字 f64、atoms）在 carve/compress 内生，
  计时含这部分工作（my-scanner 口径不需要，移植时不做——口径差见 §5）。

## 2. 移植策略：oxc 架构 × my-scanner 语义

新变体 `bitmap`（`src/variants/bitmap.zig`）。**架构**复刻 oxc 六趟流水线；
**语义**（token 切分口径）复用 my-scanner 已过 tsc 差分的语义层，这样：

- check.sh 门禁直接可用（变体 vs tsc 差分）；
- bench 矩阵 token 数与 jump_vec 一致，吞吐可直接比；
- 与 oxc_bitmap 的对比通过其 spans 门禁思路对齐（真实语料上两者
  token 边界已验证一致）。

语义层复用清单（`scanner.zig`）：

| oxc 部件 | my-scanner 等价物 |
| --- | --- |
| `scan_quoted` | `skipQuoted` / `scanString` |
| `scan_tmpl_text` + depth 栈 | `scanTemplate`（整体一个 token，含 `${}` 递归，比 oxc 三拆简单） |
| `scan_line/block_comment` | `lineEnd` / `simd.findBlockCommentEnd` |
| `scan_regex` + disambiguate | `scanRegex` + `regexAllowedAfter` 的位图版（见 §3） |
| op2/op3 完美哈希 + munch | 直接调 `scanPunct`（贪心前缀树，O(1)，口径天然一致） |
| kw_verify_batch 完美哈希 | `isKeyword`（完美哈希已在语义层） |
| `scan_number` + glue_number | `scanNumber` |
| kind 90+ 细类 | 13 类（my-scanner TokenKind），classify kind 数组按此设计 |

## 3. 位图版 regexAllowedAfter（移植最难点）

oxc 的 carve 在 coalesce **之前**做正则决策（此时 st 是原始位：每个标点
单字节都是 token start；`===` 尚未合并），其 `not_operator_position`
（~1300 行）在原始位图上向后走。my-scanner 的 `regexAllowedAfter(prev)`
只依赖 prev token 的 kind + 字节。位图等价实现：

```
regexAllowedBitmap(p):   // p = `/` 的位置，返回 true=正则
  #1 punct 尾部匹配：len 4..1，若 st_bit(p-len) 且 punctLenW(src,p-len)==len
     且中间无 trivia → prev=src[p-len..p] 按规则判
     （覆盖 `++/`：len2 命中 → 除号；`>>>=/`：len4）
  #2 否则 bm_prev1(st, p) 跳过 trivia kind（ws/注释起点）得 p0
     - 无 → true（文件头）
     - kind[p0]==Ident → 文本 [p0, bm_next0(word,p0)) 判 isKeyword：
       this/super → false；其他 keyword → true；identifier → false
     - kind[p0] ∈ {Number,String,Template,PrivateName} → false
     - kind[p0]==punct 且字节 '+'/'-' 且 src[p0+1]==同字节 且中间全 trivia
       → false（`++ /` 空格隔开场景）
     - 其他 punct 字节：`)`/`]` → false；否则 true
  已知偏差：`+++ /` 判正则（与贪心配对语义可能不一致）；真实语料
  出现率≈0，check.sh 全绿不构成对此路径的验证（如启用需登记
  tradeoff.md）。
```

### 4. NEON 原语映射（128-bit vs AVX2 256-bit）

| AVX2 | NEON (Zig @Vector(16,u8)) | 备注 |
| --- | --- | --- |
| `_mm256_shuffle_epi8` | `@shuffle`/vqtbl1q（Zig: `std.simd` 或手写） | 1:1，表 16B |
| `_mm256_cmpeq_epi8` | `==` on @Vector | 1:1 |
| `_mm256_movemask_epi8` | 合成：vand 权重 + 水平加（LLVM addv）或 vshrn+SWAR | **1 条 → ~5 条**，主要成本 |
| `_mm256_cvtepu8_epi32` | `vmovl` 两次 widen | 1→2 条 |
| `_mm256_permutevar8x32_epi32` | 无 32-bit 任意 permute → vqtbl 字节级收集（256×16B LUT） | build_spans 用 |
| `pext` | 不需要（oxc 也没用） | 无硬伤 |

宽度减半：每 64B 块 AVX2 用 2×256b，NEON 用 4×128b。M3 8-wide 解码
预期可吸收部分，**实测裁决**（AGENTS.md 规则：性能结论以 bench 实测）。

## 5. 对比口径（诚实声明）

- 主口径：bench.sh 矩阵，`bitmap` vs `jump_vec` vs `scalar`（同机同驱动
  同 token 口径），加上 oxc_bitmap 列（本机 generic fallback）。
- 同机 AVX2 对照：交叉编译 x86_64 AVX2+BMI2 版 oxc_bitmap，Rosetta 运行
  （`.rosetta-oxc/`，后台任务产出）。Rosetta 有翻译开销（~1.2-2x），
  NEON native 赢它是底线不是终点。
- 跨机参照：CI EPYC 的 oxc_bitmap 绝对数字（0.681 GB/s @ ts.js 等）。
  「达到相同速度」的裁定：**同机 Rosetta 对照 + CI 绝对值对照**两个都报。
- 口径差：oxc_bitmap 计时含 value lanes（cooked/数字 f64/atoms/注释
  meta），my-scanner 变体不做这些工作；oxc_bitmap 的 TS 泛型 `>` 拆单
  使其 token 数略多（Mtok/s 按各自 token 数计）。结论时注明。

## 6. 实验日志

### 2026-09-17 开题

- 侦察完成：CI/本机数字、oxc_lexer 源码（classify/find/scan/compress/
  coalesce/carve/tables 精读；disambiguate 不移植——用 my-scanner 语义）。
- 关键发现：无 pext 依赖；compress 是 LUT+shuffle（NEON 友好）；
  movemask 是最大缺口。
- Rosetta x86_64 基线出炉：oxc_bitmap AVX2 经 Rosetta 仅 0.37 GB/s
  （typescript.js）——比本机 jump_vec 还慢，Rosetta 只能当底线参照，
  主锚改为 CI EPYC 绝对值。

### 2026-09-17 中段：LUT 路线放弃

- 汇编实验：Zig/LLVM 不合成 vqtbl1q——同一 16B 查表，数组索引展开
  182 条指令、select 树 39 条（oxc 的 pshufb 是 1 条）。LUT 路线
  搁置，classify 全改比较链；movemask 用 LLVM 的 bool 向量 bitcast
  lowering（zip1+addv.8h）。
- 首版端到端跑通（jump_vec 的 76%），热点：compress 44%、coalesce
  30%。分 pass 计时工具留档 `tools/bitmap-passes-prof.zig`。

### 2026-09-17 后段：优化与审查

- kw 三重过滤（ts.min kw 判定 -65%）、CJK lead 快路径、位图跨轮
  复用（react.js 0.35→1.02）；dot-run 排除经审查撤销（与语义层
  `.if` 判 keyword 相悖）。
- 子 agent 并行审查（报告 + 代码）后修：carve 不扫 shebang 行
  （regex_starts 污染）、多字节非法码点整段消费、非法 `#` kind、
  `3.toFixed` 锚点误吞、4GB assert、CJK 快路径收窄到 0xE5..0xE9；
  新增 12 个防回归用例，check.sh 44/44 复绿，性能无回退。

### 2026-09-17 末段：合入 main 的新交付口径适配

main 在分叉后重写了语义层（Lexeme 粗流：trivia 不落盘 + newline_before
flag + 模板拆片 + `#` 恒单字节 punct + `/` 双回看判别），bitmap 变体
按新口径移植接缝，位图 pass 架构不变：

- 位图 5 → 6 张：新增 nl（\n、\r + miscPass 补 U+2028/29），compress
  用它把 trivia 区间的换行压成 flag_newline_before 挂到下一个显著
  lexeme（trivia 一律不落盘，keep_comments/regex_starts 旁路随
  Options 一并删除）。
- keywords pass 删除：粗流不再区分 keyword/identifier（全归
  identifier），关键字判别只在 `/` 路径按文本现查（同两阶段）。
- carve 适配模板拆片：`` ` `` 起扫 scanTemplatePart，`${` 后进入
  TemplateStack 跟踪（opener 之外加找 `{`/`}` 的 findTemplateStop），
  花括号计数归零的 `}` 起续片——与 scanner.scanAt 同口径。
- regexAllowedBitmap 对齐 regexAllowedAfter 双回看：补 prev2 名字位置
  判别（`.`/`?.`/`#`，opch run 重放取精确文本）；identifier 文本端点
  改取「下一个 st 位」（词内 `\u` 转义已并词，word 位图在 `\` 处断开）。
- miscBackslash 对齐 scanIdentifier 的转义合并：首字符后无 ASCII 快
  路径字符介入才并词（`a\u0042c` 并、`if\u0041` 断）；`#` 的
  scanPrivateName 语义删除（恒单字节 punct，miscHash 移除）。
- scanner.zig 可见性调整（无行为变化）：scanString、punctLenW 改 pub。

## 7. 实现（commit f9721cd 及前序）

- `src/variants/bitmap.zig`：~~五张位图~~（合并后六张：word/st/opch/
  numch/misc/nl）+ kind 数组；classify（NEON 比较链）→ miscPass
  （unicode/`\`）→ carve（opener 事件 + 字面量/正则 + 模板栈）→
  coalesce（multi/数字事件）→ compress（位图 → lexeme 流）。
- **与 oxc 的七张位图相比少了 kwinit 与 dot**：kwinit（关键字首字母
  位图）的预筛职责由 keywords pass 的三重位并行过滤吸收——word run
  起点、下一字节也是 word（排除单字符）、run 长度 ≤10（关键字都不
  超过 10 字符）——三关全过才进 isKeyword；oxc 用 kwinit 是为它的
  模式作用域关键字集服务，my-scanner 的 keyword 判定统一走语义层
  完美哈希、不分上下文，复制这层不划算。dot 不单独设位图：并入
  numch（digit|dot），`.5` 数字与 `...` 合并由事件处的 scanPunct
  口径自然分流。刻意**不做**「不在 dot 后」排除——语义层 `.if`
  同样判 keyword（isKeyword 无上下文），排除了会偏离 my-scanner 口径。
- 语义层复用：scanString/scanTemplate/scanNumber/scanPunct/scanRegex/
  isKeyword/decodeIdentEscape 等直接调用（tryComment/scanString/
  scanTemplate 改 pub）；`punctLenW` pub 供 gluePunct 直用。
- token 端点：end = 位图上下一个 st 位（sentinel at n），恒成立的论证
  与 oxc build_spans 的 stage 配对同构，见文件头注释。

## 8. 最终数字（M3 Pro native，GB/s，15 轮取最优，2026-09-17）

| 语料 | jump_vec | bitmap | bm/jv | EPYC oxc_bitmap(AVX2) | bm vs EPYC-oxc |
|---|---|---|---|---|---|
| react.js 72K | 0.38 | 1.02 | 2.68 | 1.068 | 0.95 |
| react.min.js 6.4K | 0.46 | 0.58 | 1.26 | 0.761 | 0.76 |
| typescript.js 8.2M | 0.63 | 0.60 | 0.95 | 0.681 | 0.88 |
| typescript.min.js 3.0M | 0.34 | 0.46 | 1.35 | 0.564 | 0.82 |
| checker.ts 3.1M | 0.72 | 0.75 | 1.04 | 0.846 | 0.89 |
| hanzi-chai.ts 255K | 0.52 | 0.56 | 1.08 | 0.187 | 3.0 |
| lib.dom.d.ts 1.9M | 1.60 | 1.14 | 0.71 | 1.036 | 1.10 |
| mon-entreprise.ts 104K | 0.71 | 0.82 | 1.15 | 0.679 | 1.21 |
| line-comments.js 1.7M | 2.17 | 1.09 | 0.50 | 0.951 | 1.15 |
| strings.js 547K | 0.94 | 0.66 | 0.70 | 0.683 | 0.97 |
| cn-dense.ts 968K | 1.24 | 0.58 | 0.47 | 0.284 | 2.0 |

要点（跨机口径注记：EPYC 数字来自 2026-09-16 CI，M3 为本地 15 轮
取最优；两机单核能力不同，绝对值对比按 ~5% 内不计胜负）：
1. **7/11 语料 ≥0.95 追平或反超**；9/11 在 0.85x 以上——跨机频率差
   折算后可视为同档。未到 0.85 的两个 minified 语料归因见 §9。
2. 胜负倾向与 oxc_bitmap 一致（token 密度高/unicode 密集赢、跳跃
   密集输），但幅度普遍缩水，且 strings.js（oxc 1.25x → 我们 0.70x）、
   typescript.js（1.64x → 0.95x）两处方向翻转——退化源头是 compress
   未 SIMD 化与 coalesce 逐事件贪心（oxc 有 pshufb LUT 加速），是
   已知缺口而非移植噪声，见 §9 未竟事项。
3. 主表 bitmap 列已是「位图缓冲跨轮复用」口径（对齐 oxc 的 arena
   复用语义，见 §7）；若每轮重新 alloc/memset 位图（约 1.9×n 字节），
   小文件的固定开销可达 3 倍（react.js 0.35）。

## 9. 归因与教训

### 为什么 NEON 版能追上 AVX2 版

oxc 的速度本源是「每 token 路径极轻」（位图批量产出 vs 逐 token
dispatch），不是指令总量少。NEON 版 classify 的指令数约为 AVX2 的
3-4 倍（movemask 合成 ~11-14 条/32B/张 + 比较链），但：
- M3 8-wide 的 IPC 上限远高于流水线实际 IPC（六趟顺序 pass 受访存/
  依赖限制）；
- classify 只占端到端 15-20%（2.6-3.1 GB/s 的单 pass 速率），非瓶颈。
端到端的瓶颈在 coalesce（事件标量处理）与 compress（位图搬运），
两边的每事件成本同量级，M3 的频率/宽核优势得以兑现。

### NEON 与 AVX2 的真实差异（实测）

- **movemask**：AVX2 1 条；Zig/LLVM 对 `@bitCast(bool vector → int)`
  生成 zip1+addv.8h 序列（~11-14 条/32B）。手写 vand+addv 略优，
  pmull 黑科技未做（预期 ~4 条，收益 <10%）。
- **pshufb 查表**：Zig 数组索引展开 182 条、select 树 39 条——LLVM
  不合成 vqtbl，**LUT 方案在 Zig+NEON 不可用**（inline asm 是唯一
  出路，未走）。oxc 的 PH 哈希 LUT（classify 的 punct kind、compress
  的 pair_luts）全部改用比较链/标量路径。
- **pext**：oxc 本来就没用（LUT+shuffle 实现压缩），BMI2 不是硬伤。

### 教训

- **位图的边界 corner 是主要 bug 来源**：`1<<64`（bmPrev1/bmClearRange/
  bmAny）、ctz 先消费后取位（compress 少产首 token）、复用缓冲的
  sentinel word 残留（phantom tokens）、stage 哨兵越界（batch 满时）
  ——位图代码每个 shift 都要问「64 会怎样」。
- **正确性门禁先行**：23 个单测用例（含 `3in4`、`if\u0041`、`#x\u41`、
  LS/NBSP）快速闭环，check.sh 44/44 兜底；每轮优化必须全绿。
- **语义对齐要逐条验证而不是想当然**：`if\u0041` 是两个 token
  （ASCII 词遇 `\` 断词）而非一个；`3in4` 的 `in4` 被吞不产 token
  （候选位图里非起点）——都与最初从 oxc/Rust 语义的猜测相反。
- **profiler 的 arena 复用与 bench 的每轮 alloc 差 3 倍**（react.js
  1.09 vs 0.35）——口径先对齐（oxc 本来就是复用），再谈优化。

### 未竟事项（下一轮候选）

- ts.min 0.82x / react.min 0.76x：compress 的 SIMD 化（oxc 用
  pair_luts+pshufb，NEON 无 tbl——候选：GPR 256 项 LUT 位置展开 +
  pmull movemask）；coalesce 的 op2/op3 式哈希合并（现在每事件调
  punctLenW 贪心）。
- inline asm vqtbl1q 封装后重估 classify LUT 方案。
- `x86_64` 上 bitmap 变体的 AVX2 后端（同构对比消除 ISA 变量）。
- Rosetta 口径：oxc_bitmap AVX2 经 Rosetta 仅 0.37 GB/s（ts.js），
  本机 bitmap 0.60 GB/s 是它的 1.6x——Rosetta 数字只作底线参照，
  全语料见 `.rosetta-oxc/results.json`。

## 10. 第二轮：口径纠正与 Rust NEON 后端（2026-09-17 晚）

### 10.1 口径纠正（对第一轮的修正）

第一轮用「M3 本机 bitmap 绝对值 vs CI EPYC oxc_bitmap 绝对值」对照，
这是跨机非法比较。合法口径（bench 的基线比较法）：

1. **同机矩阵**：M3 上全部实现（zig 侧 + rs 侧）同机跑，列间 GB/s
   直接可比；
2. **基线倍数跨机对照**：M3 的 bitmap/jump_vec 倍数 vs CI EPYC 的
   oxc_bitmap/jump_vec 倍数——倍数消除机器差异。

### 10.2 Zig 查表缺口的补法

用户指出「如果只是 Zig 做不了，可以用 Rust」。先验证 Zig 是否真做
不了：**Zig inline asm 可封装 NEON 指令**——占位符语法是 `%[name]`
（GCC 命名操作数风格），`$n` 是错误写法（此前所有 asm 失败均源于此）。
`tbl %[ret].16b, { %[tab].16b }, %[idx].16b` 编译且语义正确。

随后把 bitmap 变体的 classify 升级为 oxc 式 nibble LUT（位面绑定
hi 行、comptime 256 字节冲突自检），单 pass +14%（3.30 GB/s）。

### 10.3 Rust NEON 后端（交付物对齐的主战场）

Zig 变体的交付物天然偏离 oxc_bitmap（13 类 token、无 value lanes、
disambiguation 是 my-scanner 启发式）。公平对比要求同交付物——
**直接给 oxc_lexer 本体写 aarch64 后端**：同一份代码、同一套
disambiguate/lanes/诊断、同一测试套（test262 级）。

- patch：`tools/lexbench-rs/oxc-lexer-neon-aarch64.patch`（765 行），
  `prepare-lexbench.sh` 拉取官方源码树后自动应用；
- 覆盖：classify（nibble LUT + VQTBL + punct1 哈希链）、find1-4 与
  find_opener 家族宏、scan_block/line_comment、compress_blocks
  （pair_luts + VQTBL 位置展开 + vmovl widen）、build_spans/lanes_post
  （与 generic 同构）；cfg 接线保持 AVX2 分支不动，CI/M3 同代码；
- 正确性：oxc_lexer 全部测试通过（160 lib + 45 + 5，含歧义/诊断/
  TS 关键字）；开发期用「NEON vs scalar/generic 位图级对拍 test」
  抓出四 bug——movemask 位序（even/odd 折叠未交错，改低/高 64 位
  独立 SWAR）、mrg 位面掩码（0x1f → 0x3c/0x80/0x03）、VBSL 按位
  blend 被 h<<3 杂散位污染（VPBLENDV 只看字节 MSB，NEON 需展开
  0x00/0xFF）、compress 段 base 误拆（16 字节共享 base+16p）。

### 10.4 第二轮数字（M3 native，25 轮取最优，GB/s）

| 语料 | generic(M3) | **NEON(M3)** | NEON/generic | EPYC AVX2 | NEON ≥ EPYC？ |
|---|---|---|---|---|---|
| react.js | 0.820 | **1.066** | 1.30x | 1.068 | ≈持平 |
| react.min.js | 0.573 | **0.819** | 1.43x | 0.761 | ✓ |
| typescript.js | 0.581 | **0.739** | 1.27x | 0.681 | ✓ |
| typescript.min.js | 0.488 | **0.617** | 1.26x | 0.564 | ✓ |
| checker.ts | 0.700 | **0.964** | 1.38x | 0.846 | ✓ |
| hanzi-chai.ts | 0.246 | **0.269** | 1.09x | 0.187 | ✓ |
| lib.dom.d.ts | 0.780 | **1.119** | 1.43x | 1.036 | ✓ |
| mon-entreprise.ts | 0.578 | **0.737** | 1.27x | 0.679 | ✓ |
| line-comments.js | 0.790 | **1.045** | 1.32x | 0.951 | ✓ |
| strings.js | 0.540 | **0.652** | 1.21x | 0.683 | ✗（0.95） |
| cn-dense.ts | 0.322 | **0.352** | 1.09x | 0.284 | ✓ |

上表「NEON ≥ EPYC？」一列是**跨机绝对值对照**（M3 vs CI EPYC，
单核不同），按 §10.1 口径只能作参照、不能作结论：NEON（M3）在
10/11 语料不低于 EPYC AVX2（唯一差口 strings.js，0.95）。同机矩阵
内的合法读数是 NEON/generic 列：aarch64 后端比同代码 generic 后端
快 1.09-1.43x。跨机的结论性判定见 §10.5 基线倍数。

### 10.5 基线倍数口径（严格标准，结论性口径）

分母唯一且同机：本仓库 jump_vec（同一 bench 驱动；yuku 第三方基线
仅作旁证，不入分母）。M3 的 jump_vec 基线本身比 EPYC 强约 1.5x
（中位数），所以「相同速度」在倍数口径下要求 NEON 版跑出 EPYC
1.5 倍的绝对速度。

| 语料 | NEON(M3) | jump_vec(M3) | bm/jv M3 | bm/jv CI | 达成？ |
|---|---|---|---|---|---|
| react.js | 1.066 | 0.38* | 2.81 | 1.54 | 表面 ✓ |
| react.min.js | 0.819 | 0.22~0.46* | 1.78-3.72* | 3.37 | 不可判定（小文件噪声） |
| typescript.js | 0.739 | 0.63 | 1.17 | 1.64 | ✗ |
| typescript.min.js | 0.617 | 0.35 | 1.76 | 2.84 | ✗ |
| checker.ts | 0.964 | 0.73 | 1.32 | 1.75 | ✗ |
| lib.dom.d.ts | 1.119 | 1.60 | 0.70 | 1.00 | ✗ |
| mon-entreprise.ts | 0.737 | 0.71 | 1.04 | 1.37 | ✗ |
| line-comments.js | 1.045 | 2.26 | 0.46 | 0.66 | ✗ |
| strings.js | 0.652 | 0.98 | 0.67 | 1.25 | ✗ |
| cn-dense.ts | 0.352 | 1.29 | 0.27 | 0.48 | ✗ |
| hanzi-chai.ts | 0.269 | 0.52 | 0.52 | 0.81 | ✗ |

*jump_vec 取自第二轮前后的本机 bench（15 轮，§8 同源）；react.min
（6.4KB）单轮仅数十微秒，jump_vec 两轮测量 0.22-0.46 波动近一倍，
该语料的倍数判定不可靠。

**结论：基线倍数口径未达成**（1/11 表面达成且为假象——react.js 的
M3 jump_vec 异常偏弱 0.38 vs CI 0.693，2.81 是分母红利不是分子优势；
~1.5x 是中位数，逐语料基线强度 0.55x-2.26x 不等，倍数消除的是总体
主频差，逐语料仍有基线特异性残余）。差口来源：①基线红利 ×1.5 需要
NEON 版跑出 EPYC 1.5 倍绝对速度；②NEON 版相对退化幅度比 AVX2 版大
——跳跃密集语料尤甚（AVX2 后端 32B/步 vs NEON 16B/步、compress 的
cvtepu8/permutevar8x32 在 NEON 需多指令展开；注：32B 化已实证负收
益，见 §10.7，修复路径不在拉宽步长）。

### 10.6 结论

- 原目标「在 Apple Silicon 上达到 oxc_lexer 相同速度」：本机没有
  同机 AVX2 可对照（Rosetta 仅底线参照，见 §6），结论性口径落在
  **基线倍数——未达成（§10.5）**。跨机绝对值参照 10/11 不低于
  EPYC AVX2，说明交付物对齐后 M3 单核不落后于 CI 单核，但不是
  结论性判据。
- 在**基线倍数口径**下：未达成（2/11），剩余差距有明确的指令级
  归因（见 §9 未竟事项 + §10.5），构成下一轮的量化目标。

### 10.7 32B 步长实验：**否决**（NEON vs AVX2 的结构性差异实证）

为收窄跳跃密集语料（line-comments/strings）的倍数差，把
scan_line_comment/scan_block_comment 从 16B 双向量 32B 化（对齐 AVX2
步幅）：line-comments 1.045→0.976、strings 0.652→0.620、**lib.dom
1.119→0.910（-19%）**——全面负优化，已回退（patch 文件始终保持
16B 版本）。

根因：AVX2 的 32B 步长近乎免费（vmovemask 1 条指令/32B），NEON 的
movemask 是合成序列（~9 条/16B），翻倍步长 = 翻倍 movemask 成本 +
额外跨界向量组，超过循环开销的节省。**NEON 上模拟 AVX2 的宽步长
模式是负收益；NEON 的收益路径在减少 pass 数与 tbl 密集的分类/压缩，
不在拉宽扫描步长。**

### 10.8 第二轮交付清单

- `tools/lexbench-rs/oxc-lexer-neon-aarch64.patch`：oxc_lexer 的
  aarch64 后端（classify/find/scan/compress 四趟 + cfg 接线；
  coalesce/misc 两趟仍走 generic 标量路径，为后续候选；765 行
  patch，AVX2 分支原样保留，CI 与 M3 同代码）
- `scripts/prepare-lexbench.sh`：拉取后自动应用 patch（幂等，
  失效报错）
- Zig 线：`tbl1` inline asm 封装 + classify nibble LUT（+14% 单
  pass），防回归于 `src/variants/bitmap.zig`
- 主仓库 `.bench-deps/oxc` 曾被失败 patch 的绝对路径头污染，已删除
  （下次 prepare 幂等重拉干净版，实证确认无 aarch64 残留）
