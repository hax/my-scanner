//! Lexeme：scanner 实际产出的粗粒度词法单元。
//!
//! 与 token.zig 相对——那是 yuku 定义的细粒度 Token/TokenTag（parser 接口
//! 预备）；本文件是面向吞吐的粗流：kind 只有十数个大类，punctuator 与
//! 关键字的具体文本直接从源码字节区间恢复，等上层需要 O(1) 区分时再
//! 展开成细分枚举。
//!
//! 交付口径对齐 yuku 等引擎：trivia（空白/换行/注释）不进流，扫描期
//! 顺路把「前面有换行」压成 1 bit 挂在下一个显著 lexeme 的 flags 上
//! （ASI / `-->` 行首注释判别够用，行号由 LineIndex 惰性物化）。

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
};

/// `flags` 位：本 lexeme 之前的 trivia 中含行终止符
/// （\n、孤立 \r、U+2028、U+2029，与 LineIndex 口径一致）。
pub const flag_newline_before: u8 = 1 << 0;

pub const Lexeme = struct {
    kind: LexemeKind,
    /// per-lexeme 标志位（见 flag_* 常量；预留 ASI/高亮所需的 per-token 状态）
    flags: u8 = 0,
    _pad: [2]u8 = .{ 0, 0 },
    /// 字节区间 [start, end)
    start: u32,
    end: u32,

    /// 本 lexeme 之前的 trivia 中是否有行终止符（含注释内部）
    pub fn newlineBefore(self: Lexeme) bool {
        return self.flags & flag_newline_before != 0;
    }

    /// 字节区间文本
    pub fn slice(self: Lexeme, src: []const u8) []const u8 {
        return src[self.start..self.end];
    }
};

comptime {
    // 12B：比 yuku 的 16B（tag+flags+span）瘦一档
    if (@sizeOf(Lexeme) != 12) @compileError("Lexeme 应为 12 字节");
}
