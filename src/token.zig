//! Token 模型。

/// Token 的大类。
///
/// 故意比 ECMAScript 的完整 token 集合粗：punctuator 与关键字的具体文本
/// 直接用 token 的字节区间表达（`tok.slice(src)`），等上层需要 O(1) 区分
/// 时再展开成细分枚举。
pub const TokenKind = enum {
    /// 文件结束（tokens 一定以它收尾）
    eof,
    /// 标识符
    identifier,
    /// 私有名 `#foo`
    private_name,
    /// 关键字 / 保留字
    keyword,
    /// 数字字面量（十/十六/八/二进制、小数、指数、BigInt、数字分隔符）
    number,
    /// 字符串字面量（单/双引号）
    string,
    /// 模板字面量（反引号；`${}` 子表达式暂整体归入，见 scanner 的 TODO）
    template,
    /// 正则字面量 `/.../flags`
    regex,
    /// 标点符号 / 操作符
    punct,
    /// shebang（`#!`，仅允许出现在文件开头）
    shebang,
    /// 注释（默认视为 trivia 跳过，`keep_comments` 时输出）
    comment,
    /// 无法识别的字节（消费 1 字节，容错不中断）
    illegal,
};

pub const Token = struct {
    kind: TokenKind,
    /// 字节区间 [start, end)
    start: u32,
    end: u32,

    pub fn slice(self: Token, src: []const u8) []const u8 {
        return src[self.start..self.end];
    }
};
