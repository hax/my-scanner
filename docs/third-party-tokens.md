# 三方 lexer token 产出设计对比

本文调研五家 JS/TS lexer 的 token 产出设计：数据结构、token 种类、附带
数据、位置记录、交付形式、重扫 API。目的是为 my-scanner 的 token 模型
演进（parser 接口预备）提供参照系。结论均附源码引用；与 tsc 的切分口径
差异（`>` 合并与否等）不在本文范围，见 [correctness.md](correctness.md)。

## 对象与版本锚点

| 对象 | 版本 | 源码位置 | 本仓角色 |
| --- | --- | --- | --- |
| TypeScript tsc scanner | tools 依赖 | `tools/node_modules/typescript/lib/typescript.js`（下文 ts.js）与 `typescript.d.ts`（下文 d.ts） | 正确性校验基准 |
| yuku | v0.10.1（钉）/ main（跟踪），两版 `src/parser/token.zig` 字节级相同 | `.bench-deps/yuku/src/parser/`（下文 token.zig / lexer.zig / parser.zig / ast.zig） | 速度基线（scalar / jump_vec 同族参照） |
| swc | swc_ecma_parser（`unstable` feature；版本自动跟踪 crates.io 最新版） | cargo registry，下文 `$REG/` = `~/.cargo/registry/src/index.crates.io-*/` | jump_vec 族第三方参照 |
| oxc fused lexer | oxc_parser（版本自动跟踪；本文引用写于 0.150.0） | `.bench-deps/oxc_parser/src/`（下文 kind.rs、token.rs、lexer/*.rs 等） | jump_vec 族第三方参照 |
| oxc_lexer（多位图流水线） | 跟踪 oxc main（publish=false 无 crates.io 版本；crate 自身版本串 0.139.0） | `.bench-deps/oxc/crates/oxc_lexer/src/` | two_phase 族第三方参照 |

三方版本由 prepare-lexbench.sh 自动跟踪上游（机制见
[benchmarks.md](benchmarks.md) 的「第三方版本」）；本文的
源码行号引用写于上表所列版本，引用时若已升版需按当前源码复核。

## 一、各家的数据结构

理解 token 产出之前，先看每家"token 到底是个什么结构"。六家的答案
差异很大：从没有 token 对象（tsc），到 16 字节位包结构体（yuku / swc /
oxc fused），到根本没有 token 结构体、只有平行数组（oxc_lexer）。

### tsc：没有 token 结构体，只有一组游标

tsc 的 scanner 就是下面这个东西（ts.js:12114 起；删减过，但骨架、变量
名、行为都来自原代码）：

```js
function createScanner(languageVersion, skipTrivia, ..., text, onError, start, length) {
  // —— “token” 的全部载体：函数局部变量，从不构造任何 token 对象 ——
  var pos;          // scanner 游标 = 当前 token 的终点
  var end;          // 文本终点
  var fullStartPos; // 当前 token 含前导 trivia 的起点
  var tokenStart;   // 当前 token 的本体起点
  var token;        // 当前 token 的 SyntaxKind（359 值大枚举，token 只占 0..166）
  var tokenValue;   // 当前 token 的 cooked 值，恒为 string
  var tokenFlags;   // 当前 token 的 16 位标志

  function scan() {                    // 每调用一次推进一个 token（ts.js:12794）
    fullStartPos = pos;
    tokenFlags = 0;
    while (true) {
      tokenStart = pos;
      if (pos >= end) return token = 1 /* EndOfFileToken */;
      const ch = codePointUnchecked(pos);
      switch (ch) {
        case 10 /* \n */: case 13 /* \r */:
          tokenFlags |= 1 /* PrecedingLineBreak */;
          if (skipTrivia) { pos++; continue; }       // 跳过，不占 token 位
          return token = 4 /* NewLineTrivia */;      // 否则 trivia 也是 token
        case 33 /* ! */:
          if (charCodeUnchecked(pos + 1) === 61 /* = */) {
            if (charCodeUnchecked(pos + 2) === 61) return pos += 3, token = 38 /* !== */;
            return pos += 2, token = 36 /* != */;
          }
          pos++;
          return token = 54 /* ! */;
        case 34 /* " */: case 39 /* ' */:
          tokenValue = scanString();                 // cooked 值写进 slot
          return token = 11 /* StringLiteral */;
        // ……数字、标识符、模板等几十个 case（正则不在这里，见「重扫」一节）
      }
    }
  }

  // 返回值是一袋闭包：调用方能读到的 “token”，就是上面那组变量的当前快照
  return {
    scan,
    getToken:          () => token,
    getTokenStart:     () => tokenStart,
    getTokenEnd:       () => pos,
    getTokenFullStart: () => fullStartPos,
    getTokenText:      () => text.substring(tokenStart, pos),  // raw，现切
    getTokenValue:     () => tokenValue,                       // cooked
    hasPrecedingLineBreak: () => (tokenFlags & 1) !== 0,
    isUnterminated:        () => (tokenFlags & 4) !== 0,
    // ……共约 40 个方法：reScan 系列、setTextPos、lookAhead 等
  };
}
```

读这段代码要注意的点：**每次 `scan()` 都在原地覆盖同一组变量**，所以
"一个 token" 从来不是一份数据，而是这组游标在两次 `scan()` 之间的
瞬时状态。调用方想攒 token 流，必须自己逐轮把值拷出来——本项目
compare-tsc.mjs 的 `grab()` 干的就是这个，而且只拷 `kind + start +
end` 三样：

```js
const scanner = ts.createScanner(99, /*skipTrivia*/ true, 0, text);
const tokens = [];
while (true) {
  const kind = scanner.scan();
  tokens.push({ kind, start: scanner.getTokenStart(), end: scanner.getTokenEnd() });
  if (kind === 1 /* EndOfFileToken */) break;
}
```

也正因为没有 token 对象，这套设计谈不上数组、谈不上分配：
`getTokenText()` / `getTokenValue()` 都是访问时才 substring；位置单位
直接用 JS 字符串的天然坐标——UTF-16 code unit 下标。`tokenFlags` 的
16 个位（`PrecedingLineBreak` / `Unterminated` / `Scientific` /
`ContainsSeparator` / `UnicodeEscape` …，ts.js:6059-6084）同样全局
只有一份，随 `scan()` 重置。前导 trivia 不逐个枚举，但区间
`[fullStartPos, tokenStart)` 就是它的位置；注释的具体范围则要用
`getLeadingCommentRanges` 从原文**再扫一遍**（ts.js:11917-12088）。

### yuku：16 字节 extern Token，kind 值里压着分类位和优先级

```zig
pub const Span = extern struct { start: u32, end: u32 };  // UTF-8 字节偏移（token.zig:468-473）

