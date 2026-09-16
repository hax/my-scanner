//! my-scanner —— 探索用 SIMD 充分加速 JS/TS 词法分析。

const std = @import("std");

pub const token = @import("token.zig");
pub const simd = @import("simd.zig");
pub const scanner = @import("scanner.zig");

/// 架构变体：与 two_phase 共享语义层，各自独立演化驱动与跳跃策略。
/// 每个 scan/scanInto 与 scanner 同签名，可互换驱动（bench/差分/CLI）。
pub const variants = struct {
    pub const scalar = @import("variants/scalar.zig");
    pub const jump_vec = @import("variants/jump_vec.zig");
};

pub const Variant = enum {
    two_phase,
    scalar,
    jump_vec,

    pub fn scanInto(
        self: Variant,
        tokens: *std.ArrayList(Token),
        allocator: std.mem.Allocator,
        src: []const u8,
        options: Options,
    ) !usize {
        return switch (self) {
            .two_phase => scanner.scanInto(tokens, allocator, src, options),
            .scalar => variants.scalar.scanInto(tokens, allocator, src, options),
            .jump_vec => variants.jump_vec.scanInto(tokens, allocator, src, options),
        };
    }

    pub fn scan(self: Variant, allocator: std.mem.Allocator, src: []const u8, options: Options) !Result {
        return switch (self) {
            .two_phase => scanner.scan(allocator, src, options),
            .scalar => variants.scalar.scan(allocator, src, options),
            .jump_vec => variants.jump_vec.scan(allocator, src, options),
        };
    }
};

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
    _ = @import("variants/scalar.zig");
    _ = @import("variants/jump_vec.zig");
    _ = @import("variants/common.zig");
}
