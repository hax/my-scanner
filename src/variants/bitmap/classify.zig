//! classify：产 6 张位图（word/st/opch/numch/misc/nl）+ kind 数组，两种实现：
//! - aarch64：nibble LUT（tbl1 inline asm）。查表结构对齐 oxc tables.rs 的
//!   build_merged_luts：每张 16B 表按「低 nibble 平面位并 / 高 nibble 行位并」
//!   分解 256 项集合，两表 AND 即精确成员判定（构造需无 nibble 冲突，
//!   comptime selfCheck 兜底）。比逐谓词比较链省 ~30% 指令，且补上 Zig 无法
//!   自动合成 vqtbl 的缺口（inline asm）。
//! - 其它架构：比较链回退（语义逐位一致，指令数略多）。分流见 classify；
//!   comptime arch 裁剪 + Zig 惰性分析保证非 aarch64 目标 codegen 完全
//!   看不到 NEON asm（tbl1/V16/wb_lut 等仅在 NEON 路径被引用）。

const std = @import("std");
const builtin = @import("builtin");
const simd = @import("../../simd.zig");
const vec = @import("vec.zig");
const bits = @import("bits.zig");

const Bitmaps = bits.Bitmaps;
const Kind = bits.Kind;
const Chunk = vec.Chunk;
const Mask = vec.Mask;
const splat = vec.splat;
const V16 = vec.V16;
const splat16 = vec.splat16;
const loadPad16 = vec.loadPad16;
const tbl1 = vec.tbl1;
const loadPad = vec.loadPad;

/// 平面位定义（wb 表）：bit0-5 word 分解、bit6 ws、bit7 space；digit=bit1
const WB_PLANES = struct {
    fn bit(c: u8) u8 {
        var b: u8 = 0;
        if (c == '$') b |= 1 << 0;
        if (c >= '0' and c <= '9') b |= 1 << 1;
        if (c >= 'A' and c <= 'O') b |= 1 << 2;
        if ((c >= 'P' and c <= 'Z') or c == '_') b |= 1 << 3;
        if (c >= 'a' and c <= 'o') b |= 1 << 4;
        if (c >= 'p' and c <= 'z') b |= 1 << 5;
        if ((c >= 0x09 and c <= 0x0d)) b |= 1 << 6;
        if (c == ' ') b |= 1 << 7;
        return b;
    }
};
/// 平面位定义（mrg 表）：**位面绑定 high-nibble 行**（oxc ROWS 同款
/// 构造）——opch 字符跨 4 个 hi 行，每行一个专属位，构造性无 nibble
/// 冲突：opch = bit0-3 任一、dot = bit4。
const MRG_PLANES = struct {
    fn bit(c: u8) u8 {
        var b: u8 = 0;
        if (c == '+' or c == '-' or c == '*' or c == '&' or c == '!' or c == '.') b |= 1 << 0; // h2 行
        if (c == '=' or c == '<' or c == '>' or c == '?') b |= 1 << 1; // h3 行
        if (c == '^') b |= 1 << 2; // h5 行
        if (c == '|') b |= 1 << 3; // h7 行
        if (c == '.') b |= 1 << 4; // dot
        return b;
    }
};

fn buildNibbleLut(comptime plane: anytype) struct { lo: V16, hi: V16 } {
    @setEvalBranchQuota(10000);
    var lo: [16]u8 = @splat(0);
    var hi: [16]u8 = @splat(0);
    var c: usize = 0;
    while (c < 256) : (c += 1) {
        const b = plane.bit(@intCast(c));
        lo[c & 15] |= b;
        hi[c >> 4] |= b;
    }
    // 自检：lo & hi 的 AND 必须精确还原每字节平面位（无 nibble 冲突）
    c = 0;
    while (c < 256) : (c += 1) {
        const got = lo[c & 15] & hi[c >> 4];
        const want = plane.bit(@intCast(c));
        if (got != want) @compileError("nibble LUT conflict at byte " ++ std.fmt.comptimePrint("{d}", .{c}));
    }
    return .{ .lo = lo, .hi = hi };
}

const wb_lut = buildNibbleLut(WB_PLANES);
const mrg_lut = buildNibbleLut(MRG_PLANES);

// ---------------------------------------------------------------------------
// 比较链分类原语：非 aarch64 的 classifyGeneric 回退使用（aarch64 上不被
// 引用，Zig 惰性分析零成本）。各谓词与 wb/mrg LUT 平面定义逐位等价。
// ---------------------------------------------------------------------------

inline fn wsBool(c: Chunk) @Vector(32, bool) {
    return (c == splat(' ')) | ((c >= splat(0x09)) & (c <= splat(0x0d)));
}

inline fn wordBool(c: Chunk) @Vector(32, bool) {
    const lower = (c >= splat('a')) & (c <= splat('z'));
    const upper = (c >= splat('A')) & (c <= splat('Z'));
    const digit = (c >= splat('0')) & (c <= splat('9'));
    return lower | upper | digit | (c == splat('_')) | (c == splat('$')) | (c >= splat(0x80));
}

