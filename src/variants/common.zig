//! 单阶段变体的公共层：空白跳过（含逻辑换行计数）、跳跃区间的换行
//! 补计、LineIndex 构建。
//!
//! 单阶段没有两阶段 classify 的换行位图副产品，行号按"产生 token 时
//! 只对可能跨行的区间补一趟计数"的方式维护——这正是单阶段架构为行号
//! 付出的成本（yuku 系在 advance 循环里逐字符判断，殊途同归），
//! 计入 scanInto 的计时口径，如实反映架构差异。
//!
//! 逻辑换行语义与 simd.classifyTokenStarts 的位图一致：
//! `\n` 计 1；孤立 `\r` 计 1；CRLF 整体计 1；U+2028/U+2029 计 1。

const std = @import("std");
const simd = @import("../simd.zig");
const scanner = @import("../scanner.zig");

pub const Token = scanner.Token;

/// U+2028/U+2029 判定：src[i] 已知是 0xE2 前导。
pub inline fn isUtf8LineSep(src: []const u8, i: usize) bool {
    return i + 2 < src.len and src[i + 1] == 0x80 and
        (src[i + 2] == 0xA8 or src[i + 2] == 0xA9);
}

/// 跳过 pos 处开始的空白（ASCII + Unicode whitespace），返回新 pos 与
/// 途经的逻辑换行数。token 起点在返回 pos 处（或文件尾）。
pub fn skipWhitespace(src: []const u8, pos0: usize) struct { pos: usize, newlines: usize } {
    var pos = pos0;
    var nl: usize = 0;
    while (pos < src.len) {
        const c = src[pos];
        switch (c) {
            '\n' => {
                nl += 1;
                pos += 1;
            },
            '\r' => {
                nl += 1; // 孤立 \r 计 1；CRLF 也计 1（\n 不再单计）
                pos += 1;
                if (pos < src.len and src[pos] == '\n') pos += 1;
            },
            ' ', '\t', 0x0b, 0x0c => pos += 1,
            else => {
                if (c >= 0x80) {
                    if (simd.unicodeWhitespaceLen(src, pos)) |len| {
                        if (len == 3 and isUtf8LineSep(src, pos)) nl += 1;
                        pos += len;
                        continue;
                    }
                }
                return .{ .pos = pos, .newlines = nl };
            },
        }
    }
    return .{ .pos = pos, .newlines = nl };
}

/// 区间内可能含换行字节的 token kind：跳跃函数（string/template/块注释/
/// 正则/容错路径）不逐字节触碰内容，产完后补一趟计数。identifier、
/// number、punct 等的字符集排斥换行，无需计数。
pub fn countsNewlines(kind: scanner.TokenKind) bool {
    return switch (kind) {
        .comment, .string, .template, .regex, .illegal => true,
        else => false,
    };
}

/// 标量逻辑换行计数（跳跃区间补计用；区间的首尾边界完整落于 token
/// 之内，无跨区间 CRLF 撕裂问题——CRLF 的 \r\n 同属一个 token 或同属空白）。
pub fn countLogicalNewlines(bytes: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        switch (bytes[i]) {
            '\n' => n += 1,
            '\r' => {
                n += 1;
                if (i + 1 < bytes.len and bytes[i + 1] == '\n') {
                    i += 2;
                    continue;
                }
            },
            0xE2 => {
                if (isUtf8LineSep(bytes, i)) {
                    n += 1;
                    i += 3;
                    continue;
                }
            },
            else => {},
        }
        i += 1;
    }
    return n;
}

/// 为变体 scan() 构建 LineIndex（CLI dump 用；不进 bench 计时路径）。
/// 标量逐字节组 32B 块位图，格式与 simd.classifyTokenStarts 一致。
pub fn buildLineIndex(allocator: std.mem.Allocator, src: []const u8) !scanner.LineIndex {
    const nblocks = (src.len + simd.block_size - 1) / simd.block_size;
    const breaks = try allocator.alloc(u32, nblocks);
    errdefer allocator.free(breaks);
    @memset(breaks, 0);

    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        var hit = false;
        var width: usize = 1;
        switch (c) {
            '\n' => hit = true,
            '\r' => {
                hit = !(i + 1 < src.len and src[i + 1] == '\n');
            },
            0xE2 => {
                if (isUtf8LineSep(src, i)) {
                    hit = true;
                    width = 3; // 位标记在末字节（A8/A9），与 classify 一致
                }
            },
            else => {},
        }
        if (hit) {
            const at = if (width == 3) i + 2 else i;
            breaks[at / simd.block_size] |= @as(u32, 1) << @intCast(at % simd.block_size);
        }
        i += width;
    }

    const prefix = try allocator.alloc(u32, nblocks);
    var acc: u32 = 0;
    for (breaks, 0..) |m, b| {
        prefix[b] = acc;
        acc += @popCount(m);
    }
    return .{ .breaks = breaks, .prefix = prefix, .len = src.len };
}

test "countLogicalNewlines 语义与 classify 位图一致" {
    // 覆盖：\n、孤立 \r、CRLF、U+2028/29、普通字节、字符串内换行
    const src = "a\nb\r\nc\rd\u{2028}e\u{2029}f\n";
    const n = countLogicalNewlines(src);
    // \n(b后) CRLF \r(d前) 2028 2029 \n(尾) = 6
    try std.testing.expectEqual(@as(usize, 6), n);

    var cls = try simd.classifyTokenStarts(std.testing.allocator, src);
    defer cls.starts.deinit(std.testing.allocator);
    defer std.testing.allocator.free(cls.line_breaks);
    try std.testing.expectEqual(cls.newlines, n);
}

test "skipWhitespace 与 countLogicalNewlines 组合覆盖全文件" {
    // 任意文件：空白段计数 + token 区间计数 之和 == classify 的 newlines
    const src = "let x = 1; // 注释\n/* 块\n注释 */ `模板\n串` 'a\\nb'\r\n中文";
    var cls = try simd.classifyTokenStarts(std.testing.allocator, src);
    defer cls.starts.deinit(std.testing.allocator);
    defer std.testing.allocator.free(cls.line_breaks);

    var total: usize = 0;
    var pos: usize = 0;
    while (pos < src.len) {
        const ws = skipWhitespace(src, pos);
        total += ws.newlines;
        pos = ws.pos;
        if (pos >= src.len) break;
        // 到下一个非空白 token 的粗略终点：这里直接借两阶段 tokenAt
        const tok = scanner.tokenAt(src, pos, null, null);
        if (countsNewlines(tok.kind)) total += countLogicalNewlines(src[tok.start..tok.end]);
        pos = tok.end;
    }
    try std.testing.expectEqual(cls.newlines, total);
}
