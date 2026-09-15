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
/// 多字节空白（U+00A0 等）由 scanner 层的 Unicode whitespace 修正处理。
pub inline fn whitespaceMask(chunk: Chunk) Mask {
    const space = chunk == splat(' ');
    const control = (chunk >= splat('\t')) & (chunk <= splat('\r'));
    return @bitCast(space | control);
}

pub inline fn newlineMask(chunk: Chunk) Mask {
    return @bitCast(chunk == splat('\n'));
}

/// 标识符后续字符 [A-Za-z0-9_$]（ASCII 平面；非 ASCII 由 scanner 层
/// 解码并查 ID_Continue 范围表续扫）。
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

/// ECMAScript 的非 ASCII whitespace（19 个码点，含 U+FEFF 与行终止符
/// U+2028/U+2029）。从 i 起若是其中之一，返回其 UTF-8 字节数。
/// 前缀集合由 docs/unicode_utf8_prefixes.js 校验（首字节 C2 E1 E2 E3 EF）。
pub fn unicodeWhitespaceLen(src: []const u8, i: usize) ?usize {
    const s = src;
    if (i + 1 >= s.len) return null;
    switch (s[i]) {
        0xC2 => return if (s[i + 1] == 0xA0) 2 else null, // U+00A0
        0xE1 => return if (i + 2 < s.len and s[i + 1] == 0x9A and s[i + 2] == 0x80) 3 else null, // U+1680
        0xE2 => {
            if (i + 2 >= s.len) return null;
            switch (s[i + 1]) {
                0x80 => return switch (s[i + 2]) {
                    // U+2000..U+200A, U+2028, U+2029, U+202F
                    0x80...0x8A, 0xA8, 0xA9, 0xAF => 3,
                    else => null,
                },
                0x81 => return if (s[i + 2] == 0x9F) 3 else null, // U+205F
                else => return null,
            }
        },
        0xE3 => return if (i + 2 < s.len and s[i + 1] == 0x80 and s[i + 2] == 0x80) 3 else null, // U+3000
        0xEF => return if (i + 2 < s.len and s[i + 1] == 0xBB and s[i + 2] == 0xBF) 3 else null, // U+FEFF
        else => return null,
    }
}

inline fn eqMask(chunk: Chunk, c: u8) Mask {
    return @bitCast(chunk == splat(c));
}

inline fn highByteMask(chunk: Chunk) Mask {
    return @bitCast(chunk >= splat(0x80));
}

/// Unicode whitespace 码点可能的首字节
inline fn unicodeWsLeadMask(chunk: Chunk) Mask {
    var m: Mask = 0;
    inline for ([_]u8{ 0xC2, 0xE1, 0xE2, 0xE3, 0xEF }) |c| m |= eqMask(chunk, c);
    return m;
}

/// 本块开头是否悬挂着跨块 Unicode whitespace 码点的尾部：
/// 返回该码点在本块内的字节数（1 或 2），0 表示没有。
/// 直接读块首前两字节（i >= 2 恒成立——第一块 i=0 由调用方排除），
/// 免去跨块 prev 状态机的每块两次载入。
pub fn danglingUnicodeWs(src: []const u8, i: usize) usize {
    if (i < 2) return 0;
    const prev1 = src[i - 1];
    const prev2 = src[i - 2];
    const s = src;
    if (i >= s.len) return 0;
    // prev1 是码点首字节（2 字节码点差 1 字节；3 字节码点差 2 字节）
    switch (prev1) {
        0xC2 => return if (s[i] == 0xA0) 1 else 0,
        0xE1 => return if (i + 1 < s.len and s[i] == 0x9A and s[i + 1] == 0x80) 2 else 0,
        0xE2 => {
            if (s[i] == 0x80) {
                if (i + 1 >= s.len) return 0;
                return switch (s[i + 1]) {
                    0x80...0x8A, 0xA8, 0xA9, 0xAF => 2,
                    else => 0,
                };
            }
            if (s[i] == 0x81) {
                return if (i + 1 < s.len and s[i + 1] == 0x9F) 2 else 0;
            }
        },
        0xE3 => return if (i + 1 < s.len and s[i] == 0x80 and s[i + 1] == 0x80) 2 else 0,
        0xEF => return if (i + 1 < s.len and s[i] == 0xBB and s[i + 1] == 0xBF) 2 else 0,
        else => {},
    }
    // prev2 是首字节、prev1 是第二字节，本块首字节收尾
    // （E2 80 分支曾在一次清理中被误删，由随机交叉验证抓回——
    // 它覆盖 U+2000..U+200A/U+2028/U+2029/U+202F 的跨块形态）
    if (prev2 == 0xE2 and prev1 == 0x80) {
        return switch (s[i]) {
            0x80...0x8A, 0xA8, 0xA9, 0xAF => 1,
            else => 0,
        };
    }
    if (prev2 == 0xE1 and prev1 == 0x9A and s[i] == 0x80) return 1;
    if (prev2 == 0xE2 and prev1 == 0x81 and s[i] == 0x9F) return 1;
    if (prev2 == 0xE3 and prev1 == 0x80 and s[i] == 0x80) return 1;
    if (prev2 == 0xEF and prev1 == 0xBB and s[i] == 0xBF) return 1;
    return 0;
}