/// 多字符标点潜在首字符（my-scanner dispatch 的 punct_multi：`=<>+-*%&|^!?.`）。
/// `/` 不在此（carve 三义处理后 `/=` 自并，普通 `/` 单字节）；`.` 在
/// （`...` 合并），事件处按 scanPunct 口径消化（`.5` 归数字）。
inline fn opchBool(c: Chunk) @Vector(32, bool) {
    var r: @Vector(32, bool) = c == splat('=');
    inline for ([_]u8{ '<', '>', '+', '-', '*', '%', '&', '|', '^', '!', '?', '.' }) |ch| {
        r |= c == splat(ch);
    }
    return r;
}

inline fn miscBool(c: Chunk) @Vector(32, bool) {
    return (c == splat('#')) | (c == splat('\\')) | (c >= splat(0x80));
}

/// classify 分流：aarch64 走 NEON tbl LUT（classifyNeon），其它架构回退
/// 比较链（classifyGeneric）。comptime arch 裁剪后另一实现不被引用，
/// 非 aarch64 目标 codegen 完全看不到 NEON asm。
pub fn classify(bm: *Bitmaps, src: []const u8) void {
    if (comptime builtin.target.cpu.arch == .aarch64) {
        classifyNeon(bm, src);
    } else {
        classifyGeneric(bm, src);
    }
}

fn classifyNeon(bm: *Bitmaps, src: []const u8) void {
    const n = src.len;
    const nb = (n + 63) / 64;
    var cw: u64 = 0;
    var cs: u64 = 0;
    var b: usize = 0;
    while (b < nb) : (b += 1) {
        const base = b * 64;
        var wordm: u64 = 0;
        var wsm: u64 = 0;
        var numch: u64 = 0;
        var opchm: u64 = 0;
        var miscm: u64 = 0;
        var nlm: u64 = 0;
        inline for (0..4) |seg| {
            const off = base + seg * 16;
            const v: V16 = loadPad16(src, off);
            const vn = v & splat16(0x0f);
            const vh = v >> @as(V16, @splat(4));
            const wb = tbl1(wb_lut.lo, vn) & tbl1(wb_lut.hi, vh);
            const mg = tbl1(mrg_lut.lo, vn) & tbl1(mrg_lut.hi, vh);
            const na: @Vector(16, bool) = v >= splat16(0x80);
            const ws_b: @Vector(16, bool) = (wb & splat16(0xc0)) != splat16(0);
            const word_b: @Vector(16, bool) = ((wb & splat16(0x3f)) != splat16(0)) | na;
            const digit_b: @Vector(16, bool) = (wb & splat16(0x02)) != splat16(0);
            const dot_b: @Vector(16, bool) = (mg & splat16(0x10)) != splat16(0);
            const opch_b: @Vector(16, bool) = ((mg & splat16(0x0f)) != splat16(0)) | dot_b;
            const misc_b: @Vector(16, bool) = (v == splat16('#')) | (v == splat16('\\')) | na;
            const nl_b: @Vector(16, bool) = (v == splat16('\n')) | (v == splat16('\r'));

            const w16: u16 = @bitCast(word_b);
            const s16: u16 = @bitCast(ws_b);
            const d16: u16 = @bitCast(digit_b);
            const t16m: u16 = @bitCast(dot_b);
            const o16: u16 = @bitCast(opch_b);
            const m16: u16 = @bitCast(misc_b);
            const l16: u16 = @bitCast(nl_b);
            const sh: u6 = @intCast(seg * 16);
            wordm |= @as(u64, w16) << sh;
            wsm |= @as(u64, s16) << sh;
            numch |= @as(u64, d16 | t16m) << sh;
            opchm |= @as(u64, o16) << sh;
            miscm |= @as(u64, m16) << sh;
            nlm |= @as(u64, l16) << sh;

            // kind：punct 为底 → word(identifier) → digit(number) →
            // \(illegal) → ws(whitespace)。`#` 恒单字节 punct（新口径，
            // 私有名合法性留 parser），不再单独标 kind
            const ki: V16 = @splat(@as(u8, @intFromEnum(Kind.identifier)));
            const kn: V16 = @splat(@as(u8, @intFromEnum(Kind.number)));
            const ke: V16 = @splat(@as(u8, @intFromEnum(Kind.illegal)));
            const ks: V16 = @splat(@as(u8, @intFromEnum(Kind.whitespace)));
            var k: V16 = @splat(@as(u8, @intFromEnum(Kind.punct)));
            k = @select(u8, word_b, ki, k);
            k = @select(u8, digit_b, kn, k);
            k = @select(u8, v == splat16('\\'), ke, k);
            k = @select(u8, ws_b, ks, k);
            bm.kind[off..][0..16].* = k;
        }
        const wordm2 = wordm;
        const wsm2 = wsm;
        bm.word[b] = wordm2;
        bm.numch[b] = numch;
        bm.opch[b] = opchm;
        bm.misc[b] = miscm;
        bm.nl[b] = nlm;

        const wprev = (wordm2 << 1) | cw;
        const sprev = (wsm2 << 1) | cs;
        cw = wordm2 >> 63;
        cs = wsm2 >> 63;
        bm.st[b] = (wsm2 & ~sprev) | (wordm2 & ~wprev) | (~wsm2 & ~wordm2);
    }
    // 尾块越读位清零（pad 0x7f 非 word 非 ws 非 opch 非 misc → st=1 幻影）
    const rem = n & 63;
    if (rem != 0) {
        const last = nb - 1;
        const m = (@as(u64, 1) << @intCast(rem)) - 1;
        bm.word[last] &= m;
        bm.st[last] &= m;
        bm.opch[last] &= m;
        bm.numch[last] &= m;
        bm.misc[last] &= m;
        bm.nl[last] &= m;
    }
}

