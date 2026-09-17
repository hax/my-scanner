//! bitmap 变体 —— oxc_lexer 式位图流水线（arm64 NEON）。
//!
//! 架构移植自 oxc 主仓孵化的 oxc_lexer 实验 crate（六趟 unfused 流水线，
//! 见 docs/oxc-bitmap-neon-experiment.md）：classify 一次 SIMD 产出块位图
//! + 每字节 kind，后续 pass 只在字面量 opener / 多字符 token 事件处回读
//! 字节，最后 compress 从位图批量搬运 lexeme。与 oxc 版的关键差异：
//!
//! 1. 语义层完全复用 my-scanner（scanString/scanTemplatePart/scanNumber/
//!    scanPunct/scanRegex/isKeyword——tsc 差分测试口径），而不是 oxc 的
//!    disambiguate 自决体系；正则决策用位图版 regexAllowedAfter（见下，
//!    对齐 scanner.regexAllowedAfter 的双回看口径，prev/prev2 文本从
//!    位图现场重建）。
//! 2. NEON 没有 movemask/pshufb 等价单指令（Zig/LLVM 也不合成 vqtbl），
//!    位图提取走 LLVM 对 `@bitCast(bool vector → int)` 的 zip+addv
//!    lowering；classify 的 nibble LUT 查表用 inline asm vqtbl1q 补齐
//!    （仅 aarch64——其它架构回退到比较链 classify，见 classify 分流）。
//! 3. 位图 6 张：word/st/opch/numch(digit|dot)/misc/nl。ws 不落盘（st
//!    构造后即弃）；nl（\n、\r + miscPass 补 U+2028/29）服务交付口径的
//!    newline_before flag（trivia 不落盘，换行压成 1 bit 挂到下一个显著
//!    lexeme）。粗流不再区分 keyword/identifier（全归 identifier），
//!    oxc 的 kwinit 位图与 keywords pass 一并取消——`/` 判别按文本现查。
//!
//! 模板拆片（head/middle/tail）下的 carve：opener 扫描只经 `` ` `` 起
//! 模板 part（scanTemplatePart），`${` 后进入 TemplateStack 跟踪模式
//! （opener 之外还找 `{`/`}`），花括号计数归零的 `}` 是续片起点——与
//! scanner.scanAt 同一口径，位图 pass 结构不变。
//!
//! lexeme 端点语义：end = 位图上下一个 st 位的位置（stage 流配对，与
//! oxc build_spans 同构；st 位图在 n 处放 sentinel 保证末 lexeme 有配对）。
//! 恒成立的原因：任何 lexeme 尾之后必然是下一 lexeme 起点、trivia 起点
//! 或 EOF，而这三者都有 st 位。
//!
//! 约定：bmClearRange 是 [from, to)（zig 风格）；oxc 原文的
//! bm_clear_range 是 inclusive [from, to]，移植时调用点统一 +1。

const std = @import("std");
const builtin = @import("builtin");
const lexeme_mod = @import("../lexeme.zig");
const scanner = @import("../scanner.zig");
const simd = @import("../simd.zig");
const unicode = @import("../unicode.zig");

const Lexeme = lexeme_mod.Lexeme;
const LexemeKind = lexeme_mod.LexemeKind;
const TemplateStack = scanner.TemplateStack;

/// 位图 kind 数组的内部标签：前段与 LexemeKind 同序同值（compress 对显著
/// lexeme 直接 @enumFromInt 成 LexemeKind，零映射成本），后段两个是 trivia
/// 内部标记——新交付口径 trivia 不落盘，compress 一律跳过。
const Kind = enum(u8) {
    eof,
    identifier,
    number,
    string,
    regex,
    punct,
    shebang,
    illegal,
    no_substitution_template,
    template_head,
    template_middle,
    template_tail,
    whitespace,
    comment,
};

comptime {
    for (std.meta.tags(LexemeKind)) |k| {
        if (@intFromEnum(k) != @intFromEnum(@field(Kind, @tagName(k))))
            @compileError("Kind 前段必须与 LexemeKind 同序同值: " ++ @tagName(k));
    }
}

const Chunk = simd.Chunk; // @Vector(32, u8)
const Mask = simd.Mask; // u32

fn splat(c: u8) Chunk {
    return @splat(c);
}

const V16 = @Vector(16, u8);

inline fn splat16(c: u8) V16 {
    return @splat(c);
}

/// 16B 版尾块安全加载（越界填 0x7f）
inline fn loadPad16(src: []const u8, i: usize) V16 {
    if (i + 16 <= src.len) return src[i..][0..16].*;
    var buf: [16]u8 = @splat(0x7f);
    if (i < src.len) {
        const k = @min(16, src.len - i);
        @memcpy(buf[0..k], src[i..][0..k]);
    }
    return buf;
}

/// vqtbl1q：16B 表内动态查表（pshufb 的 NEON 等价）。与 pshufb 的差异：
/// 索引 ≥16 输出 0（pshufb 按 16 取模）——nibble 分解查找时索引须 & 15。
pub inline fn tbl1(table: V16, idx: V16) V16 {
    return asm ("tbl %[ret].16b, { %[tab].16b }, %[idx].16b"
        : [ret] "=w" (-> V16),
        : [tab] "w" (table),
          [idx] "w" (idx),
    );
}

// ---------------------------------------------------------------------------
// 位图容器：每 64 字节块一个 u64 word（多 1 word 给 n 处 sentinel），
// kind 每字节一个 u8（长度补齐到 64 倍数再 +64，尾块向量整存 + sentinel）
// ---------------------------------------------------------------------------

