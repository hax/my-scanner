# 类别码分发与 SIMD 查表分类：讨论纪要与调研

本文档整理围绕「字节分类 → 类别码 → token 分发」这条线的讨论、源码调研、
实测数据和后续计划。状态标注：✅ 已落地 / 🔬 调研结论 / 📋 计划中 / ❌ 已否决。

**与 [simd-token-boundary-prefilter.md](simd-token-boundary-prefilter.md)
的分工**：那篇是**模型层**——用四位连接关系（ID/OP/ESC/WS 的
after×before）定义更精确的 token 边界粗筛，并给出 Unicode 完备性设计；
本文是**实现层**——字节分类与分发的高效实现（查表手法、dispatch 表）。
两篇在中间汇合：四位关系需要六个以上位平面，正是 SIMD 查表（全表 LUT /
packed tag）收益翻正的前提条件。

## 背景：两阶段架构现状

scanner 是 simdjson 式两阶段（详见 README）：

- **阶段 1（分类 pass）**：一次 SIMD 扫描，从两个位平面（空白、标识符字符）
  纯位运算推出 token 候选起点掩码
  `candidate[i] = !ws[i] & !(ident_part[i] & ident_part[i-1])`，
  顺带 popcount 全文件换行数。实测吞吐 7.2-7.8 GB/s。
- **阶段 2（token 化）**：块内 `m &= m-1` 迭代候选位，tokenAt 按首字节
  分发贪心消费；token 区间内的假候选用 `start < pos` 越过。

实测（M2，bench 的 `cls` 行常设输出）分类 pass 占总扫描时间随 token 密度
反向变化：typescript.js 8-9%、lib.dom.d.ts 15-18%。**此前 README 里 "~5%"
是指令周期纸面估算，已被实测修正。**

## ✅ 类别码分发（已落地，+20~43%）

阶段 2 原来用字符 range switch 分发；现改为 comptime 生成的 256 项标量
dispatch 表（`src/scanner.zig` 的 `Dispatch` + `dispatch_table`），
每个首字节一个位集：`punct_single / quote / digit / ident_start /
punct_multi / slash / hash`。

关键副产品是 **punct_single 零调用快路径**：语料里 94-98% 的 punctuator
是单字节（`{}();,:~@`），命中位后直接内联构造 token，跳过 punctLen。
多字节 punct（`==` `===` 等，占 punct 的 2-6%）走 `punctLenW`——
候选点一次 4 字节 load + 首字符 switch + 常量比较贪心（SWAR 风格单点匹配），
其总成本只占 ~1%，SIMD 批量化收益上限锁死，❌ 不做。

结果：四文件全面反超 yuku 1.16-1.40x，项目累计 ~3x。

**实现教训**：Zig 的 `'a'..'z'` 是半开区间，第一版 dispatch 表漏了
`z`/`Z`/`9`（全掉进 illegal），被测试当场抓住——comptime 表要用显式
字符集合构造。

## 🔬 SIMD 查表手法调研

「能不能用查表替代平面合成做分类」讨论中梳理了四种手法。核心认知：
**SIMD 里没有「查表」指令，只有「洗牌」指令**（x86 `pshufb` / ARM `tbl`）——
把数据字节当位置用，洗牌就变成 16 路并行查 16 项小表。

### 手法一：nibble 十字 AND 分解（❌ 对我们不可行）

把字节拆高低 nibble 各查一张 16 项表，AND 合并。这是 simdjson **论文时代**
的描述。数学条件苛刻：共享 bit 的字符组不能有「十字洞」。反例（我们的
punct 集合）：`!`(0x21) punct、`1`(0x31) 非 punct、`<`(0x3c) punct——
低表[1] 与高表[3] 的组合无法自洽。**对 packed 多类别码（每类一个 bit、
多字符共享 bit）同样不可行**：`1` 会被 AND 出 punct+digit。

boundary-prefilter 文档把这推广为**矩形约束**：十字 AND 能表示的集合
= nibble 平面上的布尔矩形（hi 集合 × lo 集合），多矩形并集需要多组
shuffle 或临时 bit 归并；并进一步提出对输入位做 GF(2) 可逆变换搜索
更接近矩形的属性形状——比手工构造表更系统的方向。

（勘误：本讨论早期曾把 simdjson 现行实现误述为十字 AND，源码调研后纠正，
见手法二。）

### 手法二：nibble 查表定期望 + 比较验证（simdjson 现行实现）✨

源码调研结论（`src/westmere.cpp` / `src/arm64.cpp`）：

```cpp
// x86：低 nibble 查出「期望字符」，与实际字节比较
whitespace_table = [' ', 100, ..., '\t', '\n', ..., '\r', ...];
                 //  lo:0→' '  9→'\t'  A→'\n'  D→'\r'
whitespace = in.eq( pshufb(whitespace_table, in) );
```

- 假阳性需要「低 nibble 相同**且**字节值相同」= 字符本身 → **零假阳性**，
  前提仅是**集合内字符低 nibble 互不冲突**（每桶一个期望字符）。
