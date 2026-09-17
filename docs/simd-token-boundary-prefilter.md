# JS/TS SIMD Token 分界粗筛

## 目标与输出

输入是 UTF-8 编码的 JS、JSX、TS 或 TSX 字节流。一次顺序扫描同时产生两个
bit plane：

- `boundaryPlane`：bit `i` 表示字节 `i` 之后仍可能是 token 分界。
- `lineBreakPlane`：bit `i` 表示一个逻辑换行序列结束于字节 `i`。

对于相邻字节：

```text
... prev | next ...
```

粗筛只提前排除确定不需要交给完整 lexer 的位置。它不解析字符串、模板、
正则、注释、JSX 或 TypeScript 上下文，也不直接产生最终 token stream。

`boundaryPlane` 和 `lineBreakPlane` 语义独立，但应在同一个 SIMD kernel 中
计算，以共享输入加载、UTF-8 分类和跨块状态。

## 假设与正确性

1. 输入是合法 UTF-8。
2. 默认只要求正确处理合法 JS/JSX/TS/TSX。
3. `number/identifier` 相邻等词法错误不约束粗筛。
4. 正则字面量等后续必然完整扫描的 token，可以回填其真实边界。
5. TypeScript 类型的前导 `|`、`&` 可由恢复阶段处理或规范化掉。

在没有恢复机制的普通位置，粗筛只能少排除，不能误排除：

```text
少排除 -> 增加后续 lexer 工作量，结果仍正确
误排除 -> 删除真实 token 分界，结果错误
```

若某类边界由后续阶段保证恢复：

```c
finalBoundary = coarseBoundary | recoveredBoundary;
```

## 四位连接关系

分类描述的是字节在边界关系中的行为，而不是 ECMAScript token kind。一个
字节可以同时具有多个属性。

定义四种连接原因：

```text
ID  = 1 << 0
OP  = 1 << 1
ESC = 1 << 2
WS  = 1 << 3
```

每个字节产生两个逻辑 mask：

- `afterMask(c)`：`c` 之后要求继续连接的原因。
- `beforeMask(c)`：`c` 之前能够承接连接的原因。

边界确定不可切分，当且仅当：

```c
impossible(prev, next) =
    (afterMask(prev) & beforeMask(next)) != 0;
```

四位的含义是：

```text
ID : ID-like 字符之间及 UTF-8 码点内部不能切分
OP : 多字节 punctuator、运算符或注释起始不能切分
ESC: 反斜杠不能作为 token end
WS : 连续 ECMAScript whitespace 合并为一个 trivia token
```

### ASCII 关系

```text
ID after/before : [A-Za-z0-9_$]
OP after        : %^&|*/<=?
OP before       : =&|*?
ESC after       : \
WS after/before : 空格、\t-\r
```

所有字节的 `beforeMask` 都包含 `ESC`。这样反斜杠后的任意位置都会命中
`ESC`，无需为后继字节分类。

`OP` 的 after/before 集合有意不对称，覆盖：

```text
%= ^= &= |= *= /= <= ==
&& || ** ??
/*
```

它还会排除 `%&`、`^*`、`&|`、`?=` 等错误源码中的位置。合法源码假设允许
这种额外排除。它也可能排除正则字面量结束 `/` 后的真实分界，该分界由后续
必经的正则扫描回填。

`+`、`-` 不能加入共享关系，因为以下合法源码存在真实分界：

```js
a+-b
a*-b
a+++b
a--*b
```

不同语言模式允许使用不同 `OP` 集合；`op_cont_audit.js` 用合法样本分别审计
JS、JSX、TS 和 TSX。

## UTF-8 与 Unicode whitespace

### ID-like 策略

合法 UTF-8 中的非 ASCII 码点分为：

1. ECMAScript whitespace。
2. 其余码点，统一视为 `ID-like`。

`ID-like` 不表示码点一定满足 Unicode `ID_Continue`，只表示粗筛行为相同：

- `ID_Continue` 码点可以属于 identifier。
- 其他非 whitespace 码点若出现在合法源码中，只能位于字符串、模板、正则、
  注释或 JSX text 等已有 token 内。

因此它们都不能在与相邻 `ID-like` 字符之间切分。若要精确恢复非法源码，
必须改用完整 Unicode identifier 分类。