/// 阶段 1 主体（boundary v2，见 docs/simd-token-boundary-prefilter.md）：
/// 用「连接关系」推出候选起点位图——字节 i 之后不可切，当且仅当
/// (after[i] & before[i+1]) != 0。当前只启用 ID 连接：
///   ID : [A-Za-z0-9_$] 之间，以及一切 >= 0x80 的字节（UTF-8 码点内部
///        与非空白码点之间按 ID-like 处理；Unicode whitespace 由修正摘出）
/// OP/ESC 连接（docs/simd-token-boundary-prefilter.md 的完整四位关系）
/// 经实测为负收益——多字节 punctuator 与转义对中间的假候选由阶段 2 的
/// pos 跳过兜底，粗筛精化不划算；它们留给将来 candidate 免验证的激进
/// 阶段 2。WS：本 scanner 不产 whitespace token，ASCII 空白整体排除。
/// 逻辑换行（\n、孤立 \r、U+2028/U+2029）在同一 pass 计数。
pub fn classifyTokenStarts(
    allocator: std.mem.Allocator,
    src: []const u8,
) !struct { starts: TokenStarts, line_breaks: []u32, newlines: usize } {
    const nblocks = (src.len + block_size - 1) / block_size;
    const masks = try allocator.alloc(u32, nblocks);
    errdefer allocator.free(masks);
    const line_breaks = try allocator.alloc(u32, nblocks);
    errdefer allocator.free(line_breaks);

    var newlines: usize = 0;
    // 跨块状态：id after 平面的末字节（bit0 位置 = 前一字节的 after）
    var carry_id: u32 = 0;
    var carry_lf: u32 = 0;
    // 前块末字节是否 \r：若是且本块首是 \n，前块尾 \r 的乐观换行标记要回改
    var prev_was_cr = false;

    for (masks, 0..) |*out, bi| {
        const i = bi * block_size;
        const chunk = load(src, i);
        const rem = src.len - i;
        const valid: u32 = if (rem >= block_size)
            std.math.maxInt(u32)
        else
            (@as(u32, 1) << @intCast(rem)) - 1;

        // ID：ASCII 标识符字符 + 一切 >= 0x80（Unicode whitespace 待修正）。
        // OP/ESC 连接关系经实测负收益（见 docs/class-code-and-simd-lookup.md
        // 的 boundary v2 实验），其价值留给将来「candidate 免验证」的激进阶段 2。
        const high = highByteMask(chunk);
        var id_after = identPartMask(chunk) | high;
        var id_before = id_after;
        const ws = whitespaceMask(chunk); // ASCII 空白整体排除

        // Unicode whitespace 修正——必须在 impossible 合成之前改 id 平面，
        // 否则清掉的连接不生效（会把码点后的真实边界一起挤掉）。
        // 只做连接修正：首字节对外断 ID-before、末字节对外断 ID-after
        // （码点内部保持 ID 连接）。码点本身不排除出候选——统一由
        // 阶段 2 在 lead 处产 .whitespace token（跨块码点的尾部字节
        // 会被消费后的 pos 越过，无需排除）。
        // 纯 ASCII 块（且前块末尾无悬挂）整体跳过——corpus 大多是这种。
        var brk_marked: u32 = 0;
        if (high != 0 or (i >= 1 and src[i - 1] >= 0x80) or (i >= 2 and src[i - 2] >= 0x80)) {
            // 跨块悬挂：lead 在前块、末字节在本块开头，清其 id_after
            const dangle = danglingUnicodeWs(src, i);
            if (dangle != 0) {
                id_after &= ~(@as(u32, 1) << @intCast(dangle - 1));
                // 悬挂的是 U+2028/29（末字节 A8/A9 精确对应）则 break 位
                // 标在末字节位置
                if (src[i + dangle - 1] == 0xA8 or src[i + dangle - 1] == 0xA9) {
                    brk_marked = @as(u32, 1) << @intCast(dangle - 1);
                }
            }

            // 码点修正：lead 的 before 断连无条件做（lead 必在本块），
            // 这保证跨块码点的 lead 也满足「恒候选」语义（与标量版一致）；
            // 末字节的 after 断连只在码点完整落于本块时做，跨块的
            // 由下一块的悬挂修正负责
            var lead = unicodeWsLeadMask(chunk) & valid;
            while (lead != 0) {
                const p: u5 = @intCast(@ctz(lead));
                lead &= lead - 1;
                if (unicodeWhitespaceLen(src, i + p)) |len| {
                    id_before &= ~(@as(u32, 1) << p);
                    if (@as(usize, p) + len <= block_size and i + p + len <= src.len) {
                        id_after &= ~(@as(u32, 1) << @intCast(p + len - 1));
                    }
                }
            }
        }

        // impossible 位 j = after[j-1] & before[j]：左移 after 平面对齐，
        // carry 是前块末字节的 after（跨块连接）。
        // （注意方向：旧版 ident 因 after/before 对称侥幸不受影响；
        // ws 修正把两面分开后必须移对侧。）
        const impossible = ((id_after << 1) | carry_id) & id_before;

        out.* = ~ws & ~impossible & valid;

        carry_id = id_after >> (block_size - 1);

        // 逻辑换行位图（位标记在行终止字节）：\n、孤立 \r（下一字节非
        // \n，CRLF 只在 \n 计一次）、U+2028/U+2029
        const lf = eqMask(chunk, '\n');
        const cr = eqMask(chunk, '\r');
        const lf_next = (lf >> 1) | carry_lf; // i+1 是 \n：右移对齐到 \r 的位
        var brk = (lf | (cr & ~lf_next)) & valid;
        // 跨块 CRLF：前块尾 \r 被乐观标记为换行，本块首是 \n 则回改
        if (bi > 0 and prev_was_cr and rem >= 1 and src[i] == '\n') {
            line_breaks[bi - 1] &= ~(@as(u32, 1) << (block_size - 1));
            newlines -= 1;
        }
        carry_lf = lf >> (block_size - 1);
        prev_was_cr = (cr & valid & (@as(u32, 1) << (block_size - 1))) != 0;

        // U+2028/U+2029：块内完整（E2 80 A8/A9），位标记在末字节。
        // 中文密集块（E4-E9）大多无 E2：先用一个 eq 探 E2，命中才做
        // m80/a8a9 的两个 eq——cn-dense 类语料省两条
        if (high != 0 and (eqMask(chunk, 0xE2) & valid) != 0) {
            const e2 = eqMask(chunk, 0xE2);
            const m80 = eqMask(chunk, 0x80);
            const a8a9 = eqMask(chunk, 0xA8) | eqMask(chunk, 0xA9);
            brk |= ((e2 << 2) & (m80 << 1) & a8a9) & valid;
        }
        // 跨块 U+2028/29 收尾（E2 80 在前块尾、A8/A9 在本块首）
        if (i >= 2 and src[i - 2] == 0xE2 and src[i - 1] == 0x80 and rem >= 1 and
            (src[i] == 0xA8 or src[i] == 0xA9))
        {
            brk |= 1;
        }
        brk |= brk_marked;
        line_breaks[bi] = brk;
        newlines += @as(usize, @popCount(brk));
    }

    return .{ .starts = .{ .masks = masks }, .line_breaks = line_breaks, .newlines = newlines };
}

