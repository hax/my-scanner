# Roadmap

进行中与已否决方向的清单。已完成条目兼作决策记录；带数字的完整演进
见 [architecture.md](architecture.md) 的决策史，最新性能趋势见 CI 的
bench-reports 分支趋势页（机制见 architecture.md 的「CI」一节）。
本清单的维护规则见 [AGENTS.md](../AGENTS.md)。

- [x] 吞吐优化：两阶段分类 + 块内 ctz 迭代 + 数据流化 + 冷路径分离 + 打包 punct + 类别码分发（comptime 256 项 dispatch 表 + `{}();,` 单字节 punct 零调用快路径；对标 yuku：0.44x → 1.16-1.40x，累计 ~3x）
- [x] **boundary v2（精简版落地）**：[设计文档](simd-token-boundary-prefilter.md) 的 ID 连接 + Unicode whitespace（19 码点 trivia 化）+ 逻辑换行（\r\n、U+2028/2029）+ ASCII 快路径。实测砍掉了 OP/ESC 平面（粗筛精化在 pos 跳过兜底下负收益，端到端 -25~30%），语义成本 ~13-16%，OP 集合审计成果留给将来免验证阶段 2。实验全记录见 [类别码纪要](class-code-and-simd-lookup.md) 的 boundary v2 一节
- [x] whitespace 平面查表实验：**否决**——JS 空白恰为连续区间 {09..0D}+20，范围比较（3 条/16B）已最优；simdjson 查表是被 JSON 空白的不连续布局逼的。结论：等值查表只对「低 nibble 互异**且不连续**」的集合有意义（[实验记录](class-code-and-simd-lookup.md)）
- [ ] SIMD 查表分类第二阶段（packed tag / 全表 LUT）：前提已变化——boundary v2 实测砍掉 OP/ESC 后只剩 ID 平面，多平面需求暂不存在；若将来做「candidate 免验证」激进阶段 2（OP/ESC 回归），此项随之复活（矩形约束 + GF(2) 变换搜索，见类别码纪要）
- [x] 单字节 punct 批量块路径：**否决**——实测纯 punct_single 块仅 4.3-7.4%，run≥2 覆盖的 token 检测成本与省下的 dispatch 查询相抵；现有 dispatch 表的单 token 快路径已覆盖该场景
- [x] 模板子表达式：平衡扫描已感知嵌套模板（递归 scanTemplate）、行/块注释与字符串；正则字面量里的 `}` 仍为已知限制（[tradeoff.md](tradeoff.md) L1）
- [x] **注释密集语料的差距定位与部分修复**（2026-09-15）：
  - ✅ **整块跳过**：块注释/长 token 覆盖的整块直接 continue，不再逐假候选迭代（JSDoc 内 `*` `/` 全是假候选）——lib.dom.d.ts 73.5 → ~82 Mtok/s（+12%），与 yuku-main 差距 0.76x → **0.86x**
  - ❌ 块内 ws 判定内联、`|0x20` fold 压缩 identPartMask：均无实测收益，回退（教训：profile 的 ReleaseFast 行号归因不可靠——曾被误导追查 45 个码点的「热点」；指令数减少不必然转化为吞吐）
  - 剩余 -14% 为**结构性**：classify pass 在注释密集、低 token 密度语料上占总时间 26%（1.9MB 文件 0.38ms），单阶段的 yuku 没有这一趟；两阶段架构的语料谱系 trade-off——minified 端 +6~9%，注释密集端 -14%。进一步收敛需架构级改动（阶段融合已实测否决）或阶段 2 批量 token 化
