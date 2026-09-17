//! 位图版 regexAllowedAfter：`/` 在位图上下文里是正则还是除号。

const std = @import("std");
const simd = @import("../../simd.zig");
const scanner = @import("../../scanner.zig");
const bits = @import("bits.zig");

const Bitmaps = bits.Bitmaps;
const Kind = bits.Kind;

/// 语义对齐 scanner.regexAllowedAfter（prev/prev2 双回看启发式；
/// prev/prev2 的文本从位图现场重建——carve 运行在 coalesce 之前，
/// punct 尚未合并，opch run 处用 maximum munch 重放精确化）。两段式：
///  1. opch run 重放：`/` 紧贴的 punct lexeme（从 opch run 左界正向贪心，
///     maximum munch 天然正确，覆盖 `++/`、`>>>=/`、`x++++/` 等）
///  2. bmPrev1 跳 trivia：值类 lexeme → 除号；keyword this/super → 除号；
///     名字位置的关键字（prev2 ∈ `.`/`?.`/`#`）→ 除号；其他 keyword →
///     正则；`)`/`]`/`++`/`--` → 除号；其余 → 正则
pub fn regexAllowedBitmap(bm: *Bitmaps, src: []const u8, p: usize) bool {
    const n = src.len;

    // #1 punct 重放：opch run 左界 s0，正向贪心到 p
    var s0 = p;
    while (s0 > 0 and p - s0 < 8 and bits.bmGet(bm.opch, s0 - 1)) s0 -= 1;
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
        q = bits.bmPrev1(bm.st, q) orelse return true; // 文件头
        const k: Kind = @enumFromInt(bm.kind[q]);
        if (k == .whitespace or k == .comment) continue;
        switch (k) {
            .identifier => {
                // 文本端点取「下一个 st 位」而不是 word run 尾：词内 `\uXXXX`
                // 转义已被 miscPass 并词（word 位图在 `\` 处断开），st 配对
                // 恒给出 lexeme 真实尾——`if\u0041` 不会被截成关键字 if
                const we = bits.bmNext1(bm.st, q + 1, n) orelse n;
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
                const text = if (bits.bmGet(bm.opch, q)) opchTokenText(bm, src, q) else src[q .. q + 1];
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
    while (rl > 0 and r - rl < 8 and bits.bmGet(bm.opch, rl - 1)) rl -= 1;
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
        r = bits.bmPrev1(bm.st, r) orelse return false;
        const k: Kind = @enumFromInt(bm.kind[r]);
        if (k == .whitespace or k == .comment) continue;
        if (k != .punct) return false;
        if (src[r] == '#') return true; // `#` 恒单字节 punct
        if (!bits.bmGet(bm.opch, r)) return src[r] == '.'; // 非 opch 的 punct 恒单字节
        const text = opchTokenText(bm, src, r);
        return std.mem.eql(u8, text, ".") or std.mem.eql(u8, text, "?.");
    }
}
