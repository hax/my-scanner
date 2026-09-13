//! SIMD 原语层：所有向量化字节分类集中在这里。
//!
//! 设计取向：
//! - 用 Zig 的 `@Vector` 表达，由编译器按目标平台自动选择指令集
//!   （x86: SSE2/AVX2，arm64: NEON），不写 intrinsics；
//! - 每个函数返回一个 bitmask（第 i 位 = 第 i 个字节是否命中），
//!   语义交给调用方用 `@ctz`/`@popCount` 组合：跳过、计数或报错。
//!   这是 simdjson 式"结构性跳过"（structural skipping）的思路。

const std = @import("std");

/// SIMD 块宽度（字节）。
/// 32 = AVX2 一拍 32 字节；NEON 上会拆成 2×16，依然有批量收益。
/// 想实验其它宽度（16/64）改这一个常量即可。
pub const block_size: usize = 32;

pub const Chunk = @Vector(block_size, u8);
pub const Mask = std.meta.Int(.unsigned, block_size);

/// 尾部不足一块时的填充字节。
/// 0x7f (DEL) 既不是空白、不是标识符字符，也不是任何 JS 语法结构字符，
/// 因此 padding 区域永远不会被误判成"可以继续扫描"。
pub const pad_byte: u8 = 0x7f;

/// 从 src[i..] 安全加载一个块，越界部分用 pad_byte 填充。
pub inline fn load(src: []const u8, i: usize) Chunk {
    if (i + block_size <= src.len) return src[i..][0..block_size].*;
    var buf: [block_size]u8 = @splat(pad_byte);
    const n = src.len - i;
    @memcpy(buf[0..n], src[i..]);
    return buf;
}

inline fn splat(c: u8) Chunk {
    return @splat(c);
}

/// JS 空白 + 行终止符集合：' ' \t \n \r \v \f。
/// 多字节空白（U+00A0 等）由 scanner 层处理（见 TODO）。
pub inline fn whitespaceMask(chunk: Chunk) Mask {
    const m1 = chunk == splat(' ');
    const m2 = chunk == splat('\t');
    const m3 = chunk == splat('\n');
    const m4 = chunk == splat('\r');
    const m5 = chunk == splat(0x0b); // \v
    const m6 = chunk == splat(0x0c); // \f
    return @bitCast(m1 | m2 | m3 | m4 | m5 | m6);
}

pub inline fn newlineMask(chunk: Chunk) Mask {
    return @bitCast(chunk == splat('\n'));
}

/// 标识符后续字符 [A-Za-z0-9_$]（ASCII 阶段；unicode 见 scanner TODO）。
pub inline fn identPartMask(chunk: Chunk) Mask {
    const lower = (chunk >= splat('a')) & (chunk <= splat('z'));
    const upper = (chunk >= splat('A')) & (chunk <= splat('Z'));
    const digit = (chunk >= splat('0')) & (chunk <= splat('9'));
    const under = chunk == splat('_');
    const dollar = chunk == splat('$');
    return @bitCast(lower | upper | digit | under | dollar);
}

/// 字符串里需要停下来的字符：结束引号、反斜杠（转义）、换行（裸换行非法）。
pub inline fn stringStopMask(chunk: Chunk, quote: u8) Mask {
    const q = chunk == splat(quote);
    const esc = chunk == splat('\\');
    const nl = chunk == splat('\n');
    const cr = chunk == splat('\r');
    return @bitCast(q | esc | nl | cr);
}

/// 模板串里的关注字符：反引号、反斜杠（转义）、'$'（可能的 `${`）。
/// 模板允许跨行，所以不含换行；行数由调用方对最终区间统一 popcount。
pub inline fn templateStopMask(chunk: Chunk) Mask {
    const q = chunk == splat('`');
    const esc = chunk == splat('\\');
    const dollar = chunk == splat('$');
    return @bitCast(q | esc | dollar);
}

