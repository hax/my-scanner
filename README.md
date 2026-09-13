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

## 现状

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

- [ ] 吞吐优化：token 批量产出、关键字识别去 hash 化、错误路径冷热分离
- [ ] 宽度实验：block_size = 16 / 32 / 64（AVX-512）横评
- [ ] 标量 baseline + 各 SIMD 化子阶段单独 A/B 计量（把"每个环节拿到多少"量化出来）
- [ ] unicode 标识符与 `\u` 转义
- [ ] 模板子表达式递归调 scanner 本体
- [ ] token 行列号（SIMD 行计数已就绪）
- [ ] 对齐 Test262 / 真实大型 JS 代码库的模糊正确性验证
- [ ] 与 esbuild / swc / oxc 的 scanner 吞吐对比

## License

MIT
