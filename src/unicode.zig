//! Unicode 标识符判定：两级位图直查 + 严格 UTF-8 解码。
//! 表由 tools/gen_unicode_tables.mjs 从 UCD 生成（见 unicode_tables.zig）：
//! root[cp >> 9] → 去重叶（512 bit = 8 u64），一次查询 2 次 load，
//! 替代范围表二分（~10 次比较）——unicode 标识符字符密集语料（如
//! 中文标识符）每字符都查，常数差异直接体现在吞吐上。

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

inline fn lookup(root: []const u8, leaves: []const u64, cp: u21) bool {
    // decode 对 F4 序列不校验第二字节上限，可能给出 > U+10FFFF 的码点
    //（合法输入不会触发；位图只覆盖到 0x10FFFF，必须先挡住）
    if (cp > 0x10FFFF) return false;
    const leaf = root[cp >> tables.chunk_shift];
    const word = leaves[@as(usize, leaf) * tables.leaf_words + ((cp >> 6) & 7)];
    return (word >> @intCast(cp & 63)) & 1 != 0;
}

/// 非 ASCII 码点能否作标识符首字符（ID_Start；`$`/`_` 走 ASCII 路径）。
pub fn isIdStart(cp: u21) bool {
    return cp >= 0x80 and lookup(&tables.id_start_root, &tables.id_start_leaves, cp);
}

/// 非 ASCII 码点能否作标识符后续字符
/// （ID_Continue，含 ECMAScript 显式加入的 ZWNJ/ZWJ）。
pub fn isIdContinue(cp: u21) bool {
    return cp >= 0x80 and lookup(&tables.id_continue_root, &tables.id_continue_leaves, cp);
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
