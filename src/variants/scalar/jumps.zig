//! 标量跳跃函数（对应两阶段里的 SIMD 版）：字符串/模板/注释/标识符的
//! 纯标量贪心扫描。刻意不用 simd.zig 的向量原语——这条线的意义就是
//! "零 SIMD 的地基"，它与 jump_vec / 两阶段的差值 = 各向量化层的净贡献。

const std = @import("std");
const scanner = @import("../../scanner.zig");
const unicode = @import("../../unicode.zig");
const simd = @import("../../simd.zig");

const Scan = scanner.Scan;

/// 找行终止符（行注释/shebang/非法恢复的终点）：\n、\r、U+2028/U+2029
/// （与 scanner.lineEnd 同口径的标量版）。
pub fn lineEndScalar(src: []const u8, from: usize) usize {
    var i = from;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (c == '\n' or c == '\r') return i;
        if (c == 0xE2 and i + 2 < src.len and src[i + 1] == 0x80 and
            (src[i + 2] == 0xA8 or src[i + 2] == 0xA9)) return i;
    }
    return i;
}

/// 块注释扫描结果（findBlockCommentEnd 的标量版）：end 是 `*/` 后一位；
/// saw_lf 表示注释体内是否含 \n/\r（U+2028/29 由主循环统一经
/// 空白 run 或 ws 标记判定，不在此重复）。
const BcEnd = struct { end: usize, saw_lf: bool };

/// 从 from 起找下一个 `*/`（返回其后一位），找不到 null。逐字节，
/// 换行检测融合同一趟。
pub fn findBlockCommentEndScalar(src: []const u8, from: usize) ?BcEnd {
    var i = from;
    var saw_lf = false;
    while (i + 1 < src.len) : (i += 1) {
        const c = src[i];
        saw_lf = saw_lf or (c == '\n' or c == '\r');
        if (c == '*' and src[i + 1] == '/') return .{ .end = i + 2, .saw_lf = saw_lf };
    }
    return null;
}

/// 单/双引号字符串：逐字节找 `引号|反斜杠|换行`，转义对跳 2。
pub fn scanStringScalar(src: []const u8, start: usize, quote: u8) Scan {
    var i = start + 1;
    while (i < src.len) {
        const c = src[i];
        if (c == quote) return .{ .kind = .string, .end = i + 1 };
        if (c == '\\') {
            // `\`+CRLF 是合法行继续：跳 3 字节（`\`+LF / `\`+孤立 \r 跳 2）
            if (i + 2 < src.len and src[i + 1] == '\r' and src[i + 2] == '\n') {
                i += 3;
            } else {
                i += 2;
            }
            continue;
        }
        if (c == '\n' or c == '\r') {
            // 裸换行：非法字符串吞到行尾，容错继续
            return .{ .kind = .illegal, .end = lineEndScalar(src, i) };
        }
        i += 1;
    }
    return .{ .kind = .illegal, .end = src.len };
}

/// 模板片段的标量版（scanner.scanTemplatePart 同语义）：逐字节找
/// `` ` ``、`\`、`$`；`${` 收尾为 head/middle，`` ` `` 收尾为
/// no_substitution/tail，EOF 未闭合为 illegal。
pub fn scanTemplatePartScalar(src: []const u8, start: usize) Scan {
    const from_backtick = src[start] == '`';
    var i = start + 1;
    while (i < src.len) {
        const c = src[i];
        if (c == '`') {
            return .{
                .kind = if (from_backtick) .no_substitution_template else .template_tail,
                .end = i + 1,
            };
        }
        if (c == '\\') {
            i += 2;
            continue;
        }
        if (c == '$' and i + 1 < src.len and src[i + 1] == '{') {
            return .{
                .kind = if (from_backtick) .template_head else .template_middle,
                .end = i + 2,
            };
        }
        i += 1;
    }
    return .{ .kind = .illegal, .end = src.len };
}

/// 标识符：纯标量贪心（两阶段版长标识符走 SIMD 续扫，这里刻意不用）。
/// 关键字不在热路径判别（粗流全归 identifier，只 `/` 路径现查）。
pub fn scanIdentifierScalar(src: []const u8, start: usize) Scan {
    var i = if (src[start] == '\\') start + 6 else if (src[start] < 0x80) start + 1 else start + unicode.decode(src, start).?.len;
    while (i < src.len) {
        const c = src[i];
        if (c == '\\') {
            const r = scanner.decodeIdentEscape(src, i) orelse break;
            if (!scanner.isIdentPartRune(r.cp)) break;
            i += 6;
            continue;
        }
        if (c < 0x80) {
            if (!simd.isIdentPart(c)) break;
            i += 1;
            continue;
        }
        const r = unicode.decode(src, i) orelse break;
        if (!unicode.isIdContinue(r.cp)) break;
        i += r.len;
    }
    return .{ .kind = .identifier, .end = i };
}

/// 非 ASCII：Unicode whitespace → ws 标记（驱动循环跳过，不落盘）；
/// ID_Start → 标识符；其余 illegal。
pub fn scanNonAsciiScalar(src: []const u8, start: usize) Scan {
    if (simd.unicodeWhitespaceLen(src, start)) |len| {
        return .{ .kind = .illegal, .end = start + len, .ws = true };
    }
    if (unicode.decode(src, start)) |r| {
        if (unicode.isIdStart(r.cp)) return scanUnicodeIdentifierScalar(src, start, r);
    }
    const len = @min(utf8LenScalar(src[start]), src.len - start);
    return .{ .kind = .illegal, .end = start + len };
}

/// scanUnicodeIdentifier 的标量版（首字符已验证，直通循环）。
fn scanUnicodeIdentifierScalar(src: []const u8, start: usize, first: unicode.Rune) Scan {
    var i = start + first.len;
    while (i < src.len) {
        const c = src[i];
        if (c == '\\') {
            const r = scanner.decodeIdentEscape(src, i) orelse break;
            if (!scanner.isIdentPartRune(r.cp)) break;
            i += 6;
            continue;
        }
        if (c < 0x80) {
            if (!simd.isIdentPart(c)) break;
            i += 1;
            continue;
        }
        const r = unicode.decode(src, i) orelse break;
        if (!unicode.isIdContinue(r.cp)) break;
        i += r.len;
    }
    return .{ .kind = .identifier, .end = i };
}

fn utf8LenScalar(first: u8) usize {
    return switch (first) {
        0xf0...0xf4 => 4,
        0xe0...0xef => 3,
        0xc0...0xdf => 2,
        else => 1,
    };
}