pub const Token = extern struct {   // token.zig:487-491，comptime 断言恰好 16B
    span: Span,        // 8B
    tag: TokenTag,     // 4B，见下
    flags: u8,         // 4 个标志：line_terminator_before / invalid_escape / escaped / lone_surrogates
    _pad: [3]u8,
};
```

`TokenTag` 是 `enum(u32)`，160 个成员，但枚举值**不是稠密序号**：低 8
位是稠密 id，bits 8-12 压二元优先级，bits 13-21 压分类位
（`IsNumericLiteral` / `IsBinaryOp` / `IsKeyword` / `IsIdentifierLike`
等，token.zig:3-16）。于是 `plus = 15 | (11 << PrecShift) | IsBinaryOp
| IsUnaryOp`，parser 调 `isBinaryOperator()` / `precedence()` 就是一次
位运算，零查表（token.zig:227-278）。

为什么必须是 extern 且恰好 16 字节：token 列表要 `sliceAsBytes` 整块
内存拷贝给 JS/WASM 侧（token.zig:486 注释），JS 拿到的是 accessor 视图
而非对象数组，带掩码的 kind 值原样暴露、零转换。

lexer 本身**零求值**：不 cook 字符串、不算 f64、不 intern，只用 4 个
flag 标记"下游需要加工"；cooked 值和数字值都在 parser/AST 侧惰性计算
（parser.zig:256-289、ast.zig:1402-1427）。注释旁路收进
`ArrayList(Comment)`（仅 `collect_comments` 时），hashbang 既非 token
也非 comment，是 Lexer 上的独立字段（lexer.zig:66）。

**与 tsc 的亲缘**：两家是同一架构族——on-demand 重入状态机、逐 token
产出、默认不留 token 流、reScan 全家桶，连 API 命名都有明显谱系
（`reScanAsRegex` ↔ `reScanSlashToken`、`reScanTemplateContinuation`
↔ `reScanTemplateToken`）。但把 tsc 理解成"yuku 的手工 inline 版"只
对了一半，实质差异有三：(1) yuku 每次返回调用方**拥有**的 16B 值
（可存、可传、可收集成数组），tsc 出借的是下一次 `scan()` 即作废的
游标视图，想要就得自己拷；(2) yuku 零求值，tsc 扫描期就 cook——每个
数字字面量都付一次浮点解析 + toString；(3) UTF-8 字节偏移 vs UTF-16
code unit。tsc 的形态是 JS 的本土化选择（语言没有值类型，逐 token
建对象是 GC 压力，闭包变量 + 访问器是零分配的自然写法）；yuku 是
同一形态在系统语言里的值类型化 + 零求值化。

### swc：kind/value 分离——token 纯 u8，值在 lexer 的单 slot 里

```rust
#[repr(u8)]
pub enum Token { LParen, Plus, Await, Ident, Str, Num, /* ~160 个变体 */ }  // 纯 kind，无 payload

