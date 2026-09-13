# my-scanner

用 Zig 充分压榨 SIMD，给 JS/TS 做一个尽可能快的词法分析器（scanner/lexer）的实验项目。

## 为什么做这个

simdjson 证明了"结构性跳过"式的向量化能让解析的 I/O 密集阶段快一个数量级，
但主流 JS 工具链（V8、esbuild、swc、oxc）的 scanner 至今仍以逐字节标量循环为主。
这个项目想系统地回答：**JS scanner 的每个环节各能从 SIMD 拿到多少收益，瓶颈最终会停在哪里。**

## SIMD 技巧

所有向量化集中在 [src/simd.zig](src/simd.zig)：用 Zig 的 `@Vector` 表达，
由编译器按目标平台自动降到 AVX2 / NEON，不写 intrinsics。
每个原语返回一个 bitmask（第 i 位 = 第 i 个字节命中），语义由调用方用 `@ctz` / `@popCount` 组合：

| 环节 | 手法 |
| --- | --- |
| 跳空白 | 32 字节空白掩码 + `@ctz(~mask)` 定位第一个非空白；整块全空白时 `@popCount` 批量数换行 |
| 标识符 | 范围比较合成 `[A-Za-z0-9_$]` 掩码，`@ctz(~mask)` 直接得到结尾偏移 |
| 字符串 / 模板 | 掩码定位 `引号 \| 反斜杠 \| 换行`，转义对直接跳 2 字节；模板另加 `$`（`${`）|
| 块注释 | `slash_mask & (star_mask << 1)` 一条位逻辑同时探测 32 个位置的 `*/`，跨块用 carry 位衔接 |
| 行数统计 | `@popCount(newline_mask)`，注释 / 模板跨行批量计数 |

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

M2 / ReleaseFast / 10 轮取最优：

| 文件 | my-scanner | yuku | mine/yuku |
| --- | --- | --- | --- |
| typescript.js | 0.25 GB/s · 34.1 Mtok/s | 0.56 GB/s · 77.3 Mtok/s | 0.44x |
| checker.ts | 0.30 GB/s · 33.9 Mtok/s | 0.63 GB/s · 70.6 Mtok/s | 0.48x |
| react.js | 0.35 GB/s · 40.9 Mtok/s | 0.90 GB/s · 104.9 Mtok/s | 0.39x |
| lib.dom.d.ts | 0.59 GB/s · 36.8 Mtok/s | 1.02 GB/s · 63.9 Mtok/s | 0.58x |

yuku 的成熟实现目前快约 2 倍——这正是起步骨架的优化空间量化，见 roadmap。

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

- [ ] 吞吐优化：token 批量产出、关键字识别去 hash 化、错误路径冷热分离（对标 yuku：当前 0.44-0.58x）
- [ ] 宽度实验：block_size = 16 / 32 / 64（AVX-512）横评
- [ ] 标量 baseline + 各 SIMD 化子阶段单独 A/B 计量（把"每个环节拿到多少"量化出来）
- [ ] unicode 标识符与 `\u` 转义
- [ ] 模板子表达式递归调 scanner 本体
- [ ] token 行列号（SIMD 行计数已就绪）
- [ ] 对齐 Test262 / 真实大型 JS 代码库的模糊正确性验证
- [ ] 与 esbuild / swc / oxc 的 scanner 吞吐对比

## License

MIT