pub const Bitmaps = struct {
    word: []u64,
    st: []u64,
    opch: []u64,
    numch: []u64, // digit | dot
    misc: []u64,
    nl: []u64, // 行终止字节：\n、\r（classify）+ U+2028/29（miscPass）
    kind: []u8,
    n: usize,

    pub fn alloc(allocator: std.mem.Allocator, n: usize) !Bitmaps {
        const nb = (n + 63) / 64 + 1; // +1：sentinel 位 n 与越界读兜底 word
        const bm = Bitmaps{
            .word = try allocator.alloc(u64, nb),
            .st = try allocator.alloc(u64, nb),
            .opch = try allocator.alloc(u64, nb),
            .numch = try allocator.alloc(u64, nb),
            .misc = try allocator.alloc(u64, nb),
            .nl = try allocator.alloc(u64, nb),
            .kind = try allocator.alloc(u8, nb * 64),
            .n = n,
        };
        // 位图 word [0, ceil(n/64)) 由 classify 全量写入；只有兜底 word
        // （bmNext0/bmNext1 越界读会触达）需要清零
        bm.word[nb - 1] = 0;
        bm.st[nb - 1] = 0;
        bm.opch[nb - 1] = 0;
        bm.numch[nb - 1] = 0;
        bm.misc[nb - 1] = 0;
        bm.nl[nb - 1] = 0;
        return bm;
    }

    pub fn deinit(self: *Bitmaps, allocator: std.mem.Allocator) void {
        allocator.free(self.word);
        allocator.free(self.st);
        allocator.free(self.opch);
        allocator.free(self.numch);
        allocator.free(self.misc);
        allocator.free(self.nl);
        allocator.free(self.kind);
    }
};

/// 低 n 位全 1 掩码（n=64 → 全 1；避免 1<<64 溢出）
inline fn lowBits(n: usize) u64 {
    if (n >= 64) return ~@as(u64, 0);
    return (@as(u64, 1) << @intCast(n)) - 1;
}

inline fn bmGet(bm: []const u64, i: usize) bool {
    return (bm[i >> 6] >> @intCast(i & 63)) & 1 != 0;
}

inline fn bmSet(bm: []u64, i: usize) void {
    bm[i >> 6] |= @as(u64, 1) << @intCast(i & 63);
}

inline fn bmClear(bm: []u64, i: usize) void {
    bm[i >> 6] &= ~(@as(u64, 1) << @intCast(i & 63));
}

/// 清空 [from, to)
fn bmClearRange(bm: []u64, from: usize, to: usize) void {
    if (to <= from) return;
    const wf = from >> 6;
    const wt = (to - 1) >> 6;
    if (wf == wt) {
        const m = lowBits(to - from) << @intCast(from & 63);
        bm[wf] &= ~m;
        return;
    }
    bm[wf] &= lowBits(from & 63);
    for (bm[wf + 1 .. wt]) |*w| w.* = 0;
    bm[wt] &= ~lowBits(to - (wt << 6)); // 1..64
}

/// [from, to) 内是否有置位
fn bmAny(bm: []const u64, from: usize, to: usize) bool {
    if (to <= from) return false;
    var w = from >> 6;
    const wt = (to - 1) >> 6;
    const cur0 = bm[w] >> @intCast(from & 63);
    if (w == wt) {
        return cur0 & lowBits(to - from) != 0;
    }
    if (cur0 != 0) return true;
    w += 1;
    while (w < wt) : (w += 1) {
        if (bm[w] != 0) return true;
    }
    return bm[wt] & lowBits(to - (wt << 6)) != 0;
}

/// 下一个置位位（i 起含 i）；逻辑长度 limit（位 i < limit），找不到返回 null
fn bmNext1(bm: []const u64, i: usize, limit: usize) ?usize {
    var w = i >> 6;
    const wt = (limit + 63) >> 6;
    var cur = bm[w] >> @intCast(i & 63); // 首字先对齐到 i，ctz 是段内偏移
    var add: usize = i & 63;
    while (true) {
        if (cur != 0) {
            const pos = (w << 6) + add + @ctz(cur);
            return if (pos < limit) pos else null;
        }
        w += 1;
        if (w >= wt) return null;
        cur = bm[w];
        add = 0;
    }
}

/// 上一个置位位（< i），找不到返回 null
fn bmPrev1(bm: []const u64, i: usize) ?usize {
    if (i == 0) return null;
    var w = (i - 1) >> 6;
    // 保留 [w<<6, i) 的位；i 恰为 64 倍数时整 word（避免 1<<64 溢出）
    var cur = bm[w] & lowBits(i - (w << 6)); // 1..64
    while (true) {
        if (cur != 0) return (w << 6) + 63 - @clz(cur);
        if (w == 0) return null;
        w -= 1;
        cur = bm[w];
    }
}

/// 下一个 0 位（i 起含 i）；永不失败（容器尾部多 1 word 全 0）
fn bmNext0(bm: []const u64, i: usize) usize {
    var w = i >> 6;
    var cur = ~bm[w] >> @intCast(i & 63); // 首字对齐到 i，ctz 是段内偏移
    var add: usize = i & 63;
    while (true) {
        if (cur != 0) return (w << 6) + add + @ctz(cur);
        w += 1;
        cur = ~bm[w];
        add = 0;
    }
}

// ---------------------------------------------------------------------------
// classify：产 6 张位图（word/st/opch/numch/misc/nl）+ kind 数组，两种实现：
// - aarch64：nibble LUT（tbl1 inline asm）。查表结构对齐 oxc tables.rs 的
//   build_merged_luts：每张 16B 表按「低 nibble 平面位并 / 高 nibble 行位并」
//   分解 256 项集合，两表 AND 即精确成员判定（构造需无 nibble 冲突，
//   comptime selfCheck 兜底）。比逐谓词比较链省 ~30% 指令，且补上 Zig 无法
//   自动合成 vqtbl 的缺口（inline asm）。
// - 其它架构：比较链回退（语义逐位一致，指令数略多）。分流见 classify；
//   comptime arch 裁剪 + Zig 惰性分析保证非 aarch64 目标 codegen 完全
//   看不到 NEON asm（tbl1/V16/wb_lut 等仅在 NEON 路径被引用）。
// ---------------------------------------------------------------------------

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

