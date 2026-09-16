//! Lexeme：scanner 实际产出的粗粒度词法单元。
//!
//! 与 token.zig 相对——那是 yuku 定义的细粒度 Token/TokenTag（parser 接口
//! 预备）；本文件是面向吞吐的粗流：kind 只有十数个大类，punctuator 与
//! 关键字的具体文本直接从源码字节区间恢复，等上层需要 O(1) 区分时再
//! 展开成细分枚举。
//!
//! 连续性不变量：lexeme 流连续覆盖全文，trivia（whitespace / newline /
//! comment）常驻不跳过，因此不存 end——第 i 个 lexeme 的终点就是第
//! i+1 个的 start；eof.start == src.len 为最后一个真实 lexeme 兜底。

/// Lexeme 的大类。
pub const LexemeKind = enum {
    /// 文件结束（lexeme 流一定以它收尾）
    eof,
    /// 标识符（含关键字；关键字判别留给上层，文本即判别依据）
    identifier,
    /// 数字字面量（十/十六/八/二进制、小数、指数、BigInt、数字分隔符）
    number,
    /// 字符串字面量（单/双引号）
    string,
    /// 正则字面量 `/.../flags`
    regex,
    /// 标点符号 / 操作符（含私有名的 `#` 与装饰器的 `@`）
    punct,
    /// shebang（`#!`，仅出现在文件开头）
    shebang,
    /// 无法识别的字节/非法形态（容错消费，不中断）
    illegal,
    /// 无子表达式模板（`` `...` `` 整体）
    no_substitution_template,
    /// 模板首片（`` `...${ ``）
    template_head,
    /// 模板中间片（`}...${`）
    template_middle,
    /// 模板尾片（`}...` ``）
    template_tail,
    /// 行注释（`//...`，不含行尾换行）
    line_comment,
    /// 块注释（`/*...*/`）
    block_comment,
    /// 不含行终止符的连续空白
    whitespace,
    /// 含行终止符的连续空白 run：从首个 \n/\r/U+2028/U+2029 起到 run 末尾
    newline,
};

pub const Lexeme = struct {
    kind: LexemeKind,
    /// 字节起点；终点 = 下一个 lexeme 的 start（连续性不变量）
    start: u32,

    /// 字节区间文本。next_start 取下一个 lexeme 的 start（流末取 src.len）。
    pub fn slice(self: Lexeme, src: []const u8, next_start: u32) []const u8 {
        return src[self.start..next_start];
    }
};