- [x] **跳跃驱动分类 pass（长跳跃前移）**：**完整实验后否决**（[实验记录](jump-driven-classify-experiment.md)）——把字符串/模板/注释的跳跃终点判定前移进分类 pass（起点无正则歧义 + 顺序状态 + 正则误触发溢出回滚），正确性达成（7 语料差分全绿），但 line-comments 账本证明跳跃工作只是等量搬迁（cls +0.27ms / 阶段 2 -0.27ms，零净收益）且 cls 检测税 + 巨函数寄存器退化使其 4.5→2.0-2.5 GB/s。**根本教训：yuku 的注释向量化收益来自单阶段架构（字节只触一次），两阶段里搬跳跃是换位置付钱**；洞察的完全兑现需要第三形态——单阶段 + 按块产出即消费的 SIMD 候选缓冲，记为独立大方向（已由 jump_vec 变体承接前驱，见 architecture.md）
- [ ] 更进一步：SoA token 输出、token 簇融合
- [x] 宽度实验：block_size=16 在 M2 上 -9%（块循环开销翻倍，高于 NEON 单指令收益）被否决，32 定稿；64（AVX-512）待有对应硬件再测
- [x] 标量 baseline + A/B 计量：`classifyTokenStartsScalar` 与 SIMD 版经交叉验证（固定用例 + 200 轮随机字节流逐位一致，顺带抓出 SIMD 版三个跨块边界 bug：ws lead 候选性、跨块 CRLF 回改、跨块 U+2028 变体）；bench 的 `cls-s` 行常设输出。**SIMD 分类 pass = 标量的 8.8-11.9x**（4.9 vs ~0.45 GB/s）
- [x] SIMD 原语 A/B 计量（bench `--prim`）：identPartMask **19-24x**（16-17 vs 0.7-0.8 GB/s）、stringStopMask **17-21x**（21.6 vs 1.0-1.25）、whitespaceMask **仅 2.2x**（28.5 vs 12.9）——后者标量循环被 LLVM 自动向量化到接近手写 SIMD；前两者的标量版因逐位打包（`m |= 1<<j` 的变量移位）阻止 autovectorize。教训：**标量基线的写法决定 A/B 的公平性**，能被自动向量化的模式 SIMD 增益有限
- [x] unicode 标识符：ID_Start/ID_Continue 范围表（tools/gen_unicode_tables.mjs 从 UCD 生成，Unicode 17.0.0，682/795 范围二分）+ 严格 UTF-8 解码；scanIdentifier 遇非 ASCII 解码续扫（含混排、unicode 私有名 `#π`）；ID_Continue 含 ECMAScript 显式的 ZWNJ/ZWJ。已知容错差异见 [tradeoff.md](tradeoff.md) T2/T3；`\uXXXX` 转义标识符已支持（含转义 `$`/`_`/unicode 私有名）
- [ ] 模板子表达式递归调 scanner 本体
- [ ] 罕见 token 排列的重扫/二次切分协议：当前 `scan()` 一次性切分，歧义点（`/` 的正则/除号、`}` 后的正则等）按单 token 回看启发式硬判（[tradeoff.md](tradeoff.md) T1）；按 [goals.md](goals.md) 的分工设想，scanner 提供重扫指令（tsc `reScanAsRegex` 式），由 parser 在罕见形态上按语法上下文发起重扫或二次切分，scanner 不为罕见形态付出精确性成本
- [x] token 行号：`Result.lines`（LineIndex，每块逻辑换行位图 + 前缀和，O(1) `lineAt(offset)`；零 token 流开销——不改 Token 结构，`--dump` 输出加行号列）。列号可由消费方从行首 offset 推导，暂不内置
- [ ] 对齐 Test262 / 真实大型 JS 代码库的模糊正确性验证
- [ ] 与 esbuild / swc / oxc 的 scanner 吞吐对比（swc/oxc 的接入前提与实测坑见 [architecture.md](architecture.md) 的 TODO 一节；esbuild 未开工）
- [x] 架构矩阵与 CI：`src/variants/` 多架构共存（scalar / jump_vec / two_phase）+ push 自动差分门禁 + 矩阵基准 + 趋势页（见 [architecture.md](architecture.md)）