pub struct TokenAndSpan {   // 16B，Copy（$REG/swc_ecma_parser-45.1.3/src/lexer/token.rs:877-883）
    token: Token,           // u8
    had_line_break: bool,   // ASI 用
    span: Span,             // { lo: BytePos, hi: BytePos }
}
```

关键设计：**值不在 token 里**。各 `Token::xxx()` 构造函数在返回 kind 的
同时把值写进 lexer 状态里的单 slot `token_value: Option<TokenValue>`
（token.rs:336-369、state.rs:53）：

```rust
pub enum TokenValue {   // token.rs:14-28
    Word(Atom),                        // ident/JSXName/shebang：interned atom
    Str(Wtf8Atom),                     // cooked 字符串（WTF-8，容忍孤立代理项）
    Template(LexResult<Wtf8Atom>),     // cooked 模板分片；错误直接作为值携带
    JsxText(Wtf8Atom),
    Num(f64),                          // 扫描期即解析
    BigInt(Box<num_bigint::BigInt>),   // 每 token 一次堆分配
    Regex(BytePos),                    // 只存 pattern 的终点 exp_end，不拆 flags
    Error(Error),                      // 词法错误也是一种 token 值
}
```

raw 文本 token 层不存，parser 按 span 用 `read_string` 回切源码补回。
`Span` 的两个端点是 `BytePos(u32)`——**不是文件内相对偏移，而是
SourceMap 的全局绝对偏移**，跨文件唯一、文件之间可能有空隙
（swc_common syntax_pos.rs:24-30），消费方要自管 base（本项目
drive.rs:181-185 就在干这个）。注释完全旁路：`Comments` trait 背后是
`HashMap<BytePos, Vec<Comment>>` leading/trailing 两张表；传 `None` 时
注释连切片都不切（mod.rs:816）。

这套设计自称 "non-strict for higher performance"（lib.rs:173-175）：
热路径上流动的 `TokenAndSpan` 是 16 字节 Copy 结构，没有 enum payload
的体积税；代价是值的生命周期吊诡——peek 要对 slot 做 save/restore，
raw 迭代模式（本项目 bench 的用法）根本拿不到值。

### oxc fused：u128 位包 Token，值全面下游化/旁路化

```rust
pub struct Token {   // 16B（src/lexer/token.rs:9-17）
    start: u32, end: u32,        // UTF-8 字节偏移，文件内相对
    kind: Kind,                  // u8，169 变体
    is_on_new_line: bool,        // 以下 4 个布尔各占一整字节
    escaped: bool,
    lone_surrogates: bool,
    has_separator: bool,
}
```

这个版本里**没有 TokenValue union**。token 只装 kind/span/4 个布尔
（各占一字节是刻意的：换单字节读写指令，浪费 24 bit 无所谓），所有
"值"都在 token 之外：

- 无转义的字符串/标识符：按 span 直接切原文，零分配；
- 有转义的字符串/模板：cooked 值物化进 `escaped_strings` /
  `escaped_templates: FxHashMap<u32, &str>`，**以 token.start 为键**，
  转义路径标 `#[cold]`（lexer/mod.rs:105-110、string.rs:243-276）；
- 数字 f64：lexer 完全不解析，parser 按需 `parse_int`/`parse_float`；
- 正则：re-lex 时返回 `pattern_end + RegExpFlags`，文本按 span 切；
- 注释：旁路 `TriviaBuilder` → `ArenaVec<Comment>`，扫描期顺手完成
  leading/trailing 归属和 `@__PURE__`/legal/coverage 等内容分类
  （trivia_builder.rs:168-197、304-493）。

"Fused" 指 lexer 体内**没有模式状态机**——正则/模板续段/JSX 全靠
parser 调 re-lex API 注入上下文，主循环因此没有 goal-symbol 位。

### oxc_lexer：没有 token 结构体，只有 SoA 平行数组

整批物化的输出是一组平行数组（`LexResult`，arena.rs:16-32）：

```
tok_kinds: []u8      // TokenKind，169 变体；判别值分段承载语义：
                     //   punct ∈ [32,128)、关键字 ≥128 ——区间比较即分类（token.rs:5-10）
tok_spans: []Span    // {start: u32, end: u32}；start 的 bit31 预留 newline-before
                     //   （故源长限 31 位；该位当前从不置位，token.rs:414-419）
-- 以下 value lanes 与 token 流没有显式索引，靠"第 k 个同类 token"序号对齐 --
numbers:     []f64             // 扫描期解析；BigInt 也转 f64（明示的有损取舍）
strings/templates/atoms: []StringSpan  // 两个 u32 索引进共享 cooked: []u8；
                     //   bit31 塞 lone_surrogates / cooked_invalid 标志
regex_flags: []u8              // g/i/m/s/u/y/d/v 位；pattern 不拆不验，span 覆盖整体
comment_meta: []u8 + comments: []Comment   // 注释双 lane 旁路
diags:       []Diagnostic      // {off, len, code, severity} 12B 定长
```