对于多字节 UTF-8 码点：

```text
首字节 | 中间字节 | 末字节
```

- 所有非末字节设置 `afterMask |= ID`。
- 所有非首字节设置 `beforeMask |= ID`。
- 非 whitespace 首字节额外设置 `beforeMask |= ID`。
- 非 whitespace 末字节额外设置 `afterMask |= ID`。
- whitespace 首、末字节分别设置 `beforeMask/afterMask |= WS`。

前两条利用合法 UTF-8 的结构：非末字节之后必然是同一码点的 continuation
byte，因此码点内部也可以复用 `ID`。

### Whitespace 例外

本文将 ECMAScript 词法文法中的 `WhiteSpace` 和 `LineTerminator` 合称为
whitespace。非 ASCII 并集是：

```text
U+00A0
U+1680
U+2000..U+200A
U+2028
U+2029
U+202F
U+205F
U+3000
U+FEFF
```

ECMAScript 的 `WhiteSpace` 引入的是 General Category 为
`Space_Separator (Zs)` 的码点，而不是 Unicode `White_Space=Yes` 的全部
码点，并另外显式包含 `U+FEFF`；`LineTerminator` 单独包含 `U+2028` 和
`U+2029`。

所以：

- `U+0085` 的 `White_Space=Yes`，但类别是 `Cc`，不属于 ECMAScript
  `WhiteSpace` 或 `LineTerminator`。
- `U+FEFF` 的 `White_Space=No`，但被 ECMAScript 显式视为 `WhiteSpace`。

规范定义见 [ECMAScript White Space][ecma-white-space]。

[ecma-white-space]: https://tc39.es/ecma262/multipage/ecmascript-language-lexical-grammar.html#sec-white-space

合法源码只需识别上述 19 个非 ASCII whitespace。Unicode 17.0.0 下，可直接
确定为非 whitespace 的 UTF-8 首字节有：

```text
C3-DF
E0
E4-EE
F0-F4
```

只需继续检查这些首字节：

```text
C2 E1 E2 E3 EF
```

对于三字节序列，检查第二字节后仅剩这些可能形成 whitespace 的前缀：

```text
E1 9A
E2 80
E2 81
E3 80
EF BB
```

完整集合和 Unicode 版本由 `unicode_utf8_prefixes.js` 验证。

## 推荐的 fused kernel

### 不物化分类数组

不要先把整个输入转换为分类字节数组，再进行第二遍 boundary 扫描。这样会
额外写入并读回每个输入字节，通常比分类本身更贵。

推荐在一个 block 内即时分类并立即合成结果：

```c
bytes = load(input);

idAfter, idBefore = classifyId(bytes);
opAfter, opBefore = classifyOp(bytes);
wsAfter, wsBefore = classifyWhitespace(bytes);
esc = bytes == '\\';

impossible =
    (idAfter & shiftNext(idBefore))
  | (opAfter & shiftNext(opBefore))
  | (wsAfter & shiftNext(wsBefore))
  | esc;

boundaryPlane = bitpack(~impossible);
lineBreakPlane = bitpack(classifyLineBreak(bytes));
```

上述属性保持为每 lane `0x00/0xff` 的布尔向量，先在向量内完成组合，最后
只压缩一次 `boundaryPlane`。若先分别提取多个属性 bit plane，再做标量组合，
x86 会增加 `movemask`，NEON 上的代价更高。

### ASCII 分类

`ID` 和 `WS` 都适合直接范围比较：

```c
folded = byte | 0x20;
alpha = folded >= 'a' && folded <= 'z';
digit = byte >= '0' && byte <= '9';
id = alpha | digit | byte == '_' | byte == '$';

ws = byte == ' ' || (byte >= 0x09 && byte <= 0x0d);
esc = byte == '\\';
```

`OP` 集合不规则，是最适合优先尝试 nibble LUT 的部分。是否用 LUT 处理
`ID`、`WS`，应由实际指令数和目标 CPU 上的 shuffle 吞吐决定。

### Unicode 快路径

可以先把所有 `>= 0x80` 的字节视为 `ID before/after`。这已经正确覆盖：

- UTF-8 码点内部。
- 非 whitespace Unicode 码点之间。
- Unicode ID-like 与 ASCII identifier 之间。

然后只修正 19 个 Unicode whitespace：

