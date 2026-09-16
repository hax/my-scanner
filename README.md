# my-scanner

用 Zig 语言写的 JS/TS 词法器，探索如何利用 SIMD 提升性能。

## 目标

simdjson 证明「结构性跳过」式的向量化能让解析的 I/O 密集阶段快一个数量级，但主流 JS/TS 工具链的词法解析至今仍以逐字节标量循环为主。本项目探索 JS/TS词法解析如何利用 SIMD 拿到收益，瓶颈在哪里。项目同时保持多个架构不同的实现，对比这些架构在不同语料上的性能表现和原因，探索通用的优化策略或混合策略。

核心目标是将字节流转化为 token 流的整体效率，token 合法性的验证留给 parser、linter 等按需开启或自行处理。为追求性能和容错，可以做合理取舍，比如实践中罕见的 token 排列可由 parser 发起重扫描或二次切分，对错误输入可以给出不符合 spec 的切分结果。详见 [docs/goals](docs/goals.md)。当前的具体取舍见 [docs/tradeoff](docs/tradeoff.md)。

## 架构

项目以**架构矩阵**方式并行演化：`src/variants/` 下多个架构共享语义层、各自优化，每次 push 到 main 由 CI 自动跑全变体差分门禁 + 矩阵基准，趋势归档 bench-reports 分支。详见 [docs/architecture](docs/architecture.md)。当前三个并行变体：

- `scalar`：全标量单阶段，逐字节决策，作为基线参照（对应 yuku-old 形态）。
- `jump_vec`：单阶段 + SIMD 长跳跃（空白块扫、注释 trivia 快跳），当前 9/10 语料为矩阵最快、真实语料几何平均追平 yuku-main。
- `two_phase`：阶段 1 纯 SIMD 无分支地为每个字节建立分类位平面，推导 token 候选起点位图（换行统计同趟完成）；阶段 2 `@ctz` 迭代候选起点，按首字节类别码分发贪心消费。

所有向量化集中在 [src/simd.zig](src/simd.zig)，用 Zig `@Vector` 表达、编译器自动降到 AVX2 / NEON，不写 intrinsics。

## 用法

```sh
zig build test                        # 跑测试
zig build run -- src/scanner.zig      # 扫描文件，输出统计
zig build run -- --dump some.js       # 打印每个 token（含行号）
zig build --release=fast run -- --bench=50 big.js   # 吞吐基准
scripts/check.sh                      # 正确性门禁（全变体 tsc 差分）
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

## License

MIT