- JSON 空白 {20,09,0A,0D} 的 lo = {0,9,A,D} 互异 → **2 条指令检测 4 字符**。
- arm64 更妙：`vqtbx` 越界保留默认值语义，把 space 的 cmpeq 融进查表
  同一条指令。
- nibble 冲突的集合（JSON 的 `,:[ ]{ }`——`[`/`{` 同 B 桶）：先 `| 0x20`
  归一化压桶，接受 `<FF>`/`<SUB>` 等罕见控制字符的假阳性，由 stage 2
  兜底——有意识的工程取舍。

**开销：每 16 字节 2 条指令**（pshufb + pcmpeqb），是全表法的一半以下。

### 手法三：全表段查（256 项任意表）

4× 64 项 `vqtbl4q`（M2 上每条 2 uops）+ 3 级按值选段 ≈ **14 uops/16B**，
与平面合成（~13 uops）基本打平，换来**任意表 + 边际类别免费**
（一次产出完整 8 位类别码，多要类别不多花指令）。

### 手法四：平面合成（现状）

区域类（a-z、0-9）适合范围比较；ws 11 条 + ip 15 条 ≈ 13 uops/16B，
但每多一个类别线性加 ~6-7 条。

### 对比总表（16 字节单位，M2 uops 估算）

| 手法 | 开销 | 产出 | 适用条件 |
| --- | --- | --- | --- |
| 十字 AND | ~6 | 单一可分解集合 | 集合无十字洞（苛刻） |
| 查表+验证 | **~2** | 一个等值字符集 | 集合内 lo nibble 互异 |
| 全表段查 | ~14 | 完整 8 位类别码 | 任意表 |
| 平面合成（现状） | ~13 | 2 个位平面 | 区域类最自然 |

### 我们的集合分析

- **JS 空白 {20,09,0A,0D,0B,0C}**：lo = {0,9,A,D,B,C} **互不冲突** →
  手法二可用，2 条指令替代现在 11 条（6 cmpeq + 5 or），分类 pass 预估
  提速 ~1/3。
- **punct 集合**：lo 冲突多（`[`/`{`/`;` 同 B 桶），十字不可分解；如需
  检测可用归一化+验证或全表法。
- **ident（区域类）**：查表+验证不适用（每桶多字符），维持范围比较。
- **packed 多类别码**：十字 AND 不可行（假阳性共享 bit）；只有全表法。

## 📋 计划

（读完 boundary-prefilter 文档后重排：正确性与 Unicode 地基优先于纯提速。）

1. **第一步：四位连接关系落地（boundary v2）**，见
   simd-token-boundary-prefilter.md。把 `classifyTokenStarts` 的
   candidate 公式升级为 impossible 关系（`afterMask(prev) &
   beforeMask(next)`），新增 ESC/OP 平面与 lineBreakPlane
   （\r\n、U+2028/2029 逻辑换行）。纯 `@Vector` 实现，OP 集合用
   `op_cont_audit.js` 审计过的 `%^&|*/<=?` × `=&|*?`。
   主要收益是正确性与 Unicode 地基（U+00A0 等不再误判 illegal、
   中文码点假候选 3→1 个/字），速度收益预估 <2%。
   注意会**有意改变行为**（非 ASCII whitespace 从 illegal 变 trivia），
   tsc 差分口径同步更新。
2. **第二步：whitespace 平面改「tbl/pshufb 查表+验证」**（手法二），
   2 条指令替代 11 条，预估总吞吐 3-5%。与第一步独立，纯提速项。
   首次引入内联汇编，作为标注例外。
3. **第三步：OP 平面进 nibble LUT + packed tag 评估**。四维关系需要
   ≥6 个位平面（after/before×3 + ESC + 换行），全表 LUT / packed tag
   的翻正条件（类别 ≥4 且消费点 ≥2）在此点亮。用矩形约束框架 +
   GF(2) 变换搜索，`op_cont_audit.js` 验证。
4. **决策规则**：分类 pass 占比 9-18% 且随阶段 2 变快持续上升；
   单独做全表 LUT 收益 ~3-6% 不值得；两份文档合流后（多平面 +
   packed tag 消费）才值得投入。

## ❌ 已否决项存档

- 阶段融合（classify+consume 逐块流水、消灭 masks 数组）：实测 -3~12%，
  两阶段分离的缓存行为更好（线性 SIMD 扫 + L1 驻留 mask 数组）。
- 物化 codes[] 分类数组再做第二遍边界扫描：boundary-prefilter 文档
  「不物化分类数组」一节与上述实测互相印证（额外写+读每个输入字节，
  通常比分类本身更贵）。
- block_size=16：实测 -9%，块循环开销翻倍高于 NEON 单指令收益。
- 多字节 punct 的 SIMD 批量匹配：多字节 punct 占总时间 ~1%，指令数
  反超标量（十字位逻辑 40-60 条/块 vs 块内 ~1.8 个多字节 punct × 8 周期）。
- 十字 AND 用于我们的任何平面：punct 有十字洞、ws 在十字 AND 框架下
  也有（0x29/0x00 反例）——但手法二（查表+验证）不受此限制。