- 首字节清除 `ID_BEFORE`，设置 `WS_BEFORE`。
- 末字节清除 `ID_AFTER`，设置 `WS_AFTER`。
- 中间字节保持 `ID`，继续排除码点内部边界。

实际快路径甚至无需检测所有高位字节，只需检测是否出现：

```text
C2 E1 E2 E3 EF
```

若一个 block 没有这些首字节，就不需要执行 Unicode whitespace 修正。中文
等常见非 ASCII 源码多数也能直接通过该路径。

### 换行 plane

换行是单个码点或序列属性，不应并入 `ID/OP/ESC/WS` 的连接关系；但应在同一
kernel 中计算。

建议每个逻辑换行只设置一个 bit，并标记在序列末字节：

```c
lf = byte == '\n';
loneCr = byte == '\r' && nextByte != '\n';
unicode = currentSequence == U+2028 || currentSequence == U+2029;

lineBreak = lf | loneCr | unicodeFinalByte;
```

这样 `CRLF` 只在 `LF` 位置置位，`U+2028/U+2029` 在 UTF-8 末字节置位。
`lineStartPlane` 可由 `lineBreakPlane` 左移一位并加入文件首位得到。

### 可选 packed tag

若 LUT 能直接产生分类结果，可以用一个临时字节同时保存关系与换行信息：

```text
bit 0: ID_AFTER
bit 1: OP_AFTER
bit 2: WS_AFTER
bit 3: ID_BEFORE
bit 4: OP_BEFORE
bit 5: WS_BEFORE
bit 6: ESC_AFTER
bit 7: LINE_BREAK
```

`ESC_BEFORE` 恒为真，不必存入每个字节。对相邻 tag：

```c
next = shiftNext(tags);
joined = (tags & 0x07) & ((next >> 3) & 0x07);
impossible = joined != 0 || (tags & 0x40) != 0;
```

如果分类本身由比较产生，把布尔向量打包成 tag 后再拆开通常没有收益。packed
tag 只在 LUT 能以很少的 shuffle 直接生成它时值得使用。

## Nibble LUT

### 基本形式

将一个字节拆成：

```c
hi = byte >> 4;
lo = byte & 0x0f;
```

最便宜的通用 SIMD 形式是：

```c
tag = shuffle(hiTable, hi) & shuffle(loTable, lo);
```

SSSE3/AVX2 可使用 `pshufb`，NEON 可使用 `tbl`，Wasm SIMD 可使用
`swizzle`。两张 16 项表能驻留寄存器，不产生逐字节数据依赖加载。

### 矩形约束

对于 tag 中的每个 bit，上式能直接表示的成员集合是：

```text
允许的 hi 集合 × 允许的 lo 集合
```

即 16×16 nibble 平面上的一个布尔矩形。若一个属性是多个矩形的并集，就需要：

- 为不同矩形分配临时 bit，再归并为最终属性；或
- 增加第二组 shuffle；或
- 接受可证明安全的近似。

已删除的旧 nibble 分类实验使用“成员出现过的 hi 与 lo 分别取并集”的方法。
它保证不漏掉属性成员，却会把矩形内的非成员误判成成员。这个方向不能直接
用于 `impossible`：属性误报可能删除真实边界。

允许近似时，约束必须施加在最终关系上，而不是单个字符属性上：

```c
classifiedAfter(prev) & classifiedBefore(next)
```

新增的属性成员只有在以下情况才安全：

1. 产生的额外字节对在合法源码中不可能形成真实边界；或
2. 该边界由后续扫描保证回填。

因此 nibble 表搜索应直接优化最终 `after × before` 关系，并调用
`op_cont_audit.js` 或更完整的语法样本验证，而不是分别最小化 `ID`、`OP`
等属性的误报。

### 输入变换

对输入位做 permutation，或执行少量 `dstBit ^= srcBit` 的可逆 GF(2) 变换，
可以改变属性在 nibble 平面上的形状，让它更接近少量矩形。

这种变换只有在减少的 shuffle、比较或归并指令多于变换本身时才有价值。
搜索目标应计入：

- 输入变换指令数。
- shuffle 数和依赖深度。
- 临时 tag 的归并指令。
- 最终候选密度与后续 lexer 成本。

