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
    const space = chunk == splat(' ');
    const control = (chunk >= splat('\t')) & (chunk <= splat('\r'));
    return @bitCast(space | control);
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
// 阶段 1：字节分类 pass（两阶段 scanner 的第一段）
//
// 一次 SIMD 扫描为每个字节建立分类位平面（空白 / 标识符字符），
// 再用纯位运算推导出 token 候选起点掩码：
//
//     candidate[i] = !whitespace[i] & !(ident_part[i] & ident_part[i-1])
//
// 即"非空白，且不是标识符的中间字节"。字符串/注释/正则内部的字节
// 同样会命中候选（阶段 1 不做范围剔除），但阶段 2 贪心消费完一个
// token 后从它的终点继续迭代候选位，假起点自然被越过。
// ---------------------------------------------------------------------------

/// token 候选起点位图：每 block 一个 u32。
pub const TokenStarts = struct {
    masks: []u32,

    pub fn deinit(self: *TokenStarts, allocator: std.mem.Allocator) void {
        allocator.free(self.masks);
        self.masks = &.{};
    }

    /// from 之后（含 from）下一个候选起点的字节偏移。
    pub fn nextAt(self: *const TokenStarts, from: usize) ?usize {
        var bi = from / block_size;
        if (bi >= self.masks.len) return null;
        // 清掉 from 所在块中位于 from 之前的位
        var m = self.masks[bi] & ~((@as(u32, 1) << @intCast(from % block_size)) - 1);
        while (true) {
            if (m != 0) return bi * block_size + @as(usize, @ctz(m));
            bi += 1;
            if (bi >= self.masks.len) return null;
            m = self.masks[bi];
        }
    }
};

/// 阶段 1 主体：产出候选起点位图，顺带 popcount 出全文件换行总数
/// （含注释/字符串/模板内部的换行，物理行口径）。
pub fn classifyTokenStarts(
    allocator: std.mem.Allocator,
    src: []const u8,
) !struct { starts: TokenStarts, newlines: usize } {
    const nblocks = (src.len + block_size - 1) / block_size;
    const masks = try allocator.alloc(u32, nblocks);
    errdefer allocator.free(masks);

    var newlines: usize = 0;
    var carry_ip: u32 = 0; // 前一块最后一个字节是否为标识符字符（放在 bit0）
    for (masks, 0..) |*out, bi| {
        const i = bi * block_size;
        const chunk = load(src, i);
        // 尾块：padding 字节（0x7f）非空白也非标识符字符，会算出假候选，
        // 也可能被误计换行——都不会，但统一砍掉越界位最稳
        const rem = src.len - i;
        const valid: u32 = if (rem >= block_size)
            std.math.maxInt(u32)
        else
            (@as(u32, 1) << @intCast(rem)) - 1;

        const ws = whitespaceMask(chunk);
        const ip = identPartMask(chunk);
        // prev_ip 的第 j 位 = 第 j-1 个字节是否标识符字符；
        // 块内左移衔接 + 跨块 carry
        const prev_ip = (ip << 1) | carry_ip;
        out.* = ~ws & ~(ip & prev_ip) & valid;

        carry_ip = ip >> (block_size - 1);
        newlines += @as(usize, @popCount(newlineMask(chunk) & valid));
    }

    return .{ .starts = .{ .masks = masks }, .newlines = newlines };
}

// ---------------------------------------------------------------------------
// 字节类别码：多个分类平面经"矩阵旋转"打包成每字节一个 u8 码。
// plane-major（每个平面一条向量）→ byte-major（每个字节一个 packed 码），
// 后续平面在码上继续叠位即可。
// ---------------------------------------------------------------------------

