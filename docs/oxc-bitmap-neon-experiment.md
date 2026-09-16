# 实验：oxc_lexer 位图流水线移植到 Zig + NEON

状态：进行中（2026-09-17 开题）
分支：`exp/oxc-bitmap-neon`（起点 58d3e3c）
目标：**在 Apple Silicon（NEON）上达到 oxc_lexer（x86_64 AVX2+BMI2）相同的速度**。

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

### 3. 位图版 regexAllowedAfter（移植最难点）

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
  已知可接受 corner：`+++ /`（真实语料 ~0 出现率，check.sh + 随机交叉验证兜底）
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
- Rosetta x86_64 基线任务已派出（后台）。
- 下一步：tables comptime LUT + classify NEON + 标量对照交叉验证。