/// classifyTokenStarts 的标量对照实现：逐码点状态机，语义与 SIMD 版完全
/// 一致（ID-like 连接、Unicode whitespace 修正、逻辑换行）。
/// 用途：交叉验证 SIMD 版正确性 + bench 量化 SIMD 的贡献（A/B）。
/// 逐码点处理天然无块边界，跨块悬挂逻辑在此不存在。
pub const ClassifyResult = struct {
    starts: TokenStarts,
    line_breaks: []u32,
    newlines: usize,
};

pub fn classifyTokenStartsScalar(
    allocator: std.mem.Allocator,
    src: []const u8,
) !ClassifyResult {
    const nblocks = (src.len + block_size - 1) / block_size;
    const masks = try allocator.alloc(u32, nblocks);
    errdefer allocator.free(masks);
    const line_breaks = try allocator.alloc(u32, nblocks);
    errdefer allocator.free(line_breaks);
    @memset(masks, 0);
    @memset(line_breaks, 0);

    var prev_after_id = false; // 前一码点的 ID after
    var i: usize = 0;
    var newlines: usize = 0;
    while (i < src.len) {
        const c = src[i];
        const bit = @as(u32, 1) << @intCast(i % block_size);
        const bi = i / block_size;
        var adv: usize = 1;
        var after_id = false;
        var before_id = false;
        var is_break = false;
        var candidate: ?bool = null; // null = 按连接规则推导

        if (c < 0x80) {
            const ws = c == ' ' or (c >= 0x09 and c <= 0x0D);
            const idp = !ws and isIdentPart(c);
            after_id = idp;
            before_id = idp;
            if (candidate == null) candidate = !ws and !(prev_after_id and before_id);
            is_break = c == '\n' or
                (c == '\r' and !(i + 1 < src.len and src[i + 1] == '\n'));
        } else if (unicodeWhitespaceLen(src, i)) |len| {
            // Unicode whitespace 码点：lead 恒为候选（连接已被码点断开，
            // 阶段 2 统一在 lead 产 whitespace token），其余字节跳过；
            // 码点对外不建立 ID 连接；U+2028/29 的 break 位标记在末字节
            adv = len;
            candidate = true;
            if (len == 3 and src[i + 1] == 0x80 and
                (src[i + 2] == 0xA8 or src[i + 2] == 0xA9))
            {
                const e = i + len - 1;
                line_breaks[e / block_size] |= @as(u32, 1) << @intCast(e % block_size);
                newlines += 1;
            }
        } else {
            // 非 ws 非 ASCII：ID-like，逐字节判定（SIMD 版的连接是字节级的，
            // 截断/非法序列的每个字节独立参与连接，不能按码点长度跳）
            after_id = true;
            before_id = true;
            candidate = !(prev_after_id and before_id);
        }

        if (candidate.?) masks[bi] |= bit;
        if (is_break) {
            line_breaks[bi] |= bit;
            newlines += 1;
        }
        prev_after_id = after_id;
        i += adv;
    }
    return .{ .starts = .{ .masks = masks }, .line_breaks = line_breaks, .newlines = newlines };
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
    defer testing.allocator.free(r.line_breaks);
    try testing.expectEqualSlices(usize, &.{ 0, 4, 6, 8, 10 }, collectStarts(&r.starts));
    try testing.expectEqual(@as(usize, 0), r.newlines);
}