pub const Class = struct {
    pub const whitespace: u8 = 1 << 0; // ' ' \t \n \r \v \f
    pub const ident_part: u8 = 1 << 1; // [A-Za-z0-9_$]
    pub const ident_start: u8 = 1 << 2; // [A-Za-z_$]
    pub const digit: u8 = 1 << 3; // 0-9
    pub const punct: u8 = 1 << 4; // 可能的 punctuator 首字节（含 '#'）
    pub const quote: u8 = 1 << 5; // ' " `
};

/// 各平面的向量判定（bool 向量，packClasses 的原料）
inline fn classPlanes(chunk: Chunk) struct {
    ws: @Vector(block_size, bool),
    ip: @Vector(block_size, bool),
    istart: @Vector(block_size, bool),
    digit: @Vector(block_size, bool),
    punct: @Vector(block_size, bool),
    quote: @Vector(block_size, bool),
} {
    const lower = (chunk >= splat('a')) & (chunk <= splat('z'));
    const upper = (chunk >= splat('A')) & (chunk <= splat('Z'));
    const digit = (chunk >= splat('0')) & (chunk <= splat('9'));
    const under = chunk == splat('_');
    const dollar = chunk == splat('$');
    return .{
        .ws = (chunk == splat(' ')) |
            ((chunk >= splat('\t')) & (chunk <= splat('\r'))),
        .ip = lower | upper | digit | under | dollar,
        .istart = lower | upper | under | dollar,
        .digit = digit,
        .punct = blk: {
            var v: @Vector(block_size, bool) = @splat(false);
            inline for ("{}()[];,<>+-*/%&|^!~?:.=@#") |c| v |= (chunk == splat(c));
            break :blk v;
        },
        .quote = (chunk == splat('\'')) | (chunk == splat('"')) | (chunk == splat('`')),
    };
}

inline fn punctMask(chunk: Chunk) Mask {
    var v: @Vector(block_size, bool) = @splat(false);
    inline for ("{}()[];,<>+-*/%&|^!~?:.=@#") |c| v |= (chunk == splat(c));
    return @bitCast(v);
}

/// 矩阵旋转：分类平面 → 每字节类别码（bit i 来自第 i 个平面）。
pub fn packClasses(chunk: Chunk) @Vector(block_size, u8) {
    const planes = classPlanes(chunk);
    const zero = @as(@Vector(block_size, u8), @splat(0));
    var code = zero;
    code |= @select(u8, planes.ws, @as(@Vector(block_size, u8), @splat(Class.whitespace)), zero);
    code |= @select(u8, planes.ip, @as(@Vector(block_size, u8), @splat(Class.ident_part)), zero);
    code |= @select(u8, planes.istart, @as(@Vector(block_size, u8), @splat(Class.ident_start)), zero);
    code |= @select(u8, planes.digit, @as(@Vector(block_size, u8), @splat(Class.digit)), zero);
    code |= @select(u8, planes.punct, @as(@Vector(block_size, u8), @splat(Class.punct)), zero);
    code |= @select(u8, planes.quote, @as(@Vector(block_size, u8), @splat(Class.quote)), zero);
    return code;
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
    buf[block_size - 1] = '\n';
    const m = whitespaceMask(buf);
    try testing.expectEqual(@as(Mask, (1 << 1) | (1 << 5) | (1 << (block_size - 1))), m);
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

test "classifyTokenStarts：候选起点规则" {
    // "let x = 42;" → l、x、=、4、; 是候选；et/x 后的空白被跳过
    const src = "let x = 42;";
    var r = try classifyTokenStarts(testing.allocator, src);
    defer r.starts.deinit(testing.allocator);
    try testing.expectEqualSlices(usize, &.{ 0, 4, 6, 8, 10 }, collectStarts(&r.starts));
    try testing.expectEqual(@as(usize, 0), r.newlines);
}

test "classifyTokenStarts：标识符中间字节不算候选" {
    // a1b 是一个标识符：只有 0 是候选；.5 从 '.' 起算（'5' 也是候选，
    // 属于被阶段 2 贪心消费越过的假候选）
    const src = "a1b .5 x_1";
    var r = try classifyTokenStarts(testing.allocator, src);
    defer r.starts.deinit(testing.allocator);
    try testing.expectEqualSlices(usize, &.{ 0, 4, 5, 7 }, collectStarts(&r.starts));
}

test "classifyTokenStarts：字符串内部字节是假候选（阶段 2 越过）" {
    // "a b" 内的 a、b、闭引号都是候选，但属于 string token 区间或紧邻
    const src = "\"a b\" x";
    var r = try classifyTokenStarts(testing.allocator, src);
    defer r.starts.deinit(testing.allocator);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 3, 4, 6 }, collectStarts(&r.starts));
}