kind 字节在流水线内部全程以裸 u8 参与算数/blend/区间比较——"kind 空间
的空洞是给算数分类留的"，类型化 `TokenKind` 只存在于 crate 边界，
进出靠零成本 transmute（token.rs:361-375）。空白/换行 trivia 彻底不
记录；hashbang 例外留在显著流。

### my-scanner：12 字节 AoS，最简形态

```zig
pub const Lexeme = struct {   // src/lexeme.zig
    kind: LexemeKind,   // 12 大类（eof/identifier/number/string/regex/punct/shebang/illegal/
                        // no_substitution_template/template_head/template_middle/template_tail）
    flags: u8,          // newline_before（1 bit，预留 ASI/高亮所需 per-token 状态）
    start: u32, end: u32,   // UTF-8 字节偏移
};   // 12B，比 yuku 的 16B 瘦一档
```

无值、无行列。punct/关键字的具体文本靠 span 切片表达；行号靠
`LineIndex` 惰性物化——扫描期零成本，首次 `lineAt` 查询时才建换行
位图 + 块前缀和，之后 O(1)。模板拆 Head/Middle/Tail 四片（`${}`
子表达式 lexeme 全在主流，模板栈跟踪花括号平衡）；正则/除号按双
lexeme 回看启发式内部自决（prev2 识别名字位置关键字，tradeoff T1）。
trivia 不进流，「前面有换行」顺路压成 newline_before flag（含注释
内部换行检测），与五家的 newline-before 同口径。

另备细流定义 `Token`/`TokenTag`（src/token.zig，直接采用 yuku 的
定义：160 值枚举 + 分类掩码 + 优先级 + 4 flags，16B extern 结构），
作 parser 接口预备；粗→细的映射层留待消费方出现时再建。

## 二、token 种类对照

下表按 token 类别横排各家的 kind。除关键字和 punct 外，成员名字全部
列出（写法统一成各家的枚举成员名）；关键字和 punct 数量大，表中给
数量，**数量差的原因在表后两个小节专门解释**。"note" 列收无法入表
的特例与差异。

