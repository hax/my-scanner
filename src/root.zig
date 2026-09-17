//! my-scanner —— 探索用 SIMD 充分加速 JS/TS 词法分析。

const std = @import("std");

/// 粗粒度词法单元：scanner 的实际产出（连续流，trivia 常驻）
pub const lexeme = @import("lexeme.zig");
/// 细粒度 Token/TokenTag：yuku 定义（parser 接口预备）
pub const token = @import("token.zig");
pub const simd = @import("simd.zig");
pub const scanner = @import("scanner.zig");

/// 架构变体：与 two_phase 共享语义层，各自独立演化驱动与跳跃策略。
/// 每个变体一个目录（root.zig 为入口），scan/scanInto 与 scanner 同签名，
/// 可互换驱动（bench/差分测试/CLI）。
pub const variants = struct {
    pub const two_phase = @import("variants/two_phase/root.zig");
    pub const scalar = @import("variants/scalar/root.zig");
    pub const jump_vec = @import("variants/jump_vec/root.zig");
    pub const bitmap = @import("variants/bitmap/root.zig");
};

pub const Variant = enum {
    two_phase,
    scalar,
    jump_vec,
    bitmap,

    pub fn scanInto(
        self: Variant,
        tokens: *std.ArrayList(Lexeme),
        allocator: std.mem.Allocator,
        src: []const u8,
    ) !void {
        return switch (self) {
            .two_phase => variants.two_phase.scanInto(tokens, allocator, src),
            .scalar => variants.scalar.scanInto(tokens, allocator, src),
            .jump_vec => variants.jump_vec.scanInto(tokens, allocator, src),
            .bitmap => variants.bitmap.scanInto(tokens, allocator, src),
        };
    }

    pub fn scan(self: Variant, allocator: std.mem.Allocator, src: []const u8) !Result {
        return switch (self) {
            .two_phase => variants.two_phase.scan(allocator, src),
            .scalar => variants.scalar.scan(allocator, src),
            .jump_vec => variants.jump_vec.scan(allocator, src),
            .bitmap => variants.bitmap.scan(allocator, src),
        };
    }
};

pub const Lexeme = lexeme.Lexeme;
pub const LexemeKind = lexeme.LexemeKind;
pub const Result = scanner.Result;
pub const scan = variants.two_phase.scan;
pub const scanInto = variants.two_phase.scanInto;

test {
    // 显式引用各文件，确保其中的 test 块被收集
    _ = @import("lexeme.zig");
    _ = @import("token.zig");
    _ = @import("simd.zig");
    _ = @import("scanner.zig");
    _ = @import("variants/two_phase/root.zig");
    _ = @import("variants/scalar/root.zig");
    _ = @import("variants/scalar/jumps.zig");
    _ = @import("variants/scalar/dispatch.zig");
    _ = @import("variants/jump_vec/root.zig");
    _ = @import("variants/jump_vec/ws.zig");
    _ = @import("variants/bitmap/root.zig");
    _ = @import("variants/bitmap/bits.zig");
    _ = @import("variants/bitmap/vec.zig");
    _ = @import("variants/bitmap/classify.zig");
    _ = @import("variants/bitmap/misc_pass.zig");
    _ = @import("variants/bitmap/carve.zig");
    _ = @import("variants/bitmap/regex_allowed.zig");
    _ = @import("variants/bitmap/coalesce.zig");
    _ = @import("variants/bitmap/compress.zig");
    _ = @import("variants/common.zig");
}
