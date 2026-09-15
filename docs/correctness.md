# 正确性验证与已知差距

正确性以 tsc 的 scanner（`ts.createScanner`）为参考实现做 token 级
差分。与 spec 的**有意偏差**（近似判定、容错取舍）不在本文展开，
登记在 [tradeoff.md](tradeoff.md)（政策见 [goals.md](goals.md)）；
本文只谈验证机制与口径。

## 四层防线

`scripts/check.sh` 一键跑前两层（全部架构变体 × 全部语料）：

1. **单元测试**（~50 个）：token 化各路径 + SIMD 块边界 + Unicode 边界
   （跨块码点、悬挂尾部、CRLF、U+2028）+ 防回归用例（历史上被随机
   验证抓回的分支各有专属用例）。
2. **tsc 差分**：[compare-tsc.mjs](../tools/compare-tsc.mjs) 把 tsc 的
   scanner 当参考实现做 token 级差分——切分（字节偏移）对齐为主、
   语义分类从宽。**七个语料**全部对齐、零分类硬差异：

   | 文件 | tokens | 特征 |
   | --- | --- | --- |
   | typescript.js | 1,122,439 | bundled tsc（minified 高密度） |
   | checker.ts | 348,152 | tsc 源码 |
   | lib.dom.d.ts | 116,895 | JSDoc 块注释密集 |
   | react.js | 8,411 | 短文件 |
   | cn-dense.ts | 88,002 | 中文注释/标识符密集 |
   | line-comments.js | 90,002 | 行注释 + URL 密集 |
   | strings.js | 84,002 | 字符串/模板密集 |

   ```sh
   cd tools && npm i && cd ..
   node tools/compare-tsc.mjs corpus/*.js corpus/*.ts   # 加 --variant=NAME 可指定变体
   ```
3. **标量随机交叉验证**：`classifyTokenStartsScalar`（逐码点状态机）与
   SIMD 版在 200 轮确定性随机字节流上**逐位一致**（masks/line_breaks/
   newlines）。曾抓出 SIMD 版三个跨块边界 bug 与一次清理误删的分支。
4. **OP 集合审计**：[op_cont_audit.js](op_cont_audit.js) 按 JS/JSX/TS/TSX
   四模式对边界连接关系做反例搜索（现役集合 0 反例）。

## 与 tsc 的口径差异（设计分歧，非谁对谁错）

以下差异源于「tsc 把重扫推迟给 parser」的设计，差分对比时按下述口径
归一：

- tsc 按 UTF-16 code unit 计偏移，my-scanner 按字节计（对比时按
  latin1 喂入统一坐标系）。
- tsc 永不合并 `>` 家族（`>>` `>=` `>>>=`），由 parser
  `reScanGreaterToken` 合并——泛型 `A<B<C>>` 的需要。
- tsc 对 `/` 保守判除号，由 parser `reScanSlashToken` 重扫为正则
  （正则体内相邻的 `//` 在保守路径会被当成行注释）。
- 模板字面量 tsc 拆成 Head/Middle/Tail，模板字符串类型
  （`` `${string}` ``）纯 scanner 甚至不续扫；这两类整体边界以
  my-scanner 为准同步，其内部逻辑由单元测试保证。
- 转义出的关键字（`\u0069f`）我们产 identifier 而 tsc 产 keyword
  ——差分 soft 类别。
- `\u{...}` 形式标识符转义不合并——对齐 tsc 纯 scanner（属设计口径，
  与 tradeoff.md 的 T3 是同一条的两面）。

## 已支持

- 标识符 / 关键字（含 let、static、async、of 等上下文关键字的提示性归类）
- unicode 标识符：ID_Start/ID_Continue 范围表（tools/gen_unicode_tables.mjs
  从 UCD 生成，Unicode 17.0.0，682/795 范围二分）+ 严格 UTF-8 解码，
  混排续扫、unicode 私有名 `#π`、ZWNJ/ZWJ；`\uXXXX` 转义标识符
  （含转义 `$`/`_`）
- 数字：十/十六/八/二进制、小数、指数、`_` 分隔符、BigInt `n` 后缀
- 字符串（单双引号、转义、行继续）、模板字面量（跨行、`${}` 子表达式
  平衡扫描，已感知嵌套模板 / 行块注释 / 字符串）
- 正则字面量（基于前一 token 的近似判别，处理 `/` 的除号/正则二义性）
- 全部 punctuator（含 `>>>=` `??=` `?.` `...` 等最长匹配与 `?...`
  歧义排除）
- 行/块注释、shebang、私有名 `#x`
- token 行号：`Result.lines`（LineIndex，逻辑换行位图 + 前缀和，O(1)
  `lineAt(offset)`；列号可由消费方从行首 offset 推导）
- 容错：非法字节/未闭合字面量/坏 UTF-8 产出 `illegal` token 而不是
  中断（目标特性，见 [goals.md](goals.md)）

## 已知差距

完整的行为偏差登记见 [tradeoff.md](tradeoff.md) 登记表。此处只列计划内的
正确性 TODO：

- 模板子表达式递归调 scanner 本体（根治 L1：子表达式内正则的 `}`）
- 字符串行继续 + CRLF 截断（L2，待修 bug）
- `}` 之后的正则/除法歧义，花括号栈精确判定（当前为单 token 回看
  启发式，见 T1）
- 对齐 Test262 / 真实大型 JS 代码库的模糊正确性验证