| 类别 | tsc | yuku | swc | oxc fused | oxc_lexer | my-scanner | note |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 标识符 | `Identifier` | `identifier` | `Ident` | `Ident` | `Ident`、`IdentEscaped` | `identifier` | oxc_lexer 用平行 kind 代替 escaped flag（含转义的标识符单独成 kind） |
| 私有名 `#foo` | `PrivateIdentifier` | `private_identifier` | **`Hash` + `Ident` 两个 token** | `PrivateIdentifier` | `PrivateIdent`、`PrivateIdentEscaped` | **punct `#` + `identifier` 两个 lexeme** | swc 与 my-scanner 都把 `#` 单独成 token（swc mod.rs:2156-2166），私有名要下游拼 |
| 数字 | `NumericLiteral`、`BigIntLiteral` | `numeric_literal`、`hex_literal`、`octal_literal`、`binary_literal`、`bigint_literal` | `Num`、`BigInt` | `Decimal`、`Float`、`Binary`、`Octal`、`Hex`、`PositiveExponential`、`NegativeExponential`、`DecimalBigInt`、`BinaryBigInt`、`OctalBigInt`、`HexBigInt` | `Number`、`BigInt` | `number` | 细分的动机是给 parser 省一次文本查看（进制/形态直接读 kind）；oxc_lexer 也声明了 `Decimal/Float/Binary/Octal/Hex` 五个细分 kind 但**从未发射**，细分理想与实际产出口径不一 |
| 字符串 | `StringLiteral` | `string_literal` | `Str` | `Str` | `String` | `string` | oxc_lexer 另声明 `StringCooked`，同样未发射 |
| 模板 | `NoSubstitutionTemplateLiteral`、`TemplateHead`、`TemplateMiddle`、`TemplateTail` | `no_substitution_template`、`template_head`、`template_middle`、`template_tail` | `NoSubstitutionTemplateLiteral`、`TemplateHead`、`TemplateMiddle`、`TemplateTail`，另有辅助 `Template`、`BackQuote`、`DollarLBrace` | `NoSubstitutionTemplate`、`TemplateHead`、`TemplateMiddle`、`TemplateTail` | `TemplateNoSub`、`TemplateHead`、`TemplateMiddle`、`TemplateTail` | `no_substitution_template`、`template_head`、`template_middle`、`template_tail` | 六家都是 NoSub/Head/Middle/Tail 四件套打平交错。oxc_lexer 另声明 4 个 `*Cooked` 变体未发射 |
| 正则 | `RegularExpressionLiteral` | `regex_literal` | `Regex` | `RegExp` | `RegExp` | `regex` | 种类上唯一无分歧的类别；差异全在附带数据（pattern/flags 拆不拆、值算不算），见第三节 |
| 注释 | `SingleLineCommentTrivia`、`MultiLineCommentTrivia`（仅 `skipTrivia=false` 时进流） | **无 kind**（旁路 `Comment{type: line\|block}`） | **无 kind**（旁路 `Comment{kind: Line\|Block}`） | **无 kind**（旁路 `ArenaVec<Comment>`） | `LineComment`、`BlockComment`（仅流水线内部存在，compress 时丢弃改走旁路 lane） | **无 kind**（不进流） | 五家里四家根本不设注释 kind；tsc 和 oxc_lexer 有 kind 但都不是默认交付 |
| 空白/换行 | `WhitespaceTrivia`、`NewLineTrivia`（同上进流条件） | 无 | 无 | `Skip`（伪 kind，主循环内部消化，对外不可见） | `Whitespace`、`LineTerminator`（compress 时丢弃） | 无（换行事实压成 `newline_before` flag） | 没有任何一家把空白当正式交付物；换行信息全部收敛成 1 bit newline-before |
| shebang | `ShebangTrivia` | **无 kind**（Lexer 上的独立字段 `{start, len}`） | `Shebang` | `HashbangComment`（产出即 Discard） | `Hashbang`（**保留在显著流**） | `shebang`（进流） | 处置最分散的一类：trivia / 独立字段 / token / 丢弃 / 显著流，五家五样 |
| JSX | `JsxText`、`JsxTextAllWhiteSpaces` | `jsx_identifier`、`jsx_text` | `JSXName`、`JSXText`，另有辅助 `JSXTagStart`、`JSXTagEnd`、`LessSlash`、`DollarLBrace` | `JSXText` | `JsxText`、`JsxTagEnd`、`JsxLt` | **无** | swc 的 4 个辅助 kind 是 JSX 模式的结构性碎片（`</`、`${`、标签首尾）；my-scanner 恒非 JSX，没有任何 JSX kind |
| EOF / 非法 | `EndOfFileToken`（未闭合等走 `tokenFlags` 的 `Unterminated` 位，无非法 kind） | `eof`、`invalid`（仅 lookahead 失败的哨兵，正常扫描不产） | `Eof`、`Error`（词法错误做成 `Token::Error` + `TokenValue::Error`，错误即 token） | `Eof`，另有内部伪 kind `Undetermined`、`Skip`（不对外） | `Eof`（流尾附 8 个哨兵防越界）、`Invalid`（诊断细节进 diags lane） | `eof`、`illegal`（逐字节消费，容错不中断） | 错误处理的三个代表方向：flags 位（tsc）、错误即值（swc）、旁路诊断（oxc_lexer） |
| 关键字 | 84 | ~83 | 39 + 46 | 87 | 79 | **并入 identifier** | 构成与差异原因见「关键字」小节 |
| punct | 61 | 58 | 64 | 58 | 58 | **1 大类** | 构成与差异原因见「punct」小节 |

### punct：58 是公约数，多出来的全是辅助

核心运算符全集恰好 **58 个**，yuku / oxc fused / oxc_lexer 三家一字不
差：算术、位、逻辑、比较、赋值（含 `**=`、`&&=`、`||=`、`??=`）、
更新、三元、箭头、`...`、`?.`、`@` 全套。61 和 64 的来源都是核心
之外的辅助 kind：

- **tsc 61 = 58 核心 + 3 个特殊**：`LessThanSlashToken`（`</`，JSX
  闭合标签用）、`BacktickToken` 与 `HashToken`（d.ts 注释明写"仅
  JSDoc scanner 产出"，普通 scanner 永不产生——普通路径里反引号
  直接产模板 kind、`#` 直接产 PrivateIdentifier）。另外注意 tsc 的
  **`>` 家族是二等公民**：`>>` `>>>` `>>=` `>>>=` 的 kind 在枚举里
  存在，但首扫恒只产单个 `GreaterThanToken`，复合要 parser 调
  `reScanGreaterToken` 合成——这是为 TS 泛型 `A<B<C>>` 闭合留的
  活口。`<` 家族没有这种待遇，`<<`/`<<=` 首扫正常合并。