test "classifyTokenStarts：标识符中间字节不算候选" {
    // a1b 是一个标识符：只有 0 是候选；.5 从 '.' 起算（'5' 也是候选，
    // 属于被阶段 2 贪心消费越过的假候选）
    const src = "a1b .5 x_1";
    var r = try classifyTokenStarts(testing.allocator, src);
    defer r.starts.deinit(testing.allocator);
    defer testing.allocator.free(r.line_breaks);
    try testing.expectEqualSlices(usize, &.{ 0, 4, 5, 7 }, collectStarts(&r.starts));
}

test "classifyTokenStarts：字符串内部字节是假候选（阶段 2 越过）" {
    // "a b" 内的 a、b、闭引号都是候选，但属于 string token 区间或紧邻
    const src = "\"a b\" x";
    var r = try classifyTokenStarts(testing.allocator, src);
    defer r.starts.deinit(testing.allocator);
    defer testing.allocator.free(r.line_breaks);
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
    defer testing.allocator.free(r.line_breaks);
    // 每块首字节（0、32、64）是候选，其余标识符中间字节都不是
    try testing.expectEqualSlices(usize, &.{ 0, block_size, block_size * 2 }, collectStarts(&r.starts));
    try testing.expectEqual(@as(usize, 1), r.newlines);
}

test "classifyTokenStarts：空文件与纯空白" {
    {
        var r = try classifyTokenStarts(testing.allocator, "");
        defer r.starts.deinit(testing.allocator);
        defer testing.allocator.free(r.line_breaks);
        try testing.expectEqual(@as(?usize, null), r.starts.nextAt(0));
    }
    {
        var r = try classifyTokenStarts(testing.allocator, "  \n\t ");
        defer r.starts.deinit(testing.allocator);
        defer testing.allocator.free(r.line_breaks);
        try testing.expectEqual(@as(?usize, null), r.starts.nextAt(0));
    }
}

