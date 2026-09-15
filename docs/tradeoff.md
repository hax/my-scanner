# Tradeoff 登记表

### 有意近似（主动选择的偏差）

| # | 输入形态 | my-scanner 行为 | spec/tsc 行为 | 为何可接受 |
| --- | --- | --- | --- | --- |
| T1 | `)` `]` `}` 后以 `/` 开头的正则字面量语句（`if (x) /re/.test(y)`） | `)`/`]` 后判除号；`}` 后判正则 | parser 按语法位置精确判定 | 单 token 回看启发式（[scanner.zig](../src/scanner.zig) `regexAllowedAfter`）：`}` 后是块尾新语句的常见形态；`)` 后接正则语句、`}` 后接对象除法在真实代码里几乎不出现 |
| T2 | 合法标识符后裸贴非 ID_Continue、非空白的 unicode 字符（`变量☃ = 1`，本身是非法 JS） | 非空白非 ASCII 字节一律按 ID-like 相互连接（boundary v2 设计），☃ 整个被越过，token 流中消失（孤立出现的 ☃ 仍正常产 `illegal`）；单阶段变体（scalar/jump_vec）无候选合成，对该形态产 `illegal`（更接近 tsc 的 error token） | tsc 产 error token | 阶段 1 无上下文，精确剔除需付出额外分类平面；「只保证合法源码」假设下的已知容错差异（[simd.zig](../src/simd.zig) boundary v2 注释） |
| T3 | `\u{41}` 形式的标识符转义 | 拆成普通 token（`\` 为 illegal），不合并 | spec 视为合法转义；tsc **纯 scanner** 同样不合并，parser 层恢复 | 对齐 tsc 纯 scanner 口径，四进制 `\uXXXX` 已完整支持（[scanner.zig](../src/scanner.zig) `decodeIdentEscape`） |
| T4 | 数字尾部非法 `_` 分隔符（`123_`） | 连同尾部 `_` 一起并入 number token，无错误标记 | tsc 报 numeric separator 错误 | token 边界与 tsc 一致，仅缺语义标记；非法代码 |

### 已知限制（已知、触发极罕见、暂不修）

| # | 输入形态 | 现状 | 期望行为 | 备注 |
| --- | --- | --- | --- | ---|
| L2 | 字符串行继续 + CRLF 行尾（`"...\` + `\r\n`） | `\`+CRLF 只跳过 `\r`，随后的 `\n` 被当裸换行，合法字符串被截断为 illegal | `\`+CRLF 是合法 LineContinuation | LF 行尾的行继续正常；待修 bug（非 tradeoff），代码内有 TODO |
| L3 | legacy 八进制 `0755`、非法数字-标识符邻接 `3in`、空十六进制 `0x`、指数无数字 `1.e` | 均按容错策略产出边界近似合理的 token（`0755` 整体为 number、`3in` 拆成 number+keyword），无语义错误标记 | tsc 记错误 flag 并报诊断 | 「不产错误诊断」非目标（见 [goals.md](goals.md)）的直接结果；token 边界基本一致 |

### 维护说明

- 登记条目引用代码内注释的行号会漂移，以符号名（函数/设计名）为准。
- 修复某个已知限制后，把对应条目从登记表移除并在
  [roadmap.md](roadmap.md) 留一条记录。