/// 定位从 from 起下一个 `*/`（返回其 **后一位**），找不到返回 null。
///
/// 思路：`slash_mask & (star_mask << 1)` 即"前面是 `*` 的 `/`"，
/// 一条位逻辑同时检查 32 个位置。跨块边界（上一块末字节是 `*`、
/// 本块首字节是 `/`）用 carry 位衔接。
pub fn findBlockCommentEnd(src: []const u8, from: usize) ?usize {
    var i = from;
    var carry: Mask = 0; // 上一块的最后一个字节是否为 '*'
    while (i < src.len) {
        const chunk = load(src, i);
        const star: Mask = @bitCast(chunk == splat('*'));
        const slash: Mask = @bitCast(chunk == splat('/'));
        const close = slash & ((star << 1) | carry);
        if (close != 0) {
            // padding 区不可能是 '/'，命中位必在真实字节里
            return i + @as(usize, @ctz(close)) + 1;
        }
        carry = star >> (block_size - 1);
        i += block_size;
    }
    return null;
}

/// 统计一段字节里的 '\n' 个数：整块 popcount + 尾部标量。
pub fn countNewlines(bytes: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i + block_size <= bytes.len) : (i += block_size) {
        n += @as(usize, @popCount(newlineMask(bytes[i..][0..block_size].*)));
    }
    while (i < bytes.len) : (i += 1) {
        n += @intFromBool(bytes[i] == '\n');
    }
    return n;
}

// ---------------------------------------------------------------------------
// 标量版字符分类（SIMD mask 的人类可读对照，供冷路径与尾部收尾使用）
// ---------------------------------------------------------------------------

pub fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

pub fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

pub fn isOctalDigit(c: u8) bool {
    return c >= '0' and c <= '7';
}

pub fn isBinaryDigit(c: u8) bool {
    return c == '0' or c == '1';
}

pub fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
}

pub fn isIdentPart(c: u8) bool {
    return isIdentStart(c) or isDigit(c);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "load 尾部填充" {
    const src = "ab"; // 不足一块
    const chunk = load(src, 0);
    try testing.expectEqual(@as(u8, 'a'), chunk[0]);
    try testing.expectEqual(@as(u8, 'b'), chunk[1]);
    try testing.expectEqual(@as(u8, pad_byte), chunk[2]);
    try testing.expectEqual(@as(u8, pad_byte), chunk[block_size - 1]);
}

test "whitespaceMask" {
    var buf: [block_size]u8 = @splat('x');
    buf[1] = ' ';
    buf[5] = '\t';
    buf[31] = '\n';
    const m = whitespaceMask(buf);
    try testing.expectEqual(@as(Mask, (1 << 1) | (1 << 5) | (1 << 31)), m);
}

test "identPartMask" {
    var buf: [block_size]u8 = @splat('-');
    buf[0] = 'a';
    buf[2] = 'Z';
    buf[4] = '9';
    buf[6] = '_';
    buf[8] = '$';
    const m = identPartMask(buf);
    try testing.expectEqual(@as(Mask, 1 | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 8)), m);
}

test "findBlockCommentEnd 各种对齐（含跨块边界）" {
    // 用不同长度前缀把 "*/" 推到块内不同位置，验证 carry 衔接
    var src_buf: [block_size * 3]u8 = undefined;
    for (0..block_size + 8) |pad| {
        @memset(&src_buf, 'x');
        const comment = "/* yy */ tail";
        @memcpy(src_buf[pad..][0..comment.len], comment);
        const src = src_buf[0 .. pad + comment.len];
        const end = findBlockCommentEnd(src, pad + 2).?;
        try testing.expectEqual(pad + "/* yy */".len, end);
    }
}

test "findBlockCommentEnd 未闭合" {
    try testing.expectEqual(@as(?usize, null), findBlockCommentEnd("/* nope", 2));
    try testing.expectEqual(@as(?usize, null), findBlockCommentEnd("", 0));
    try testing.expectEqual(@as(?usize, null), findBlockCommentEnd("a */", 3));
}

test "countNewlines" {
    try testing.expectEqual(@as(usize, 0), countNewlines(""));
    try testing.expectEqual(@as(usize, 1), countNewlines("a\nb"));
    try testing.expectEqual(@as(usize, 2), countNewlines("\r\n\n")); // 只数 \n
    const many = "\n" ** 100;
    try testing.expectEqual(@as(usize, 100), countNewlines(many));
}