test "classifyTokenStarts：nextAt 从任意位置起查" {
    const src = "a b  c";
    var r = try classifyTokenStarts(testing.allocator, src);
    defer r.starts.deinit(testing.allocator);
    defer testing.allocator.free(r.line_breaks);
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

test "classifyTokenStarts 与标量版交叉验证" {
    const cases = [_][]const u8{
        "",
        "a",
        "let x = 42;",
        "a==b;a%=b;a**b;\\\"x\\\"",
        "  \t\n  \r\n  \r  ",
        "a\u{2028}b\u{2029}c",
        "let \u{53d8}\u{91cf} = 1;",
        "\u{00a0}a\u{3000}b\u{feff}",
        "a\u{4e2d}b \u{2603} c",
        // 跨块 U+2003/U+2028（E2 80 恰在块尾、末字节在块首）——防回归
        "a" ** 30 ++ "\u{2003}\u{00a0}x",
        "b" ** 31 ++ "\u{2028}y",
        "c" ** 30 ++ "\u{2029}\u{2000}z",
        "x\\y", // 反斜杠
        "// comment\n/* block */ a",
    };
    for (cases) |src| {
        const simd_r = try classifyTokenStarts(testing.allocator, src);
        defer {
            var s0 = simd_r;
            s0.starts.deinit(testing.allocator);
        }
        defer testing.allocator.free(simd_r.line_breaks);
        var scalar_r = try classifyTokenStartsScalar(testing.allocator, src);
        defer scalar_r.starts.deinit(testing.allocator);
        defer testing.allocator.free(scalar_r.line_breaks);
        testing.expectEqualSlices(u32, scalar_r.starts.masks, simd_r.starts.masks) catch |e| {
            std.debug.print("masks 不一致: {s}\n", .{src});
            return e;
        };
        testing.expectEqualSlices(u32, scalar_r.line_breaks, simd_r.line_breaks) catch |e| {
            std.debug.print("line_breaks 不一致: {s}\n", .{src});
            return e;
        };
        try testing.expectEqual(scalar_r.newlines, simd_r.newlines);
    }
}

test "classifyTokenStarts 与标量版随机交叉验证" {
    // 确定性 PRNG 生成含多字节前缀的字节流，两版必须逐位一致
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();
    const alphabet = "abc $_=\n\r\t/\\\"\u{4e2d}\u{00a0}\u{2028}\u{2603}\u{e4}x";
    var buf: [512]u8 = undefined;
    for (0..200) |_| {
        const n = rand.intRangeAtMost(usize, 0, buf.len);
        for (buf[0..n]) |*b| b.* = alphabet[rand.intRangeAtMost(usize, 0, alphabet.len - 1)];
        const src = buf[0..n];
        const simd_r = try classifyTokenStarts(testing.allocator, src);
        var s0 = simd_r;
        defer s0.starts.deinit(testing.allocator);
        defer testing.allocator.free(simd_r.line_breaks);
        var scalar_r = try classifyTokenStartsScalar(testing.allocator, src);
        defer scalar_r.starts.deinit(testing.allocator);
        defer testing.allocator.free(scalar_r.line_breaks);
        testing.expectEqualSlices(u32, scalar_r.starts.masks, simd_r.starts.masks) catch |e| {
            for (scalar_r.starts.masks, simd_r.starts.masks, 0..) |sm, vm, b| {
                if (sm != vm) {
                    const d = sm ^ vm;
                    const off = b * block_size + @ctz(d);
                    std.debug.print("masks diff @block {d} bit {d} (offset {d}): scalar={b:0>8} simd={b:0>8}\nsrc={any}\nbytes near: {any}\n", .{ b, @ctz(d), off, sm, vm, src, src[off - @min(off, 8) .. @min(off + 12, src.len)] });
                    break;
                }
            }
            return e;
        };
        testing.expectEqualSlices(u32, scalar_r.line_breaks, simd_r.line_breaks) catch |e| {
            for (scalar_r.line_breaks, simd_r.line_breaks, 0..) |sb, vb, b| {
                if (sb != vb) {
                    const d = sb ^ vb;
                    const off = b * block_size + @ctz(d);
                    std.debug.print("line_breaks diff @block {d} bit {d} (offset {d}): scalar={b:0>8} simd={b:0>8}\nbytes: {any}\n", .{ b, @ctz(d), off, sb, vb, src[@min(off, 6)..@min(off + 10, src.len)] });
                    break;
                }
            }
            return e;
        };
        try testing.expectEqual(scalar_r.newlines, simd_r.newlines);
    }
}