- **swc 64 = 58 核心 + 6 个辅助**：`Hash`（`#` 单独成 token，私有名
  要下游拼 `Hash + Ident`）、`BackQuote`、`LessSlash`（`</`）、
  `DollarLBrace`（`${`）、`JSXTagStart` / `JSXTagEnd`——JSX 模式与
  模板分片机制的结构性碎片。
- **my-scanner 不细分**：一个 `punct` 大类覆盖全部，具体是哪个运算
  符靠 span 切片文本判别。

### 关键字：词表大同小异，差在 TS 收不收、怎么分段

各家的词表有一个明显的公约数：**ES 标准保留字 34 个
（`break`..`with`，含 `enum`）+ `true/false/null`**。数量从 79 到
87 的差异来自三件事：

1. **TS 类型层关键字收不收、收多少**——这是最大的口径差。五家全
   收：tsc 的 39 个上下文段含 `AnyKeyword` 等 TS 词；yuku 收 26 个
   （16 个 TS 上下文 + 10 个 TS 原始类型 `any/number/string/...`）；
   oxc 收 31 个 TS 段；swc 的 46 个 "known ident" 段大部分是 TS 词；
   oxc_lexer 收 35 个 TS 段、**仅 TS 模式生效**（JS 模式同样拼写产
   `Ident`，kind 集合是模式参数化的）。**my-scanner 干脆不分**：
   关键字一律归 identifier，判别留给上层（文本即依据）；45 词完美
   哈希表收缩为内部设施，只在 `/` 的正则/除号判别路径上现查
   （this/super 是值，其余关键字把 `/` 放进表达式位置）。
2. **条件/严格保留字归哪段**：`await/yield/let/static/async` 各家
   摆放不一——tsc 把 `await` 放进上下文段，oxc 放进 34 保留字段
   之首，yuku 用 `IsStrictModeReserved` 掩码单独标记。词还是那些
   词，段界不同导致"保留字数"不可直接比。
3. **新提案词汇的收录进度**：`using/defer/source/assert(s)/satisfies/
   accessor` 各家不齐（yuku 全收且 `as/satisfies` 还带二元优先级；
   tsc 收到 `defer` 为止）。

分段方式本身也是一种设计选择：tsc 分 3 段（36 保留 + 9 未来保留 +
39 上下文），oxc 分 4 段（34 保留 + 10 上下文 + 31 TS + 9 strict）
外加 `True/False/Null` 独立成 kind，swc 分 2 段（39 keyword + 46
known ident），oxc_lexer 一刀切（判别值 ≥ 128 即关键字，区间比较
本身就是 SIMD 分类机制的一部分），yuku 干脆不分段——在枚举值上压
掩码组合（`IsKeyword` × `IsIdentifierLike` × `IsUnconditionallyReserved`
× `IsStrictModeReserved`），所以 yuku 的 "~83" 取决于按哪个掩码数。

种类层面的总规律：**除我们外，五家都把 punct 和关键字逐一枚举，没有
一家靠文本二次判别**；kind 编码全部 ≤ u16。主流类别（标识符/数字/
字符串/模板/正则）成员高度同构，真正的分歧在边缘类别（shebang、
trivia、JSX、错误）的处置和数字的细分程度上。

## 三、附带数据：值的交付是个谱系

token 除了 kind 还带什么，六家分布在一个清晰的谱系上：

- **全物化端**：tsc 扫描期就 cook——字符串/模板 cooked 进 `tokenValue`
  （恒 string），数字连 f64 都不存、直接存 cooked 后的十进制字符串
  （`"" + +result`，ts.js:12315），代价是每个数字扫描期一次解析 +
  toString。swc 扫描期解析 f64、intern atom、cook 字符串（Wtf8Atom），
  BigInt 每 token 一次堆分配。oxc_lexer 把值物化推到极致：数字 f64
  （BigInt 也转 f64，明示的有损取舍）、cooked 字节统一进单一 lane、
  正则 flags 拆成位字节——全部流水线内生、不可关。
- **分层中间端**：oxc fused 快路径纯切片（零分配零间接），只有转义
  路径才把 cooked 值物化进以 token.start 为键的 HashMap 旁路，且标
  `#[cold]`。
- **零求值端**：yuku 和 my-scanner——lexer 不 cook、不 parse float、
  不 intern。yuku 用 4 个 flag 标记"下游需加工"（escaped /
  invalid_escape / lone_surrogates），cooked 值和数字值全部 parser/AST
  侧惰性计算；我们连 flag 都没有，切片即全部。

值得注意的是谱系位置与吞吐的相关性：最快的两家（yuku、oxc fused）
都在零求值/近零求值端，全物化的 swc 恰是吞吐最低的一家（oxc_lexer
全物化但靠 SIMD 流水线摊薄，其交付物更重的口径已在 architecture.md
注明）。

**flags 则高度收敛**，与值的策略无关：

