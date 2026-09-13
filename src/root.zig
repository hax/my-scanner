//! my-scanner —— 探索用 SIMD 充分加速 JS/TS 词法分析。

pub const token = @import("token.zig");
pub const simd = @import("simd.zig");
pub const scanner = @import("scanner.zig");

pub const Token = token.Token;
pub const TokenKind = token.TokenKind;
pub const Options = scanner.Options;
pub const Result = scanner.Result;
pub const scan = scanner.scan;
pub const scanInto = scanner.scanInto;

test {
    // 显式引用各文件，确保其中的 test 块被收集
    _ = @import("token.zig");
    _ = @import("simd.zig");
    _ = @import("scanner.zig");
}