test "classifyTokenStarts：跨块 carry 与尾块 padding" {
    // 80 字节标识符 + 分隔，跨 32 字节块边界验证 carry
    var buf: [block_size * 3]u8 = undefined;
    @memset(&buf, 'a'); // 全标识符字符
    buf[block_size - 1] = ' ';
    buf[block_size * 2 - 1] = '\n';
    const src = buf[0 .. block_size * 3];
    var r = try classifyTokenStarts(testing.allocator, src);
    defer r.starts.deinit(testing.allocator);
    // 每块首字节（0、32、64）是候选，其余标识符中间字节都不是
    try testing.expectEqualSlices(usize, &.{ 0, block_size, block_size * 2 }, collectStarts(&r.starts));
    try testing.expectEqual(@as(usize, 1), r.newlines);
}

test "classifyTokenStarts：空文件与纯空白" {
    {
        var r = try classifyTokenStarts(testing.allocator, "");
        defer r.starts.deinit(testing.allocator);
        try testing.expectEqual(@as(?usize, null), r.starts.nextAt(0));
    }
    {
        var r = try classifyTokenStarts(testing.allocator, "  \n\t ");
        defer r.starts.deinit(testing.allocator);
        try testing.expectEqual(@as(?usize, null), r.starts.nextAt(0));
    }
}

test "classifyTokenStarts：nextAt 从任意位置起查" {
    const src = "a b  c";
    var r = try classifyTokenStarts(testing.allocator, src);
    defer r.starts.deinit(testing.allocator);
    try testing.expectEqual(@as(?usize, 0), r.starts.nextAt(0));
    try testing.expectEqual(@as(?usize, 2), r.starts.nextAt(1));
    try testing.expectEqual(@as(?usize, 5), r.starts.nextAt(3));
    try testing.expectEqual(@as(?usize, 5), r.starts.nextAt(5));
    try testing.expectEqual(@as(?usize, null), r.starts.nextAt(6));
}

test "packClasses：平面矩阵旋转成每字节类别码" {
    var buf: [block_size]u8 = @splat('x');
    buf[0] = ' ';
    buf[1] = '9';
    buf[2] = '$';
    buf[3] = '"';
    buf[4] = '+';
    const code = packClasses(buf);
    // 逐字节核对：码位来自对应平面
    try testing.expectEqual(Class.whitespace, code[0]);
    try testing.expect((code[0] & Class.whitespace) != 0);
    try testing.expect((code[1] & Class.digit) != 0);
    try testing.expect((code[1] & Class.ident_part) != 0);
    try testing.expect((code[1] & Class.ident_start) == 0);
    try testing.expect((code[2] & Class.ident_start) != 0);
    try testing.expect((code[2] & Class.digit) == 0);
    try testing.expect((code[3] & Class.quote) != 0);
    try testing.expect((code[4] & Class.punct) != 0);
    try testing.expect((code[5] & Class.ident_part) != 0); // 'x'
}

/// 收集全部候选起点（测试辅助）
fn collectStarts(starts: *const TokenStarts) []usize {
    var list: [1024]usize = undefined;
    var n: usize = 0;
    var pos: usize = 0;
    while (starts.nextAt(pos)) |p| {
        list[n] = p;
        n += 1;
        pos = p + 1;
    }
    return list[0..n];
}