| flag | tsc | yuku | swc | oxc fused | oxc_lexer | my-scanner |
| --- | --- | --- | --- | --- | --- | --- |
| newline-before（ASI 必需） | ✓ | ✓ | ✓ | ✓ | 预留未实现 | ✗ |
| escaped / 含转义 | ✓ | ✓ | ✓（lexer 级） | ✓ | 平行 kind | ✗ |
| lone_surrogates | ✓ | ✓ | ✗（WTF-8 天然容忍） | ✓ | StringSpan bit31 | ✗ |
| 数字含分隔符 `_` | ✓ | ✗ | ✗ | ✓ | ✗ | ✗ |
| unterminated | ✓ | ✗（报错） | ✗（错误即值） | ✗（报错） | 转诊断 | ✗ |

五家全都用独立的位/字节表达 flags，**没有一家污染 kind**（yuku 压进
kind 值的是分类/优先级这类静态属性，不是 per-token 状态）。

## 四、位置与行列

六家的 span 全部是 u32 偏移对，分歧在坐标系：

- **UTF-8 字节偏移、文件内相对**：yuku、oxc 两家、my-scanner。
- **UTF-16 code unit 下标**：tsc（JS 实现的天然坐标；本项目对照时经样本侧
  稀疏修正表 `samples/offsets/**` 换算，见 [samples.md](samples.md)）。
- **SourceMap 全局绝对偏移**：swc 的 `BytePos` 跨文件唯一，消费方须
  自管 base。

行列信息则呈现完全一致的默契：**没有一家在 token 上带行/列**。
换行事实全部压缩成 1 bit newline-before 挂在下一个 token 上（oxc_lexer
连这 1 bit 都还没实现，只在 span.start 预留了 bit31）；行列由下游
惰性换算——tsc 靠 SourceFile line map，swc 靠 SourceMap 二分查行表。
我们的惰性 LineIndex 在哲学上与之一致，但交付物更强：查询方不用自己
重扫，首次 `lineAt` 时引擎物化索引、之后 O(1)。

trivia 的位置：注释各家都有 span（旁路记录里）；tsc 最特殊，注释位置
靠 `getLeadingCommentRanges` 从原文**重扫一遍**获得，等于注释区域
扫两遍。空白换行除 tsc 的非默认模式外，没有任何一家记录。

## 五、交付形式与内存

六家分两极，**没有一家用 emit 事件/回调**：

- **on-demand 重入**（tsc / yuku / swc / oxc fused）：逐 token 拉取。
  tsc 是单 token 游标零分配；yuku 是 `nextToken() !Token`（+ 内联快
  路径 `tryNextToken`），默认不留流，`Options.tokens` 时才收集成
  arena 里的 AoS 数组；swc 是 `Tokens` trait 的 `first_token/next_token`
  （`Iterator` 只是兼容层，想要数组得用 `Capturing` 装饰器）；oxc 是
  `next_token()`，是否收集成流是**泛型 comptime 配置**——不收集的
  分支编译期消除，收集时按源长 +1 一次性预分配。
- **整批物化**（oxc_lexer / my-scanner）：一次性返回全部。oxc_lexer
  是纯 SoA + thread_local 复用 scratch，容量按源长和启发比例一次给足；
  我们是调用方管理缓冲的 AoS 数组（`scanInto`，容量按密度启发预留，
  bench 循环复用）。

两个值得记住的细节：其一，yuku 和 oxc fused 都是"on-demand 为体、
可选收集为用"——重入能力保留（re-lex 需要），批量收集只是配置项；
其二，on-demand 各家在迭代路径上都不携带值（swc 值留单 slot、oxc
没有值），**热路径上流动的 token 都是 16B 以内的纯位数据**。

## 六、歧义决策、重扫 API 与模板形态

正则/除号、模板续段、`>` 拆分、JSX 这四类歧义的处置方式，把六家
分成三个哲学阵营：

- **lexer 零上下文 + parser reScan 注入**（tsc / yuku / swc / oxc
  fused）：`/` 恒先按除号产 token，由 parser 调重扫 API 改判。tsc 有
  `reScanSlashToken` / `reScanGreaterToken` / `reScanTemplateToken` /
  `reScanJsxToken` 全套；yuku 以 `rewindTo` 为基座提供五个 reScan；
  swc 的正则重扫是**注入式**的 `set_next_regexp(Some(pos))`（下一次
  next_token 强制走正则），意外地适合外部决策注入（本项目 drive.rs
  即利用此点）；oxc 的 re-lex 只动当前 token（回退 1-3 字节 + Replace
  模式修正已收流）。
- **完备 oracle 内部自决**（oxc_lexer）：disambiguate pass 含 TS
  type-context oracle，test262 全过，**无任何 reScan API**。
