//! Unicode 标识符判定：范围表二分 + 严格 UTF-8 解码。
//! 表由 tools/gen_unicode_tables.mjs 从 UCD 生成（见 unicode_tables.zig）。

const std = @import("std");
const tables = @import("unicode_tables.zig");

pub const Rune = struct { cp: u21, len: usize };

/// 解码 i 处的 UTF-8 码点；非法序列（孤立续字节、超长编码、代理区、
/// 超 U+10FFFF、截断）返回 null。
pub fn decode(src: []const u8, i: usize) ?Rune {
    const c = src[i];
    if (c < 0x80) return .{ .cp = c, .len = 1 };
    const len: usize = switch (c) {
        0xC2...0xDF => 2,
        0xE0...0xEF => 3,
        0xF0...0xF4 => 4,
        else => return null,
    };
    if (i + len > src.len) return null;
    var cp: u21 = c & @as(u8, 0xFF) >> @intCast(len + 1);
    for (src[i + 1 .. i + len]) |b| {
        if (b & 0xC0 != 0x80) return null;
        cp = (cp << 6) | (b & 0x3F);
    }
    if (cp >= 0xD800 and cp <= 0xDFFF) return null;
    return .{ .cp = cp, .len = len };
}

fn inRanges(comptime ranges: []const tables.Range, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (cp < ranges[mid].lo) {
            hi = mid;
        } else if (cp > ranges[mid].hi) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

/// 非 ASCII 码点能否作标识符首字符（ID_Start；`$`/`_` 走 ASCII 路径）。
pub fn isIdStart(cp: u21) bool {
    return cp >= 0x80 and inRanges(&tables.id_start, cp);
}

/// 非 ASCII 码点能否作标识符后续字符
/// （ID_Continue，含 ECMAScript 显式加入的 ZWNJ/ZWJ）。
pub fn isIdContinue(cp: u21) bool {
    return cp >= 0x80 and inRanges(&tables.id_continue, cp);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "decode：合法与非法序列" {
    try testing.expectEqual(Rune{ .cp = 'a', .len = 1 }, decode("a", 0).?);
    // π = U+03C0 = CF 80
    try testing.expectEqual(Rune{ .cp = 0x3C0, .len = 2 }, decode("\xcf\x80", 0).?);
    // 中 = U+4E2D = E4 B8 AD
    try testing.expectEqual(Rune{ .cp = 0x4E2D, .len = 3 }, decode("\xe4\xb8\xad", 0).?);
    // U+1F600 = F0 9F 98 80
    try testing.expectEqual(Rune{ .cp = 0x1F600, .len = 4 }, decode("\xf0\x9f\x98\x80", 0).?);
    // 孤立续字节 / 超长 / 截断 / 代理区（ED A0 80 = U+D800）
    try testing.expectEqual(@as(?Rune, null), decode("\x80", 0));
    try testing.expectEqual(@as(?Rune, null), decode("\xc0\xaf", 0));
    try testing.expectEqual(@as(?Rune, null), decode("\xe4\xb8", 0));
    try testing.expectEqual(@as(?Rune, null), decode("\xed\xa0\x80", 0));
}

test "ID_Start / ID_Continue 判定" {
    // π、中、日文假名是 ID_Start
    try testing.expect(isIdStart(0x3C0));
    try testing.expect(isIdStart(0x4E2D));
    try testing.expect(isIdStart(0x3042)); // あ
    // 数字里的非 ASCII（阿拉伯-印度数字 U+0660）不是 ID_Start 但是 ID_Continue
    try testing.expect(!isIdStart(0x0660));
    try testing.expect(isIdContinue(0x0660));
    // ☃ U+2603、→ U+2192 不是标识符字符
    try testing.expect(!isIdStart(0x2603));
    try testing.expect(!isIdContinue(0x2192));
    // ZWNJ/ZWJ 是 ID_Continue（ECMAScript 显式）
    try testing.expect(isIdContinue(0x200C));
    try testing.expect(isIdContinue(0x200D));
    // ASCII 由快速路径处理，表不覆盖
    try testing.expect(!isIdStart('a'));
    try testing.expect(!isIdContinue('0'));
}
