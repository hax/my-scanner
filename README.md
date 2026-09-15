# my-scanner

用 Zig 充分压榨 SIMD，给 JS/TS 做一个尽可能快的词法分析器（scanner/lexer）的实验项目。

## 为什么做这个

simdjson 证明了"结构性跳过"式的向量化能让解析的 I/O 密集阶段快一个数量级，
但主流 JS 工具链（V8、esbuild、swc、oxc）的 scanner 至今仍以逐字节标量循环为主。
这个项目想系统地回答：**JS scanner 的每个环节各能从 SIMD 拿到多少收益，瓶颈最终会停在哪里。**

## SIMD 技巧

所有向量化集中在 [src/simd.zig](src/simd.zig)：用 Zig 的 `@Vector` 表达，
由编译器按目标平台自动降到 AVX2 / NEON，不写 intrinsics。
scanner 采用 simdjson 式**两阶段架构**：

**阶段 1（分类 pass，纯 SIMD 无分支）**：一次扫描为每个字节建立分类位平面
（空白 / 标识符字符），纯位运算推导 token 候选起点掩码：

```
candidate[i] = !whitespace[i] & !(ident_part[i] & ident_part[i-1])
```

即"非空白，且不是标识符的中间字节"，跨块用 carry 位衔接。字符串/注释/
正则内部的字节同样命中候选（阶段 1 不做范围剔除），但阶段 2 贪心消费完
token 后从它的终点继续迭代候选位，假起点自然被越过——无需在分类阶段
处理字符串/注释范围。多个分类平面还可经"矩阵旋转"（`packClasses`）打包成
每字节一个 u8 类别码（`Class`），后续平面继续叠位即可。
换行统计也在这一趟用 `@popCount` 一次算完，替代散落在各 token 扫描里的行数维护。

**阶段 2（token 化）**：`@ctz` 迭代候选起点位图，在每个起点按首字符分发
贪心消费（复用各 scanXxx），token 区间内的假候选位被自动跳过。

热路径的向量扫描模式一览：

| 环节 | 手法 |
| --- | --- |
| 跳空白 | ~~逐 token 重扫~~ 两阶段：候选位图 + `@ctz` 一步到下一个 token 起点 |
| 标识符 | 范围比较合成 `[A-Za-z0-9_$]` 掩码，`@ctz(~mask)` 直接得到结尾偏移 |
| 字符串 / 模板 | 掩码定位 `引号 \| 反斜杠 \| 换行`，转义对直接跳 2 字节；模板另加 `$`（`${`）|
| 块注释 | `slash_mask & (star_mask << 1)` 一条位逻辑同时探测 32 个位置的 `*/`，跨块用 carry 位衔接 |
| 行数统计 | 阶段 1 的 `@popCount(newline_mask)` 一趟算完 |

数字、正则、punctuator 目前是标量：数字 token 平均只有几字节，
punctuator 是 O(1) 的首字符前缀树，先求正确，等 profile 说话再决定是否向量化。

## 两个脚本

```sh
scripts/check.sh                    # 正确性：单元测试 + 与 tsc 差分对比
scripts/bench.sh                    # 性能：my-scanner vs yuku lexer 吞吐对比
```

## 与 yuku 的对比基准

