//! 位图容器与原语。容器布局：每 64 字节块一个 u64 word（多 1 word 给
//! n 处 sentinel），kind 每字节一个 u8（长度补齐到 64 倍数再 +64，尾块
//! 向量整存 + sentinel）。
//!
//! 约定：bmClearRange 是 [from, to)（zig 风格）；oxc 原文的
//! bm_clear_range 是 inclusive [from, to]，移植时调用点统一 +1。

const std = @import("std");
const lexeme_mod = @import("../../lexeme.zig");

/// 位图 kind 数组的内部标签：前段与 LexemeKind 同序同值（compress 对显著
/// lexeme 直接 @enumFromInt 成 LexemeKind，零映射成本），后段两个是 trivia
/// 内部标记——新交付口径 trivia 不落盘，compress 一律跳过。
pub const Kind = enum(u8) {
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
    for (std.meta.tags(lexeme_mod.LexemeKind)) |k| {
        if (@intFromEnum(k) != @intFromEnum(@field(Kind, @tagName(k))))
            @compileError("Kind 前段必须与 LexemeKind 同序同值: " ++ @tagName(k));
    }
}

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
pub inline fn lowBits(n: usize) u64 {
    if (n >= 64) return ~@as(u64, 0);
    return (@as(u64, 1) << @intCast(n)) - 1;
}

pub inline fn bmGet(bm: []const u64, i: usize) bool {
    return (bm[i >> 6] >> @intCast(i & 63)) & 1 != 0;
}

pub inline fn bmSet(bm: []u64, i: usize) void {
    bm[i >> 6] |= @as(u64, 1) << @intCast(i & 63);
}

pub inline fn bmClear(bm: []u64, i: usize) void {
    bm[i >> 6] &= ~(@as(u64, 1) << @intCast(i & 63));
}

/// 清空 [from, to)
pub fn bmClearRange(bm: []u64, from: usize, to: usize) void {
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
pub fn bmAny(bm: []const u64, from: usize, to: usize) bool {
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
pub fn bmNext1(bm: []const u64, i: usize, limit: usize) ?usize {
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
pub fn bmPrev1(bm: []const u64, i: usize) ?usize {
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
pub fn bmNext0(bm: []const u64, i: usize) usize {
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
