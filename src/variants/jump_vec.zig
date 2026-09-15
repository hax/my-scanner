//! 架构变体二：**单阶段驱动 + SIMD 长跳跃**（对标 yuku main、swc、oxc）。
//!
//! 与 scalar 变体同一条 pos 驱动循环，差别只在跳跃函数：字符串/模板/
//! 行注释/块注释的"找终点"复用两阶段里已有的 SIMD 原语
//! （stringStopMask / templateStopMask / newlineMask / findBlockCommentEnd）。
//! 字节仍只触碰一次（单阶段的本质优点），长跳跃区间一次跨 32 字节。
//!
//! 这条线回答的问题：把两阶段的"跳跃向量化"平移到单阶段骨架上，
//! 能不能既保住"字节只读一遍"，又吃到向量化跳跃的红利——它同时是
//! 第三形态（单阶段 + 按块候选缓冲）的直接前驱。
//!
//! 首字节分发与全部语义函数直接共享 scanner.tokenAt：这条线的演化
//! 空间在跳跃原语与驱动循环，语义修复由共享层单点生效。

const std = @import("std");
const token_mod = @import("../token.zig");
const scanner = @import("../scanner.zig");
const common = @import("common.zig");

const Token = token_mod.Token;
const Options = scanner.Options;
const Result = scanner.Result;

pub fn scan(allocator: std.mem.Allocator, src: []const u8, options: Options) !Result {
    std.debug.assert(src.len <= std.math.maxInt(u32));
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(allocator);
    const line_count = try scanInto(&tokens, allocator, src, options);
    const lines = try common.buildLineIndex(allocator, src);
    errdefer allocator.free(lines.breaks);
    errdefer allocator.free(lines.prefix);
    return .{
        .tokens = try tokens.toOwnedSlice(allocator),
        .line_count = line_count,
        .lines = lines,
    };
}

/// scan 的复用缓冲版本（与两阶段 scanInto 同签名，bench 同口径驱动）。
/// 返回逻辑行数。
pub fn scanInto(
    tokens: *std.ArrayList(Token),
    allocator: std.mem.Allocator,
    src: []const u8,
    options: Options,
) !usize {
    var pos: usize = 0;
    var prev: ?Token = null;
    var newlines: usize = 0;

    if (src.len >= 2 and src[0] == '#' and src[1] == '!') {
        const t = scanner.scanShebang(src);
        pos = t.end;
        prev = t;
        try tokens.append(allocator, t);
    }

    while (true) {
        const ws = common.skipWhitespace(src, pos);
        pos = ws.pos;
        newlines += ws.newlines;
        if (pos >= src.len) break;

        // SIMD 跳跃版分发（scanString/scanTemplate/lineEnd/块注释全向量化）
        const tok = scanner.tokenAt(src, pos, prev);
        pos = tok.end;
        // SIMD 跳跃不触碰区间内部字节，行号与 scalar 变体同款补计
        if (common.countsNewlines(tok.kind)) {
            newlines += common.countLogicalNewlines(src[tok.start..tok.end]);
        }
        if (tok.kind == .comment or tok.kind == .whitespace) {
            if (options.keep_comments) try tokens.append(allocator, tok);
            continue;
        }
        prev = tok;
        try tokens.append(allocator, tok);
    }
    try tokens.append(allocator, .{ .kind = .eof, .start = @intCast(src.len), .end = @intCast(src.len) });
    return newlines + 1;
}

// -- 测试：与两阶段交叉验证 ---------------------------------------------------

fn crossCheck(src: []const u8) !void {
    var a = try scanner.scan(std.testing.allocator, src, .{});
    defer a.deinit(std.testing.allocator);
    var mine: std.ArrayList(Token) = .empty;
    defer mine.deinit(std.testing.allocator);
    const line_count = try scanInto(&mine, std.testing.allocator, src, .{});
    try std.testing.expectEqual(a.line_count, line_count);
    if (mine.items.len != a.tokens.len) {
        std.debug.print("token 数不一致：两阶段 {d}，jump_vec {d}\n", .{ a.tokens.len, mine.items.len });
        return error.TestTokenCountMismatch;
    }
    for (a.tokens, mine.items) |x, y| {
        try std.testing.expectEqualDeep(x, y);
    }
}

test "jump_vec 变体与两阶段交叉验证" {
    const cases = [_][]const u8{
        "let x = 42;",
        "const s = \"a\\\"b\" + 'c';",
        "/* 块\n注释 */ var t = `模板 ${x + `嵌套${y}`} 尾`;",
        "// 行注释\nfoo?.bar!.baz ?? 1_000n;",
        "a / b / c; let re = /ab[/]/gu;",
        "中文标识符π = 0x1f + 0o17 + 0b101;",
        "#priv in obj;",
        "\\u0041bc = 1;",
        "x = \"未闭合\n",
        "a\r\nb\rc",
        "// 注释里有孤立\rv\n",
    };
    for (cases) |cases_src| try crossCheck(cases_src);
}