[scripts/bench.sh](scripts/bench.sh) 首次运行会把 [yuku](https://github.com/yuku-toolchain/yuku)
的源码 clone 到 `.bench-deps/`（gitignore），然后同进程、同文件、同计时器跑两个
lexer：口径对称（都把产出的 token append 到复用缓冲、读文件与初始化不计入），
N 轮取最优。yuku 纯 scanner 与 tsc 同款把正则/模板续扫推迟给 parser，
bench 里按 yuku parser 的方式调 `reScanAsRegex` / `reScanTemplateContinuation`
对齐（正则决策与 my-scanner 完全一致，模板用花括号平衡栈跟踪）。

M2 / ReleaseFast / 30 轮取最优（bench 同时驱动 yuku 两版本：引入向量化前的
基线快照与上游主干 `perf(lexer)` 提交之后；采样时段系统负载 ~4.5，绝对值
偏低约 10%，三者同进程比较不受影响）：

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
checker.ts 持平。**lib.dom.d.ts 上 yuku-main 反超我们 24%**——注释密集
语料是当前的明确短板；注意我们的块注释同样是 SIMD（`slash & star<<1`
的 32B 块 + carry 衔接，指令数理应更少），差距的具体定位需要 profile，
不预设结论（见 roadmap）。

（历史演进：单阶段 0.25-0.59 → 两阶段分类 0.41-1.05 → 块内迭代等微优化
0.55-1.07 → 数据流化 + 冷路径 + 打包 punct 0.59-1.13 → 类别码分发
0.71-1.35 GB/s。被数据否决的尝试：阶段融合（-3~12%，两阶段分离的缓存
行为更好）与 block_size=16（-9%）。安静时段的绝对值另见前文各轮记录。）

## 正确性验证

单元测试之外，用 [tools/compare-tsc.mjs](tools/compare-tsc.mjs) 把 tsc 的 scanner
（typescript 包的 `ts.createScanner`）当参考实现做 token 级差分：以切分（字节偏移）
对齐为主，语义分类从宽。四个真实大文件全部对齐，零分类硬差异：

| 文件 | tokens | 结果 |
| --- | --- | --- |
| typescript.js | 1,122,439 | ✓ 切分完全一致 |
| checker.ts | 348,152 | ✓ 切分完全一致 |
| lib.dom.d.ts | 116,895 | ✓ 切分完全一致 |
| react.js | 8,411 | ✓ 切分完全一致 |

对比口径中归一的 tsc scanner 设计差异（推迟给 parser 重扫，不是谁对谁错）：

- tsc 按 UTF-16 code unit 计偏移，my-scanner 按字节计（对比时按 latin1 喂入统一坐标系）
- tsc 永不合并 `>` 家族（`>>` `>=` `>>>=`），由 parser `reScanGreaterToken` 合并——泛型 `A<B<C>>` 的需要
- tsc 对 `/` 保守判除号，由 parser `reScanSlashToken` 重扫为正则（正则体内相邻的 `//` 在保守路径会被当成行注释）
- 模板字面量 tsc 拆成 Head/Middle/Tail，模板字符串类型（`` `${string}` ``）纯 scanner 甚至不续扫；这两类整体边界以 my-scanner 为准同步，其内部逻辑由单元测试保证

```sh
cd tools && npm i && cd ..
node tools/compare-tsc.mjs corpus/*.js corpus/*.ts
```

## 现状

### 吞吐（M2, ReleaseFast, --bench=20）

| 文件 | 大小 | tokens | GB/s | Mtok/s |
| --- | --- | --- | --- | --- |
| typescript.js（bundled tsc） | 8.2 MB | 1.12 M | 0.25 | 34.6 |
| checker.ts（tsc 源码） | 3.1 MB | 348 K | 0.31 | 34.6 |
| react.js | 72 KB | 8.4 K | 0.34 | 40.0 |
| lib.dom.d.ts | 1.9 MB | 117 K | 0.61 | 37.9 |

（基准文件在 `corpus/`，已 gitignore）

Mtok/s 几乎恒定而 GB/s 随 token 密度反向变化——瓶颈是每 token 的固定开销
（分发 + emit + append），不是 SIMD 扫描本身。所以 roadmap 第一项就是 token 批量产出。

已支持（ASCII 阶段）：

- 标识符 / 关键字（含 let、static、async、of 等上下文关键字的提示性归类）
- 数字：十/十六/八/二进制、小数、指数、`_` 分隔符、BigInt `n` 后缀
- 字符串（单双引号、转义）、模板字面量（跨行、`${}` 子表达式的简易平衡扫描）
- 正则字面量（基于前一 token 的近似判别，处理 `/` 的除号/正则二义性）
- 全部 punctuator（含 `>>>=` `??=` `?.` `...` 等最长匹配与 `?...` 歧义排除）
- 行/块注释、shebang、私有名 `#x`
- 容错：非法字节/未闭合字面量产出 `illegal` token 而不是中断

已知差距（都是 TODO，代码里有标注）：

- unicode 标识符（`\u` 转义、非 ASCII 合法标识符字符）
- `}` 之后的正则/除法歧义需要花括号栈做精确判定
- 模板 `${}` 里嵌套模板与注释会骗过简易平衡扫描
- 行继续（`\<newline>`）的物理行计数、`\r\n` 归一化

## 用法

```sh
zig build test                        # 跑测试
zig build run -- src/scanner.zig      # 扫描文件，输出统计
zig build run -- --dump some.js       # 打印每个 token
zig build --release=fast run -- --bench=50 big.js   # 吞吐基准
```

```
$ zig build run -- src/scanner.zig
src/scanner.zig: 26963 bytes, 5649 tokens, 817 lines (eof=1, identifier=1433, keyword=350, number=145, string=348, punct=3372)
```

作为库使用（`build.zig.zon` 依赖 + `@import("my_scanner")`）：

```zig
const result = try my_scanner.scan(allocator, src, .{});
for (result.tokens) |tok| { ... }
```

## Roadmap

- [x] 吞吐优化：两阶段分类 + 块内 ctz 迭代 + 数据流化 + 冷路径分离 + 打包 punct + 类别码分发（comptime 256 项 dispatch 表 + `{}();,` 单字节 punct 零调用快路径；对标 yuku：0.44x → 1.16-1.40x，累计 ~3x）
- [x] **boundary v2（精简版落地）**：[设计文档](docs/simd-token-boundary-prefilter.md) 的 ID 连接 + Unicode whitespace（19 码点 trivia 化）+ 逻辑换行（\r\n、U+2028/2029）+ ASCII 快路径。实测砍掉了 OP/ESC 平面（粗筛精化在 pos 跳过兜底下负收益，端到端 -25~30%），语义成本 ~13-16%，OP 集合审计成果留给将来免验证阶段 2。实验全记录见 [类别码纪要](docs/class-code-and-simd-lookup.md) 的 boundary v2 一节
- [x] whitespace 平面查表实验：**否决**——JS 空白恰为连续区间 {09..0D}+20，范围比较（3 条/16B）已最优；simdjson 查表是被 JSON 空白的不连续布局逼的。结论：等值查表只对「低 nibble 互异**且不连续**」的集合有意义（[实验记录](docs/class-code-and-simd-lookup.md)）
- [ ] SIMD 查表分类第二阶段（packed tag / 全表 LUT）：前提已变化——boundary v2 实测砍掉 OP/ESC 后只剩 ID 平面，多平面需求暂不存在；若将来做「candidate 免验证」激进阶段 2（OP/ESC 回归），此项随之复活（矩形约束 + GF(2) 变换搜索，见类别码纪要）
- [x] 单字节 punct 批量块路径：**否决**——实测纯 punct_single 块仅 4.3-7.4%，run≥2 覆盖的 token 检测成本与省下的 dispatch 查询相抵；现有 dispatch 表的单 token 快路径已覆盖该场景
- [x] 模板子表达式：平衡扫描已感知嵌套模板（递归 scanTemplate）、行/块注释与字符串；正则字面量里的 `}` 仍为已知限制
- [x] **注释密集语料的差距定位与部分修复**（2026-09-15）：
  - ✅ **整块跳过**：块注释/长 token 覆盖的整块直接 continue，不再逐假候选迭代（JSDoc 内 `*` `/` 全是假候选）——lib.dom.d.ts 73.5 → ~82 Mtok/s（+12%），与 yuku-main 差距 0.76x → **0.86x**
  - ❌ 块内 ws 判定内联、`|0x20` fold 压缩 identPartMask：均无实测收益，回退（教训：profile 的 ReleaseFast 行号归因不可靠——曾被误导追查 45 个码点的「热点」；指令数减少不必然转化为吞吐）
  - 剩余 -14% 为**结构性**：classify pass 在注释密集、低 token 密度语料上占总时间 26%（1.9MB 文件 0.38ms），单阶段的 yuku 没有这一趟；两阶段架构的语料谱系 trade-off——minified 端 +6~9%，注释密集端 -14%。进一步收敛需架构级改动（阶段融合已实测否决）或阶段 2 批量 token 化
- [x] **跳跃驱动分类 pass（长跳跃前移）**：**完整实验后否决**（[实验记录](docs/jump-driven-classify-experiment.md)）——把字符串/模板/注释的跳跃终点判定前移进分类 pass（起点无正则歧义 + 顺序状态 + 正则误触发溢出回滚），正确性达成（7 语料差分全绿），但 line-comments 账本证明跳跃工作只是等量搬迁（cls +0.27ms / 阶段 2 -0.27ms，零净收益）且 cls 检测税 + 巨函数寄存器退化使其 4.5→2.0-2.5 GB/s。**根本教训：yuku 的注释向量化收益来自单阶段架构（字节只触一次），两阶段里搬跳跃是换位置付钱**；洞察的完全兑现需要第三形态——单阶段 + 按块产出即消费的 SIMD 候选缓冲，记为独立大方向
- [ ] 更进一步：SoA token 输出、token 簇融合
- [x] 宽度实验：block_size=16 在 M2 上 -9%（块循环开销翻倍，高于 NEON 单指令收益）被否决，32 定稿；64（AVX-512）待有对应硬件再测
- [x] 标量 baseline + A/B 计量：`classifyTokenStartsScalar` 与 SIMD 版经交叉验证（固定用例 + 200 轮随机字节流逐位一致，顺带抓出 SIMD 版三个跨块边界 bug：ws lead 候选性、跨块 CRLF 回改、跨块 U+2028 变体）；bench 的 `cls-s` 行常设输出。**SIMD 分类 pass = 标量的 8.8-11.9x**（4.9 vs ~0.45 GB/s）
- [x] SIMD 原语 A/B 计量（bench `--prim`）：identPartMask **19-24x**（16-17 vs 0.7-0.8 GB/s）、stringStopMask **17-21x**（21.6 vs 1.0-1.25）、whitespaceMask **仅 2.2x**（28.5 vs 12.9）——后者标量循环被 LLVM 自动向量化到接近手写 SIMD；前两者的标量版因逐位打包（`m |= 1<<j` 的变量移位）阻止 autovectorize。教训：**标量基线的写法决定 A/B 的公平性**，能被自动向量化的模式 SIMD 增益有限
- [x] unicode 标识符：ID_Start/ID_Continue 范围表（tools/gen_unicode_tables.mjs 从 UCD 生成，Unicode 17.0.0，682/795 范围二分）+ 严格 UTF-8 解码；scanIdentifier 遇非 ASCII 解码续扫（含混排、unicode 私有名 `#π`）；ID_Continue 含 ECMAScript 显式的 ZWNJ/ZWJ。已知容错差异：ident 后裸跟非 ident 非 ws 的非 ASCII 字符（非法 JS）会被 ID-like 连接静默跳过。`\uXXXX` 转义标识符已支持（含转义 `$`/`_`/unicode 私有名；`\u{...}` 形式对齐 tsc 纯 scanner 不合并；转义出的关键字我们产 identifier 而 tsc 产 keyword——差分 soft 类别）
- [ ] 模板子表达式递归调 scanner 本体
- [x] token 行号：`Result.lines`（LineIndex，每块逻辑换行位图 + 前缀和，O(1) `lineAt(offset)`；零 token 流开销——不改 Token 结构，`--dump` 输出加行号列）。列号可由消费方从行首 offset 推导，暂不内置
- [ ] 对齐 Test262 / 真实大型 JS 代码库的模糊正确性验证
- [ ] 与 esbuild / swc / oxc 的 scanner 吞吐对比

## License

MIT