旧实验按过时的字符分类分别统计误报，结论不能直接用于当前四位关系；保留
的方法论是“搜索变换 + 矩形分解”，而不是当时生成的具体表。

## SIMD 对齐与 bitpack

设向量宽度为 `W` 个字节。分类阶段产生：

```text
after = [afterMask(b0), ..., afterMask(bW-1)]
before = [beforeMask(b0), ..., beforeMask(bW-1)]
```

将 `before` 向前错位一个字节：

```text
beforeNext = [beforeMask(b1), ..., beforeMask(bW)]
```

然后逐 lane 计算：

```c
joined = after & beforeNext;
impossible = joined != 0;
candidate = !impossible;
```

这些操作不依赖特定 SIMD：

- x86 使用 SSE、AVX2 或 AVX-512。
- ARM 使用 NEON `vext`。
- WebAssembly SIMD 使用 byte shuffle。
- 可变长度 SIMD 使用 slide。

如果后续阶段可直接消费向量布尔 mask，就不必立即压成标量 bitset。必须输出
bit plane 时：

- x86 mask 寄存器或 `movemask` 可直接提取。
- NEON 可将 `0x00/0xff` lane 转成 `0/1`，乘以
  `[1,2,4,8,16,32,64,128]` 后按八 lane 水平求和。
- 也可先存储布尔向量，统一执行独立的 bitpack 阶段；是否更快取决于消费者
  和写带宽。

每块最后一个 lane 需要下一块第一个字节的 `beforeMask`。可保留下一块分类、
从 `input + 1` 错位加载，或保存一个字节的块间状态。UTF-8 whitespace 和
`U+2028/U+2029` 检测还需要最多两个前序字节。

文件最后一个字节之后没有 `next`，对应 boundary bit 应屏蔽。

## Whitespace token 与并行切块

连续 ECMAScript whitespace 在最终 token stream 中可合并为一个 trivia
token，因此相邻 whitespace 之间设置 `WS`：

```text
let····x
   ^^^
   whitespace token 内部
```

该 token 必须保留 `containsLineTerminator`；若要计算源码位置，还需保留原始
span，或记录换行数量和最后一行长度。

Token 分界和并行切块点不是同一概念。若允许汇合时合并跨块 trivia，则已确认
处于普通代码状态的 whitespace run 内部仍可作为并行切点：

```text
chunk A ... tokenA············tokenB ... chunk B
                            ^
                         并行切点
```

因此可按用途选择：

1. 生成合并 whitespace 的 token stream：让 `WS` 参与 `impossible`。
2. 寻找并行切点：忽略 `WS`，或额外输出 `whitespacePlane`。

字符串、模板、正则和注释中的空格不能仅凭字节分类视为安全切点。

## 实现候选与基准

建议按以下顺序实现：

1. **直接谓词 + OP nibble LUT**：最可能成为 SSE/AVX2/NEON/Wasm 的共同
   基线。
2. **少量 nibble shuffle 直接生成 packed tag**：若关系搜索能找到安全表，
   可能成为最快方案。
3. **完整 byte LUT**：作为标量 fallback；仅在支持高效宽 byte lookup 的
   ISA 上评估专用 SIMD 版本。
4. **物化分类数组后再扫描**：除非分类还被多个阶段复用，否则通常最慢。

完整 256 项 LUT 在标量代码中简单且常驻 L1，但 AVX2 没有 byte gather；
NEON `tbl`、AVX-512 byte permute 的能力和吞吐也不同，因此不存在不经测量就
能确认的跨平台唯一最优实现。

需要分别测量：

- 初始化成本：表构造应在构建期完成，运行时只加载常量。
- 稳态吞吐：cycles/byte、GB/s，并包含 bit plane 写出。
- ASCII identifier 密集、格式化代码、minified 代码、运算符密集、中文、
  Unicode whitespace 等不同样本。
- 纯粗筛成本和包含后续候选验证的端到端成本。

总成本近似为：

```text
粗筛成本 + 候选数量 × 后续验证成本
```

因此更快但保留更多候选的近似分类，不一定有更好的端到端性能。

## 辅助脚本

- `op_cont_audit.js`：按 JS、JSX、TS、TSX 模式搜索 `OP` 关系反例。
- `unicode_utf8_prefixes.js`：根据指定 Unicode 版本验证 UTF-8 前缀和
  ECMAScript whitespace 例外。
