//! compress：st 位图 → lexeme 流，全量 (pos, kind[pos]) 配对 end=下一
//! st 位（stage 流配对，与 oxc build_spans 同构；st 位图在 n 处放
//! sentinel 保证末 lexeme 有配对）。end=下一 st 位恒成立的原因：任何
//! lexeme 尾之后必然是下一 lexeme 起点、trivia 起点或 EOF，而这三者都
//! 有 st 位。
//!
//! 交付口径：trivia（whitespace/comment）一律不落盘；trivia 区间内的
//! 行终止符（nl 位图）压成 flag_newline_before 挂到下一个显著 lexeme
//! （含 eof）的 flags 上。

const std = @import("std");
const lexeme_mod = @import("../../lexeme.zig");
const bits = @import("bits.zig");

const Bitmaps = bits.Bitmaps;
const Kind = bits.Kind;
const Lexeme = lexeme_mod.Lexeme;

pub fn compress(bm: *Bitmaps, tokens: *std.ArrayList(Lexeme), allocator: std.mem.Allocator) !void {
    const n = bm.n;
    // sentinel：位 n 恒置位，保证每个 lexeme 都有「下一 st 位」可配对。
    // 位 n 所在 word 的高位段可能是复用缓冲的上一轮残留，先清掉。
    bm.st[n >> 6] &= bits.lowBits(n & 63);
    bits.bmSet(bm.st, n);
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
        var bits_w = bm.st[w];
        const base = w << 6;
        while (bits_w != 0) {
            const pos = base + @ctz(bits_w);
            bits_w &= bits_w - 1;
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
                .flags = if (bits.bmAny(bm.nl, last_end, pos)) lexeme_mod.flag_newline_before else 0,
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
        .flags = if (bits.bmAny(bm.nl, last_end, n)) lexeme_mod.flag_newline_before else 0,
        .start = @intCast(n),
        .end = @intCast(n),
    });
}