/// 比较链版 classify（非 aarch64 回退）：与 classifyNeon 逐位同产出
/// （6 张位图 + kind 数组；谓词定义与 LUT 平面一一对应）。
fn classifyGeneric(bm: *Bitmaps, src: []const u8) void {
    const n = src.len;
    const nb = (n + 63) / 64;
    var cw: u64 = 0;
    var cs: u64 = 0;
    var b: usize = 0;
    while (b < nb) : (b += 1) {
        const base = b * 64;
        const c0 = loadPad(src, base);
        const c1 = loadPad(src, base + 32);

        const w0: Mask = @bitCast(wordBool(c0));
        const w1: Mask = @bitCast(wordBool(c1));
        const s0: Mask = @bitCast(wsBool(c0));
        const s1: Mask = @bitCast(wsBool(c1));
        const d0: Mask = @bitCast((c0 >= splat('0')) & (c0 <= splat('9')));
        const d1: Mask = @bitCast((c1 >= splat('0')) & (c1 <= splat('9')));
        const t0: Mask = @bitCast(c0 == splat('.'));
        const t1: Mask = @bitCast(c1 == splat('.'));
        const o0: Mask = @bitCast(opchBool(c0));
        const o1: Mask = @bitCast(opchBool(c1));
        const m0: Mask = @bitCast(miscBool(c0));
        const m1: Mask = @bitCast(miscBool(c1));
        const l0: Mask = @bitCast((c0 == splat('\n')) | (c0 == splat('\r')));
        const l1: Mask = @bitCast((c1 == splat('\n')) | (c1 == splat('\r')));

        const wordm = @as(u64, w1) << 32 | w0;
        const wsm = @as(u64, s1) << 32 | s0;
        bm.word[b] = wordm;
        bm.numch[b] = (@as(u64, d1) << 32 | d0) | (@as(u64, t1) << 32 | t0);
        bm.opch[b] = @as(u64, o1) << 32 | o0;
        bm.misc[b] = @as(u64, m1) << 32 | m0;
        bm.nl[b] = @as(u64, l1) << 32 | l0;

        const wprev = (wordm << 1) | cw;
        const sprev = (wsm << 1) | cs;
        cw = wordm >> 63;
        cs = wsm >> 63;
        bm.st[b] = (wsm & ~sprev) | (wordm & ~wprev) | (~wsm & ~wordm);

        bm.kind[base..][0..32].* = kindVecGeneric(c0);
        bm.kind[base + 32 ..][0..32].* = kindVecGeneric(c1);
    }
    // 尾块越读位清零（pad 0x7f 同上：st=1 幻影必须 mask 掉）
    const rem = n & 63;
    if (rem != 0) {
        const last = nb - 1;
        const m = (@as(u64, 1) << @intCast(rem)) - 1;
        bm.word[last] &= m;
        bm.st[last] &= m;
        bm.opch[last] &= m;
        bm.numch[last] &= m;
        bm.misc[last] &= m;
        bm.nl[last] &= m;
    }
}

/// kind 覆盖序（从底到顶，与 classifyNeon 内联版一致）：punct →
/// word(identifier) → digit(number) → `\`(illegal) → ws(whitespace)。
/// `#` 恒单字节 punct（新口径，私有名合法性留 parser），不单独标 kind。
inline fn kindVecGeneric(c: Chunk) @Vector(32, u8) {
    const V = @Vector(32, u8);
    var k: V = @splat(@intFromEnum(Kind.punct));
    k = @select(u8, wordBool(c), @as(V, @splat(@intFromEnum(Kind.identifier))), k);
    k = @select(u8, (c >= splat('0')) & (c <= splat('9')), @as(V, @splat(@intFromEnum(Kind.number))), k);
    k = @select(u8, c == splat('\\'), @as(V, @splat(@intFromEnum(Kind.illegal))), k);
    k = @select(u8, wsBool(c), @as(V, @splat(@intFromEnum(Kind.whitespace))), k);
    return k;
}
