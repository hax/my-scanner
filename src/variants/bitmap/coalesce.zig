//! coalesce：多字符 punct 合并 / 数字粘合。

const std = @import("std");
const simd = @import("../../simd.zig");
const scanner = @import("../../scanner.zig");
const bits = @import("bits.zig");

const Bitmaps = bits.Bitmaps;
const Kind = bits.Kind;

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
            if (!bits.bmGet(bm.st, p)) continue;
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
            bits.bmClearRange(bm.st, pos + 1, end);
        }
        pos = end;
        if (!(pos < n and bits.bmGet(bm.opch, pos))) break;
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
        bits.bmClearRange(bm.st, p + 1, end);
    }
    if (end > p) {
        bits.bmClearRange(bm.opch, p, end);
    }
    if (end < src.len and bits.bmGet(bm.word, end) and !bits.bmGet(bm.st, end)) {
        // 非法词邻接（`3in4` 的 `in4`）：end 处放 whitespace kind 的 st 位
        // 作 number 的 end 锚点；该位是 trivia，compress 不产 lexeme，
        // 整段词对齐 my-scanner 的「吞掉」语义。end 本就是 st 位时不覆盖
        // （`3.toFixed` 的 toFixed 是合法 identifier 起点，two_phase 会产出）。
        bits.bmSet(bm.st, end);
        bm.kind[end] = @intFromEnum(Kind.whitespace);
    }
    return end - 1;
}