- **启发式内部自决**（my-scanner）：单 lexeme 回看（tradeoff T1），
  无 reScan API（roadmap 已列重扫/二次切分协议）。

reScan 成立的前提被 tsc 的设计点破：**token 只携带可从 span 重推导的
数据**（kind + 游标 + 可从原文重算的 value），重扫就是回拨 pos 换
路径重走。这与"值下游化"互为因果——值一旦物化进 token，重扫就得
处理旧值作废问题（swc 的单 slot 恰好规避了它）。我们的 lexeme 恰好
满足这个前提，这是接 reScan 时的优势。

模板形态曾是六家中唯一的结构分歧，现已拉平：**六家全部打平成
Head/Middle/Tail 交错流**（子表达式是普通 token）。差别只剩续段
判别的归属：tsc/yuku/swc/oxc 靠 parser 重扫或外部驱动，oxc_lexer 靠
流水线帧栈，my-scanner 把同款花括号平衡栈内建于主循环（模板栈，
三驱动循环共享），无需外部续扫机制。

## 七、注释与 trivia

注释旁路收集是五家共识，形态各异：yuku 是 `ArrayList(Comment)`（仅
collect_comments 时填）；swc 是按挂点索引的 `HashMap<BytePos,
Vec<Comment>>` leading/trailing 两张表，注释文本也 intern；oxc fused
的 TriviaBuilder 在扫描期顺手做完 leading/trailing 归属和
`@__PURE__`/legal/coverage 内容分类；oxc_lexer 是 comment_meta +
comments 双 lane；tsc 最省——主流里什么都没有，要用时从原文重扫。
my-scanner 与五家同侧：注释不进流、无旁路（高亮/lint 需要时可按
span 重扫），扫描期只顺路做一件事——检测注释体内有没有换行，
压成下一个显著 lexeme 的 newline_before flag。

空白/换行除 tsc 非默认模式外无人记录；newline-before 是 trivia 留给
token 的唯一主流遗产，my-scanner 同口径。

## 八、横向规律

1. **token 本体瘦身是共识**：热路径上流动的都是 ≤16B 纯位数据
   （kind + span + 少量 flag）；值要么没有、要么旁路、要么在 lexer
   单 slot。
2. **零求值与速度正相关**：最快的两家 lexer 都不 cook、不 parse
   float、不 intern。
3. **flags 收敛于同一小组**：newline-before / escaped /
   lone_surrogates / separator / unterminated，全部走独立位。
4. **位置收敛于 u32 span + 1 bit newline-before**，行列全部下游惰性。
5. **on-demand 重入是 re-lex 的基座**：四家 reScan 系 lexer 全是
   重入状态机；整批物化的两家（oxc_lexer、my-scanner）都无 reScan——
   一个靠完备 oracle，一个靠启发式。
6. **注释旁路、空白抹除**是共识；shebang/JSX/错误这类边缘类别的
   处置才是各家的自由发挥区。

## 九、my-scanner 现状与候选改动

与谱系对照后的候选改动（详细论证见上文各节；标注 * 的 roadmap 已列）：

| 候选 | 谱系证据 | 状态 |
| --- | --- | --- |
| * per-token flags 字节，line_terminator_before 先行 | 五家全有（1 bit 起步） | **已落地**（2026-09）：粗流 Lexeme 带 flags 字节 + newline_before（含注释体内换行检测） |
| * reScan / 决策注入协议 | 四家 on-demand 系标配；我们的 lexeme 已满足"数据可从 span 重推导"前提 | jump_vec 单阶段天然可重入；two_phase 整批 classify 需专门设计 |
| 模板分片 | 六家全部分片 | **已落地**（2026-09）：四片 + 内建模板栈，`${}` 内 lexeme 全在主流，regex_starts 旁路随之删除 |
| escaped / unterminated / has_separator 等 flags | tsc/yuku/oxc 交集；unterminated 对 LSP 半成品场景特别有用 | 随细流映射层一并评估 |
| 注释改旁路收集 | 五家全部旁路 | **已落地**（2026-09）：注释不进流、无旁路（体换行检测仍顺路做）；曾短暂试过的连续流常驻选型同日否决（交付口径与对比方不公平） |
| kind 细分（punct/关键字展开成枚举） | 五家全部细分 | **定义已就位**（2026-09）：细流 Token/TokenTag 直接采用 yuku 定义（src/token.zig）；粗流维持 12 大类，映射层留待 parser 需要 O(1) 判别时 |
| * SoA 输出 | oxc_lexer 同族实践 | 性能实验，bench 裁决 |
| UTF-16 坐标边界层（LSP 场景） | tsc 原生 UTF-16；yuku 在 JS decoder 层换算 | 非 token 改动，边界层职责 |