/// 尾块安全加载：越界部分填 0x7f（不命中任何分类位图；st 幻影由
/// classify 的 rem mask 清除）。i > src.len 时返回全 pad。
inline fn loadPad(src: []const u8, i: usize) Chunk {
    if (i + 32 <= src.len) return src[i..][0..32].*;
    var buf: [32]u8 = @splat(0x7f);
    if (i < src.len) {
        const k = @min(32, src.len - i);
        @memcpy(buf[0..k], src[i..][0..k]);
    }
    return buf;
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

// ---------------------------------------------------------------------------
// misc pass：unicode（空白拆位 / ID_Start 保留 / illegal 拆位）、`\`
// ---------------------------------------------------------------------------

pub fn miscPass(bm: *Bitmaps, src: []const u8) void {
    const n = src.len;
    var i: usize = 0;
    while (bmNext1(bm.misc, i, n)) |j| {
        i = j + 1;
        const c = src[j];
        if (c >= 0x80) {
            i = j + miscUnicode(bm, src, j);
            continue;
        } else if (c == '\\') {
            miscBackslash(bm, src, j);
        }
        // `#`：恒单字节 punct（新口径），位图已就位，无需处理
    }
}

/// 非 ASCII 字节 j（对齐 scanNonAscii 语义）；返回应跳过的字节数
/// （整码点——续字节也在 misc 位图里，不跳会被单独误判）
fn miscUnicode(bm: *Bitmaps, src: []const u8, j: usize) usize {
    const n = src.len;
    // unicode 空白（含 U+2028/29）：从 word 摘出、标 trivia kind、补断点 st；
    // U+2028/29 是行终止符（trivia 不落盘，newline_before flag 靠 nl 位图）
    if (simd.unicodeWhitespaceLen(src, j)) |len| {
        if (scanner.wsIsLineTerminator(src, j)) bmSet(bm.nl, j);
        setTriviaRange(bm, j, @min(j + len, n));
        return len;
    }
    const lead = src[j];
    const len = std.unicode.utf8ByteSequenceLength(lead) catch {
        // 非 UTF-8 起始字节：单字节 illegal
        setIllegalRange(bm, j, 1);
        return 1;
    };
    // CJK 快路径：0xE4..0xE9 开头的 3 字节码点全部位于 CJK 统一表意文字
    // 区（U+4E00..U+9FFF，ID_Start）——真实中文标识符的绝大多数，免 decode。
    // 对齐 decode 的合法性前提：续字节须是 0x80..0xBF（坏输入仍 decode 判）
    if (len == 3 and lead >= 0xE4 and lead <= 0xE9 and
        j + 2 < src.len and src[j + 1] >= 0x80 and src[j + 1] < 0xC0 and src[j + 2] >= 0x80 and src[j + 2] < 0xC0)
    {
        return 3;
    }
    const r = unicode.decode(src, j) orelse {
        // 坏 UTF-8：按首字节的标称宽度整段消费成 illegal（对齐
        // scanNonAscii 的 utf8Len 吞段）
        setIllegalRange(bm, j, 1);
        return 1;
    };
    if (unicode.isIdStart(r.cp)) {
        // 标识符码点：word 保留（kind 已是 identifier），跳过码点续字节
        return r.len;
    }
    // 非 ID_Start 非 ws 的非 ASCII：按码点消费成**一个** illegal lexeme
    //（对齐 scanNonAscii：首字节 st，续字节只清 word+kind）
    setIllegalRange(bm, j, r.len);
    return r.len;
}

/// 把 [j, e) 从 word run 摘成 trivia：清 word、kind=whitespace、
/// 首字节补 st（ws run 首）、尾后字节若是 word 补 st（新 run 首）
fn setTriviaRange(bm: *Bitmaps, j: usize, e: usize) void {
    var k = j;
    while (k < e) : (k += 1) {
        bmClear(bm.word, k);
        bm.kind[k] = @intFromEnum(Kind.whitespace);
    }
    bmSet(bm.st, j);
    // 尾后接 word 时需要新 run 首 st：classify 时它前一字节 word=1 无 st
    if (e < bm.n and bmGet(bm.word, e)) {
        bmSet(bm.st, e);
    }
}

/// [j, j+len) 消费成**一个** illegal lexeme（对齐 scanNonAscii 的整段
/// 吞法）：首字节 st+kind=illegal，续字节只清 word+kind（st 本就 0），
/// 尾后 word 补 run 首 st
fn setIllegalRange(bm: *Bitmaps, j: usize, len: usize) void {
    const e = @min(j + len, bm.n);
    var k = j;
    while (k < e) : (k += 1) {
        bmClear(bm.word, k);
        bm.kind[k] = @intFromEnum(Kind.illegal);
    }
    bmSet(bm.st, j);
    if (e < bm.n and bmGet(bm.word, e)) {
        bmSet(bm.st, e);
    }
}

/// `\`：对齐 tokenAt 的转义标识符分支 + scanIdentifier 的词中转义合并。
/// `\uXXXX` decode 失败或码点不合格：单字节 illegal（classify 已就位，
/// 无需动）。合法转义分三种位置：
/// - 词外（前字节非 word）：是 ID_Start 才是独立 identifier 起点；
/// - 词中（前字节 word）：只有「首字符之后无 ASCII 快路径字符介入」时
///   才并入前词——scanIdentifier 的循环先判 `\`，但 ASCII 字符走
///   asciiIdentEnd 快路径停在 `\` 即断词（`a\u0042c` 并、`if\u0041` /
///   `ab\u0042c` 断、`a中\u0042` 并、`中a\u0042` 断）；并入条件即
///   [run_start+1, j) 全是非 ASCII 字节（unicode 码点的续字节天然满足），
///   并入时转义须是 ID_Continue，从词首重放 scanIdentifier；
/// - 词首是数字的 word run（数字与词共享 word 位图）：`3\u…` 的数字已被
///   scanNumber 切断，转义按词外处理（对齐 tokenAt 的候选起点判别）。
fn miscBackslash(bm: *Bitmaps, src: []const u8, j: usize) void {
    const r = scanner.decodeIdentEscape(src, j) orelse return;
    if (j > 0 and bmGet(bm.word, j - 1)) {
        var start = j;
        while (start > 0 and bmGet(bm.word, start - 1)) start -= 1;
        if (simd.isDigit(src[start])) {
            if (!scanner.isIdentStartRune(r.cp)) return;
            mergeIdent(bm, src, j);
            return;
        }
        var k = start + 1;
        var merges = true;
        while (k < j) : (k += 1) {
            if (src[k] < 0x80) {
                merges = false;
                break;
            }
        }
        if (merges) {
            if (!scanner.isIdentPartRune(r.cp)) return;
            mergeIdent(bm, src, start);
        } else {
            // 词在 `\` 前已断（asciiIdentEnd 快路径），转义是新词起点
            if (!scanner.isIdentStartRune(r.cp)) return;
            mergeIdent(bm, src, j);
        }
        return;
    }
    if (!scanner.isIdentStartRune(r.cp)) return;
    mergeIdent(bm, src, j);
}

/// scanIdentifier 从 start 重放：清 [start+1, end) 的内部 st、kind[start]
/// 置 identifier（start 处的 st 保留——它就是词首）。
fn mergeIdent(bm: *Bitmaps, src: []const u8, start: usize) void {
    const body = scanner.scanIdentifier(src, start);
    if (body.end > start + 1) {
        bmClearRange(bm.st, start + 1, body.end);
    }
    bm.kind[start] = @intFromEnum(Kind.identifier);
}

// ---------------------------------------------------------------------------
// carve：字符串 / 模板 / 注释 / 正则的 opener 事件循环
// ---------------------------------------------------------------------------

/// SIMD 找下一个 `" ' \` /`（32B 窗口 movemask + ctz）
pub fn findOpener(src: []const u8, n: usize, from: usize) usize {
    var i = from;
    while (i + 32 <= n) {
        const m: Mask = @bitCast((simd.load(src, i) == splat('"')) | (simd.load(src, i) == splat('\'')) |
            (simd.load(src, i) == splat('`')) | (simd.load(src, i) == splat('/')));
        if (m != 0) {
            return i + @ctz(m);
        }
        i += 32;
    }
    while (i < n) : (i += 1) {
        const c = src[i];
        if (c == '"' or c == '\'' or c == '`' or c == '/') return i;
    }
    return n;
}

pub fn carve(bm: *Bitmaps, src: []const u8, from: usize) void {
    const n = src.len;
    // shebang 行不参与 opener 扫描（scanInto 传入行尾）：行内的 `/` 会
    // 被误判正则起点，行内未闭合反引号会吞到行外
    var tpl: TemplateStack = .{};
    var i: usize = from;
    while (true) {
        // 模板子表达式内（tpl 非空）还要找 `{`/`}`：花括号计数归零的 `}`
        // 是模板续片（middle/tail）起点，与 scanner.scanAt 同一口径。
        // 模板外短路为零额外成本（模板-free 文件走纯 opener 扫描）
        const s = if (tpl.len > 0) findTemplateStop(src, n, i) else findOpener(src, n, i);
        if (s >= n) break;
        switch (src[s]) {
            '"', '\'' => {
                const tok = scanner.scanString(src, s, src[s]);
                carveLiteral(bm, s, tok.end, fromLexeme(tok.kind));
                i = tok.end;
            },
            '`' => {
                // 模板起点：扫一个 part（head 收尾含 `${`，无子表达式整体
                // 一片）；子表达式内部由主循环按普通 lexeme 流继续扫
                const tok = scanner.scanTemplatePart(src, s);
                carveLiteral(bm, s, tok.end, fromLexeme(tok.kind));
                tpl.track(tok.kind, '`');
                i = tok.end;
            },
            '/' => {
                i = carveSlash(bm, src, s);
            },
            '{' => {
                tpl.track(.punct, '{');
                i = s + 1;
            },
            '}' => {
                if (tpl.closesTemplate()) {
                    // 子表达式收尾：`}` 起续片（middle 到 `${`，tail 到反引号）
                    const tok = scanner.scanTemplatePart(src, s);
                    carveLiteral(bm, s, tok.end, fromLexeme(tok.kind));
                    tpl.track(tok.kind, '}');
                    i = tok.end;
                } else {
                    tpl.track(.punct, '}');
                    i = s + 1;
                }
            },
            else => {
                // 不可达（finder 只停上述字节）；容错跳过
                i = s + 1;
            },
        }
    }
}

/// 模板子表达式内的停靠点：`" ' \` /` 之外加 `{` `}`（花括号计数与续片
/// 判别）。仅 tpl 非空时启用，模板-free 文件零成本。
pub fn findTemplateStop(src: []const u8, n: usize, from: usize) usize {
    var i = from;
    while (i + 32 <= n) {
        const c = simd.load(src, i);
        const m: Mask = @bitCast((c == splat('"')) | (c == splat('\'')) | (c == splat('`')) |
            (c == splat('/')) | (c == splat('{')) | (c == splat('}')));
        if (m != 0) {
            return i + @ctz(m);
        }
        i += 32;
    }
    while (i < n) : (i += 1) {
        const c = src[i];
        if (c == '"' or c == '\'' or c == '`' or c == '/' or c == '{' or c == '}') return i;
    }
    return n;
}

/// 字面量 lexeme 落位：kind[s]=kind、清 [s+1, end) 的 st
/// （oxc 的 inclusive [s+1, end-1] 等价——lexeme 内部全部摘除）。
/// kind 取内部 Kind（含 trivia 标签）；LexemeKind 值经 fromLexeme 转换。
fn carveLiteral(bm: *Bitmaps, s: usize, end: usize, kind: Kind) void {
    bm.kind[s] = @intFromEnum(kind);
    if (end > s + 1) {
        bmClearRange(bm.st, s + 1, end);
    }
}

/// LexemeKind → 内部 Kind（前段同序同值，直接 reinterpret）
inline fn fromLexeme(kind: LexemeKind) Kind {
    return @enumFromInt(@intFromEnum(kind));
}

/// `/` 的三义：行注释 / 块注释 / 正则 / 除号（`/=` 自并）。
/// 注释是 trivia（不落盘）：carve 成 comment kind，compress 跳过；
/// 换行信息由 nl 位图在 compress 统一交付。返回续扫位置。
fn carveSlash(bm: *Bitmaps, src: []const u8, s: usize) usize {
    const n = src.len;
    const d: u8 = if (s + 1 < n) src[s + 1] else 0;
    if (d == '/') {
        const end = scanner.lineEnd(src, s);
        carveLiteral(bm, s, end, .comment);
        return end;
    }
    if (d == '*') {
        if (simd.findBlockCommentEnd(src, s + 2)) |e| {
            carveLiteral(bm, s, e.end, .comment);
            return e.end;
        }
        // 未闭合块注释：吞掉余下全部，illegal 落盘（错误可见，容错不中断）
        carveLiteral(bm, s, n, .illegal);
        return n;
    }
    if (regexAllowedBitmap(bm, src, s)) {
        const tok = scanner.scanRegex(src, s);
        carveLiteral(bm, s, tok.end, fromLexeme(tok.kind));
        return tok.end;
    }
    if (d == '=') {
        // `/=`：自并成单 punct lexeme（对齐 scanPunct 贪心）
        bmClear(bm.st, s + 1);
        bmClear(bm.opch, s + 1);
        return s + 2;
    }
    return s + 1;
}

// ---------------------------------------------------------------------------
// 位图版 regexAllowedAfter
// ---------------------------------------------------------------------------

/// `/` 在位图上下文里是正则还是除号。语义对齐 scanner.regexAllowedAfter
/// （prev/prev2 双回看启发式；prev/prev2 的文本从位图现场重建——carve
/// 运行在 coalesce 之前，punct 尚未合并，opch run 处用 maximum munch
/// 重放精确化）。两段式：
///  1. opch run 重放：`/` 紧贴的 punct lexeme（从 opch run 左界正向贪心，
///     maximum munch 天然正确，覆盖 `++/`、`>>>=/`、`x++++/` 等）
///  2. bmPrev1 跳 trivia：值类 lexeme → 除号；keyword this/super → 除号；
///     名字位置的关键字（prev2 ∈ `.`/`?.`/`#`）→ 除号；其他 keyword →
///     正则；`)`/`]`/`++`/`--` → 除号；其余 → 正则
fn regexAllowedBitmap(bm: *Bitmaps, src: []const u8, p: usize) bool {
    const n = src.len;

    // #1 punct 重放：opch run 左界 s0，正向贪心到 p
    var s0 = p;
    while (s0 > 0 and p - s0 < 8 and bmGet(bm.opch, s0 - 1)) s0 -= 1;
    if (s0 < p) {
        var t = s0;
        var prev_start = s0;
        while (t < p) {
            prev_start = t;
            // `.5` 是数字（对齐 tokenAt 的 punct_multi 分支）
            if (src[t] == '.' and t + 1 < n and simd.isDigit(src[t + 1])) {
                t = scanner.scanNumber(src, t).end;
            } else {
                t = scanner.scanPunct(src, t).end;
            }
        }
        if (t == p) {
            const c0 = src[prev_start];
            if (c0 == ')' or c0 == ']') return false;
            const l = p - prev_start;
            if ((c0 == '+' or c0 == '-') and l == 2 and src[prev_start + 1] == c0) return false;
            return true;
        }
        // t != p：run 内有数字跨界（如 `1.5e+3/`——scanNumber 吃断 opch run），
        // 落到 #2（此时前 lexeme 是数字，#2 的 kind 分支处理）
    }

    // #2：上一个显著 lexeme
    var q = p;
    while (true) {
        q = bmPrev1(bm.st, q) orelse return true; // 文件头
        const k: Kind = @enumFromInt(bm.kind[q]);
        if (k == .whitespace or k == .comment) continue;
        switch (k) {
            .identifier => {
                // 文本端点取「下一个 st 位」而不是 word run 尾：词内 `\uXXXX`
                // 转义已被 miscPass 并词（word 位图在 `\` 处断开），st 配对
                // 恒给出 lexeme 真实尾——`if\u0041` 不会被截成关键字 if
                const we = bmNext1(bm.st, q + 1, n) orelse n;
                const w = src[q..we];
                if (!scanner.isKeyword(w)) return false;
                // this/super 是值；名字位置（prev2 ∈ `.`/`?.`/`#`）的关键字
                // 是属性/私有名，同样是值
                if (std.mem.eql(u8, w, "this") or std.mem.eql(u8, w, "super")) return false;
                if (prev2IsNamePunct(bm, src, q)) return false;
                return true;
            },
            .number, .string, .regex, .no_substitution_template, .template_tail => return false,
            .punct => {
                const c0 = src[q];
                if (c0 == ')' or c0 == ']') return false;
                // q 所在 punct lexeme 的精确文本（opch run 重放；carve 时
                // punct 尚未合并），只对 `++`/`--` 判除号
                const text = if (bmGet(bm.opch, q)) opchTokenText(bm, src, q) else src[q .. q + 1];
                return !std.mem.eql(u8, text, "++") and !std.mem.eql(u8, text, "--");
            },
            // template_head/middle（`${` 后是表达式位置）、shebang、illegal
            else => return true,
        }
    }
}

/// opch 字节 r 所在 lexeme 的文本（carve 时 punct 尚未合并，从 run 左界
/// 正向 maximum munch 重放定位；`.5` 归数字，与 #1 重放同口径）。
/// r 必须在 opch run 内；run 超过 8 字节时左界截断（病态代码，罕见）。
fn opchTokenText(bm: *Bitmaps, src: []const u8, r: usize) []const u8 {
    const n = src.len;
    var rl = r;
    while (rl > 0 and r - rl < 8 and bmGet(bm.opch, rl - 1)) rl -= 1;
    var t = rl;
    while (t <= r) {
        const tend = if (src[t] == '.' and t + 1 < n and simd.isDigit(src[t + 1]))
            scanner.scanNumber(src, t).end
        else
            scanner.scanPunct(src, t).end;
        if (tend > r) return src[t..tend];
        t = tend;
    }
    return src[r .. r + 1]; // 不可达（r 必在某 lexeme 内）；兜底单字节
}

/// prev2（q 之前的显著 lexeme）是否名字位置 punct：`.`、`?.`、`#`
/// （regexAllowedAfter 的 prev2 口径）。`#` 恒单字节；`.`/`?.` 需在 opch
/// run 里正向 maximum munch 重放确认——`...`、`.5` 都不算名字位置。
fn prev2IsNamePunct(bm: *Bitmaps, src: []const u8, q: usize) bool {
    var r = q;
    while (true) {
        r = bmPrev1(bm.st, r) orelse return false;
        const k: Kind = @enumFromInt(bm.kind[r]);
        if (k == .whitespace or k == .comment) continue;
        if (k != .punct) return false;
        if (src[r] == '#') return true; // `#` 恒单字节 punct
        if (!bmGet(bm.opch, r)) return src[r] == '.'; // 非 opch 的 punct 恒单字节
        const text = opchTokenText(bm, src, r);
        return std.mem.eql(u8, text, ".") or std.mem.eql(u8, text, "?.");
    }
}

// ---------------------------------------------------------------------------
// coalesce：多字符 punct 合并 / 数字粘合
// ---------------------------------------------------------------------------

pub fn coalesce(bm: *Bitmaps, src: []const u8) void {
    const n = src.len;
    const nb = (n + 63) / 64;
    var opprev: u64 = 0;
    var cursor: usize = 0;
    var w: usize = 0;
    while (w < nb) : (w += 1) {
        const op = bm.opch[w];
        const opnext: u64 = if (w + 1 < nb) bm.opch[w + 1] else 0;
        const stw = bm.st[w];
        // multi：opch run 起点（token start & 前一字节非 opch & 后一字节 opch）
        const multi = op & stw & ~((op << 1) | (opprev >> 63)) & ((op >> 1) | (opnext << 63));
        // numev：数字/`.5` 起点（numch & st；单 `.` 等 punct 形态在事件处分流）
        const numev = bm.numch[w] & stw;
        var ev = multi | numev;
        opprev = op;
        while (ev != 0) {
            const bit: u32 = @ctz(ev);
            ev &= ev - 1;
            const p = (w << 6) + bit;
            if (p < cursor) continue;
            // ev 是进入本 word 前的 st 快照：前序事件（gluePunct/glueNumber）
            // 已消费的字节 st 被清，其事件是陈旧的，必须跳过——否则 `...`
            // 末字节的 numev 会越界触发 glueNumber 把后续数字并入 punct
            // （`[...191` 并成一个 lexeme）。注意 p == cursor 不能一并排除：
            // `a?.5:b` 的 `.` 按单字节 punct 消费（st 未清），其事件要照常
            // 触发 glueNumber 粘出 `.5` 数字。
            if (!bmGet(bm.st, p)) continue;
            if (simd.isDigit(src[p]) or
                (src[p] == '.' and p + 1 < n and simd.isDigit(src[p + 1])))
            {
                cursor = glueNumber(bm, src, p);
            } else {
                cursor = gluePunct(bm, src, p);
            }
        }
    }
}

/// 多字符 punct 合并（对齐 scanPunct 贪心链）：kind 不变（.punct），清
/// 内部 st。opch run 内连续贪心（`++++` → `++`+`++`，对齐 oxc 的
/// munch_walk）。返回 cursor（最后 token 的尾字节位）。
fn gluePunct(bm: *Bitmaps, src: []const u8, p: usize) usize {
    const n = src.len;
    var pos = p;
    while (true) {
        const end = if (pos + 4 <= n)
            pos + scanner.punctLenW(std.mem.readInt(u32, src[pos..][0..4], .little))
        else
            pos + scanner.punctLenW(blk: {
                var w: u32 = 0;
                for (src[pos..@min(pos + 4, n)], 0..) |c, k| w |= @as(u32, c) << @intCast(8 * k);
                break :blk w;
            });
        if (end > pos + 1) {
            bmClearRange(bm.st, pos + 1, end);
        }
        pos = end;
        if (!(pos < n and bmGet(bm.opch, pos))) break;
    }
    return pos - 1;
}

/// 数字 lexeme 粘合（对齐 scanNumber）：kind=number、清内部 st 与 opch
/// （`1.5e+3` 的 `+` 不许再触发 multi）。词紧邻数字的非法形态（`3in4`）
/// 对齐 my-scanner 容错语义：不补 st、整段吞掉（候选位图里这些字节本
/// 就不再是 lexeme 起点，无 lexeme 产出）。
fn glueNumber(bm: *Bitmaps, src: []const u8, p: usize) usize {
    const end = scanner.scanNumber(src, p).end;
    bm.kind[p] = @intFromEnum(Kind.number);
    if (end > p + 1) {
        bmClearRange(bm.st, p + 1, end);
    }
    if (end > p) {
        bmClearRange(bm.opch, p, end);
    }
    if (end < src.len and bmGet(bm.word, end) and !bmGet(bm.st, end)) {
        // 非法词邻接（`3in4` 的 `in4`）：end 处放 whitespace kind 的 st 位
        // 作 number 的 end 锚点；该位是 trivia，compress 不产 lexeme，
        // 整段词对齐 my-scanner 的「吞掉」语义。end 本就是 st 位时不覆盖
        // （`3.toFixed` 的 toFixed 是合法 identifier 起点，two_phase 会产出）。
        bmSet(bm.st, end);
        bm.kind[end] = @intFromEnum(Kind.whitespace);
    }
    return end - 1;
}

// ---------------------------------------------------------------------------
// 驱动
// ---------------------------------------------------------------------------

/// 位图缓冲的跨轮复用：bench 计时循环里 scanInto 反复调用，每轮重新
/// alloc/memset 约 1.9×n 字节在小文件上占比极高。oxc 的 bench 口径本就
/// 是 arena 跨轮复用（零分配稳态设计意图，见 architecture.md
/// 「oxc_bitmap」节）——这里对齐同一口径。单线程假设与 bench/CLI 一致；
/// classify 全量重写位图 word，复用只需清兜底 word。
var reuse: ?Bitmaps = null;

fn acquireBitmaps(allocator: std.mem.Allocator, n: usize) !*Bitmaps {
    const nb = (n + 63) / 64 + 1;
    if (reuse) |*bm| {
        if (bm.st.len >= nb) {
            bm.n = n;
            bm.word[nb - 1] = 0;
            bm.st[nb - 1] = 0;
            bm.opch[nb - 1] = 0;
            bm.numch[nb - 1] = 0;
            bm.misc[nb - 1] = 0;
            bm.nl[nb - 1] = 0;
            return bm;
        }
        bm.deinit(allocator);
    }
    reuse = try Bitmaps.alloc(allocator, n);
    return &reuse.?;
}

/// 释放复用缓冲（测试的泄漏检测需显式归还；bench/CLI 退出无需调用）
pub fn releaseReuse(allocator: std.mem.Allocator) void {
    if (reuse) |*bm| bm.deinit(allocator);
    reuse = null;
}

pub fn scanInto(
    tokens: *std.ArrayList(Lexeme),
    allocator: std.mem.Allocator,
    src: []const u8,
) !void {
    std.debug.assert(src.len <= std.math.maxInt(u32));

    const bm = try acquireBitmaps(allocator, src.len);

    classify(bm, src);
    miscPass(bm, src);

    // shebang 特判（对齐 jump_vec/主循环：文件头 `#!` 是独立 lexeme），
    // 并把 carve 起点推到行尾（shebang 行内不做 opener 扫描）
    var carve_from: usize = 0;
    if (src.len >= 2 and src[0] == '#' and src[1] == '!') {
        const end = scanner.lineEnd(src, 0);
        try tokens.append(allocator, .{ .kind = .shebang, .start = 0, .end = @intCast(end) });
        bmClearRange(bm.st, 1, end);
        bm.kind[0] = @intFromEnum(Kind.whitespace); // compress 按 trivia 跳过
        carve_from = end;
    }

    carve(bm, src, carve_from);
    coalesce(bm, src);
    try compress(bm, tokens, allocator);
}

pub fn scan(allocator: std.mem.Allocator, src: []const u8) !scanner.Result {
    std.debug.assert(src.len <= std.math.maxInt(u32));
    var tokens: std.ArrayList(Lexeme) = .empty;
    errdefer tokens.deinit(allocator);
    try scanInto(&tokens, allocator, src);
    return .{
        .tokens = try tokens.toOwnedSlice(allocator),
        // 行索引留空：首次查询时由 LineIndex 跑 classifyLineBreaks 物化
        .lines = .{ .src = src, .allocator = allocator },
    };
}

/// st 位图 → lexeme 流：全量 (pos, kind[pos]) 配对 end=下一 st 位。
/// 交付口径：trivia（whitespace/comment）一律不落盘；trivia 区间内的
/// 行终止符（nl 位图）压成 flag_newline_before 挂到下一个显著 lexeme
/// （含 eof）的 flags 上。
pub fn compress(bm: *Bitmaps, tokens: *std.ArrayList(Lexeme), allocator: std.mem.Allocator) !void {
    const n = bm.n;
    // sentinel：位 n 恒置位，保证每个 lexeme 都有「下一 st 位」可配对。
    // 位 n 所在 word 的高位段可能是复用缓冲的上一轮残留，先清掉。
    bm.st[n >> 6] &= lowBits(n & 63);
    bmSet(bm.st, n);
    bm.kind[n] = @intFromEnum(Kind.whitespace); // sentinel 自身按 trivia 跳过

    // st 位总数是产出 lexeme 数的上界（含 trivia entry），一次预留到位，
    // 热循环全部 appendAssumeCapacity（免每 lexeme 的容量分支）
    // 循环界 = 位 n 所在 word（含 sentinel）：classify 覆盖 [0, ceil(n/64))，
    // 复用缓冲中更高 word 是上一轮残留，不可读
    const nb_total = (n >> 6) + 1;
    var total: usize = 0;
    for (bm.st[0..nb_total]) |wd| total += @popCount(wd);
    try tokens.ensureTotalCapacity(allocator, tokens.items.len + total + 1);

    var pending: Lexeme = undefined;
    var has_pending = false;
    var last_end: usize = 0; // 上一个显著 lexeme 的尾（newline flag 的区间左界）
    var w: usize = 0;
    outer: while (w < nb_total) : (w += 1) {
        var bits = bm.st[w];
        const base = w << 6;
        while (bits != 0) {
            const pos = base + @ctz(bits);
            bits &= bits - 1;
            if (pos > n) break :outer; // 越界兜底（正常到 sentinel 即止）
            if (has_pending) {
                pending.end = @intCast(pos);
                tokens.appendAssumeCapacity(pending);
                last_end = pos;
                has_pending = false;
            }
            const k: Kind = @enumFromInt(bm.kind[pos]);
            if (k == .whitespace or k == .comment) continue;
            pending = .{
                // Kind 前段与 LexemeKind 同序同值，显著 kind 直接转
                .kind = @enumFromInt(@intFromEnum(k)),
                .flags = if (bmAny(bm.nl, last_end, pos)) lexeme_mod.flag_newline_before else 0,
                .start = @intCast(pos),
                .end = 0,
            };
            has_pending = true;
        }
    }
    if (has_pending) {
        pending.end = @intCast(n);
        tokens.appendAssumeCapacity(pending);
        last_end = n;
    }
    // 尾部空白不是 st 位，eof 固定 start == end == n；换行归 eof
    tokens.appendAssumeCapacity(.{
        .kind = .eof,
        .flags = if (bmAny(bm.nl, last_end, n)) lexeme_mod.flag_newline_before else 0,
        .start = @intCast(n),
        .end = @intCast(n),
    });
}
// ---------------------------------------------------------------------------
// 测试：与两阶段 scanner 逐 lexeme 交叉验证（含 newline_before flags）
// ---------------------------------------------------------------------------

fn expectSame(src: []const u8) !void {
    const a = std.testing.allocator;
    var want = try scanner.scan(a, src);
    defer want.deinit(a);
    var got_list: std.ArrayList(Lexeme) = .empty;
    defer got_list.deinit(a);
    try scanInto(&got_list, a, src);
    if (want.tokens.len != got_list.items.len) {
        std.debug.print("lexeme 数不一致：两阶段 {d}，bitmap {d}\nsrc: {s}\n", .{ want.tokens.len, got_list.items.len, src });
        return error.TestTokenCountMismatch;
    }
    for (want.tokens, got_list.items, 0..) |w, g, i| {
        std.testing.expectEqualDeep(w, g) catch |e| {
            std.debug.print("第 {d} 个 lexeme 不符（src: {s}）：两阶段 {any}，bitmap {any}\n", .{ i, src, w, g });
            return e;
        };
    }
}

test "bitmap 与两阶段 scanner 交叉验证" {
    try expectSame("const x = 1 + 2;");
    try expectSame("let re = /ab+c/gi; let s = `a${b}c`;");
    try expectSame("// line comment\n/* block */ var y = \"str\\\"esc\";");
    try expectSame("a.5 + ...b");
    try expectSame("if (a) { b() } else { c() }");
    try expectSame("#!/usr/bin/env node\nconsole.log('hi');");
    try expectSame("x++++/re/");
    try expectSame("3in4");
    try expectSame("const π = Math.PI; // unicode");
    try expectSame("class A { #p = 1; m() { return this.#p; } }");
    try expectSame("a = b => `t${ { x: 1 }.x }s`");
    try expectSame("do { x++ } while (x < 10)");
    try expectSame("label: for (const v of xs) { if (v) continue label; }");
    try expectSame("switch (x) { case 1: break; default: }");
    try expectSame("0x1Fn + 0b1010 + 0o17 + 1_000.5e+3n");
    try expectSame("v = v / 2 / 3; w = v++ / 2;");
    try expectSame("`a${`b${c}d`}e`");
    try expectSame("a===b; c!==d; e>>>=f; g<<=h;");
    // 防回归：coalesce 陈旧事件（st 快照在被 gluePunct 消费的字节上残留）——
    // `...` 末字节的 numev 事件（dot 在 numch 位图）曾越界触发 glueNumber，
    // 把 `...`+数字并成一个 punct（typescript.min.js 实测 `[...191===`）
    try expectSame("[...191===t");
    try expectSame("f(...5)");
    // 反例必须保持绿：`?` 后 `.` 按单字节 punct 消费（st 未清），其 numev
    // 事件触发 glueNumber 粘出 `.5`——st 复核放行该路径
    try expectSame("a?.5:b");
    try expectSame("if\\u0041 = 1; // \\u 转义并入词（新口径）");
    try expectSame("a\\u0042c = 1; // ASCII 词中转义并词");
    try expectSame("3\\u0042c = 1; // 数字后转义是新词起点");
    try expectSame("a\\u{41}b = 2; // \\u{...} 不合并（tsc 同口径）");
    try expectSame("#x\\u{41}; // # 恒单字节 punct");
    try expectSame("x\u{2028}y; // LS 逻辑换行（newline flag）");
    try expectSame("\u{00A0}x; // NBSP 空白");
    // 防回归：审查发现的容错路径
    try expectSame("#!/usr/bin/env node\nx = 1;"); // shebang 行不被 carve 扫
    try expectSame("a \u{2603} b"); // emoji 按码点一个 illegal
    try expectSame("a # b"); // 裸 # 是单字节 punct（新口径）
    try expectSame("3.toFixed(2)"); // 数字后词邻接不吞合法标识符
    try expectSame("x.if = 1;"); // `.if` 的 if 参与 prev2 名字位置判别
    // 模板拆片：子表达式内的字符串/注释/正则/花括号配对（carve 模板栈）
    try expectSame("`a${x}b${y}c`");
    try expectSame("tag`a${x}b${ fn`y` }c` / re/g");
    try expectSame("{ t = `a${x}b${y}c`; } f(`a '${x}'`) }");
    try expectSame("x = `a${ /* } ` */ 1 }d`;");
    try expectSame("x = `a${ // }`\n1 }d`;");
    try expectSame("x = `a${ \"}\" }d`;");
    try expectSame("` ${x/y}` + /re/g");
    try expectSame("`a${ /}/.test(x) }b`");
    try expectSame("` ${r.replace(/\\*\\//g,\"*_/\")} `");
    try expectSame("a/b; `x${ /c/ }y${ `z${ /d/ }w` }v`; /e/g");
    // 正则 vs 除法：prev2 名字位置（新口径）
    try expectSame("x.return / v; x?.if / w; this.#return /2/ u");
    try expectSame("if\\u0041 /x/; return /y/;"); // 转义词不是关键字
    try expectSame("x = \"未闭合\n"); // 裸换行非法字符串
    try expectSame("/* 未闭合块注释"); // 吞到 EOF 落 illegal
    try expectSame("a /* x\ny */ b"); // 块注释内换行 → flag
    try expectSame("a\r\nb\rc"); // CRLF 与孤立 \r
    // 位图 word 边界（n 恰为 64/128 倍数与 n=65）
    try expectSame("a" ** 64 ++ ";");
    try expectSame("a" ** 65 ++ ";");
    try expectSame("a" ** 128 ++ ";");
    // 复用收缩：大文件后接小文件
    try expectSame("const abc = 1;" ** 40);
    try expectSame("x;");
    releaseReuse(std.testing.allocator);
}

test "bitmap 复用缓冲跨轮一致" {
    // 大→小→中混合扫描，结果与单独扫描一致
    const a = std.testing.allocator;
    const cases = [_][]const u8{ "const hello = 'world';\n" ** 30, "x = 1;", "var yy = `tpl ${a} end`;\n" ** 10 };
    for (cases) |src| {
        var got_list: std.ArrayList(Lexeme) = .empty;
        defer got_list.deinit(a);
        try scanInto(&got_list, a, src);
        var want = try scanner.scan(a, src);
        defer want.deinit(a);
        if (want.tokens.len != got_list.items.len) {
            std.debug.print("lexeme 数不一致：两阶段 {d}，bitmap {d}\nsrc: {s}\n", .{ want.tokens.len, got_list.items.len, src });
            return error.TestTokenCountMismatch;
        }
        for (want.tokens, got_list.items) |w, g| {
            try std.testing.expectEqualDeep(w, g);
        }
    }
    releaseReuse(a);
}
