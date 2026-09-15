//! 架构变体一：**全标量单阶段**（对标 yuku 0.10.1）。
//!
//! 一条直线走到底：pos 循环跳过空白 → dispatch 首字节 → 贪心扫到
//! token 终点。每个字节只被触碰一次，无位图、无第二趟。所有跳跃函数
//! （字符串/模板/注释/长标识符）都是纯标量循环——刻意不用 simd.zig 的
//! 向量原语，哪怕它就在手边：这条线的意义就是"零 SIMD 的地基"，
//! 它与 jump_vec / 两阶段的差值 = 各向量化层的净贡献。
//!
//! 语义层（数字/标点/正则/关键字/Unicode 表）与两阶段共享同一套函数，
//! 保证语义修复单点生效；架构层（驱动循环与跳跃函数）本文件自治，
//! 可独立演化。差分正确性由 compare-tsc（--variant=scalar）在 CI 兜底。

const std = @import("std");
const token_mod = @import("../token.zig");
const scanner = @import("../scanner.zig");
const unicode = @import("../unicode.zig");
const simd = @import("../simd.zig");
const common = @import("common.zig");

const Token = token_mod.Token;
const TokenKind = token_mod.TokenKind;
const Options = scanner.Options;
const Result = scanner.Result;

// -- 标量跳跃函数（对应两阶段里的 SIMD 版）--------------------------------

/// 找 '\n'（行注释/shebang/非法恢复的终点）。
fn lineEndScalar(src: []const u8, from: usize) usize {
    var i = from;
    while (i < src.len) : (i += 1) {
        if (src[i] == '\n') return i;
    }
    return i;
}

/// 从 from 起找下一个 `*/`（返回其后一位），找不到 null。逐字节。
fn findBlockCommentEndScalar(src: []const u8, from: usize) ?usize {
    var i = from;
    while (i + 1 < src.len) : (i += 1) {
        if (src[i] == '*' and src[i + 1] == '/') return i + 2;
    }
    return null;
}

/// start 处若是注释则返回 token；否则 null。
fn tryCommentScalar(src: []const u8, start: usize) ?Token {
    if (start + 1 >= src.len or src[start] != '/') return null;
    if (src[start + 1] == '/') {
        return .{ .kind = .comment, .start = @intCast(start), .end = @intCast(lineEndScalar(src, start)) };
    }
    if (src[start + 1] == '*') {
        if (findBlockCommentEndScalar(src, start + 2)) |end| {
            return .{ .kind = .comment, .start = @intCast(start), .end = @intCast(end) };
        }
        return .{ .kind = .illegal, .start = @intCast(start), .end = @intCast(src.len) };
    }
    return null;
}

/// 单/双引号字符串：逐字节找 `引号|反斜杠|换行`，转义对跳 2。
fn scanStringScalar(src: []const u8, start: usize, quote: u8) Token {
    var i = start + 1;
    while (i < src.len) {
        const c = src[i];
        if (c == quote) return .{ .kind = .string, .start = @intCast(start), .end = @intCast(i + 1) };
        if (c == '\\') {
            i += 2;
            continue;
        }
        if (c == '\n' or c == '\r') {
            // 裸换行：非法字符串吞到行尾，容错继续
            return .{ .kind = .illegal, .start = @intCast(start), .end = @intCast(lineEndScalar(src, i)) };
        }
        i += 1;
    }
    return .{ .kind = .illegal, .start = @intCast(start), .end = @intCast(src.len) };
}

/// 模板字面量：逐字节找 `` ` ``、`\`、`$`；`${}` 子表达式花括号平衡。
fn scanTemplateScalar(src: []const u8, start: usize) Token {
    var i = start + 1;
    while (i < src.len) {
        const c = src[i];
        if (c == '`') return .{ .kind = .template, .start = @intCast(start), .end = @intCast(i + 1) };
        if (c == '\\') {
            i += 2;
            continue;
        }
        if (c == '$' and i + 1 < src.len and src[i + 1] == '{') {
            i = scanTemplateSubstitutionScalar(src, i + 2);
            continue;
        }
        i += 1;
    }
    return .{ .kind = .illegal, .start = @intCast(start), .end = @intCast(src.len) };
}

/// `${...}` 边界扫描（scanTemplateSubstitution 的纯标量版，同一设计）：
/// 逐 token 扫描（tokenAtScalar + regexAllowedAfter，与主循环同口径），
/// 返回配对 `}` 之后的位置；token 只用于定边界，全部丢弃。字符串、注释、
/// 嵌套模板、正则（含 pattern 里的 `}` / `//` / `/*`）都无法骗过配对。
fn scanTemplateSubstitutionScalar(src: []const u8, from: usize) usize {
    var depth: usize = 1;
    var i = from;
    var prev: ?Token = null; // 与主循环同口径：上一个非注释/非空白 token
    while (i < src.len) {
        const c = src[i];
        if (c == ' ' or (c >= 9 and c <= 13)) {
            i += 1; // ASCII trivia 逐字节（子表达式通常很小）
            continue;
        }
        const t = tokenAtScalar(src, i, prev);
        if (t.end <= i) return src.len; // 防御：token 不前进按未闭合处理
        i = t.end;
        switch (t.kind) {
            .comment, .whitespace => continue, // trivia 不进 prev（同主循环）
            .punct => {
                const text = t.slice(src);
                if (text[0] == '{') {
                    depth += 1;
                } else if (text[0] == '}') {
                    depth -= 1;
                    if (depth == 0) return i;
                }
                prev = t;
            },
            else => prev = t,
        }
    }
    return i; // EOF 未闭合
}

/// 标识符：纯标量贪心（两阶段版长标识符走 SIMD 续扫，这里刻意不用）。
fn scanIdentifierScalar(src: []const u8, start: usize) Token {
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
    const kind: TokenKind = if (scanner.isKeyword(src[start..i])) .keyword else .identifier;
    return .{ .kind = kind, .start = @intCast(start), .end = @intCast(i) };
}

/// 私有名 `#foo`（scanPrivateName 的标量 ident 版）。
fn scanPrivateNameScalar(src: []const u8, start: usize) Token {
    if (start + 1 < src.len) {
        const c = src[start + 1];
        const ok = simd.isIdentStart(c) or (c == '\\' and if (scanner.decodeIdentEscape(src, start + 1)) |r| scanner.isIdentStartRune(r.cp) else false) or
            (c >= 0x80 and if (unicode.decode(src, start + 1)) |r| unicode.isIdStart(r.cp) else false);
        if (ok) {
            const body = scanIdentifierScalar(src, start + 1);
            return .{ .kind = .private_name, .start = @intCast(start), .end = body.end };
        }
    }
    return .{ .kind = .illegal, .start = @intCast(start), .end = @intCast(start + 1) };
}

/// 非 ASCII：Unicode whitespace → trivia；ID_Start → 标识符；其余 illegal。
fn scanNonAsciiScalar(src: []const u8, start: usize) Token {
    if (simd.unicodeWhitespaceLen(src, start)) |len| {
        return .{ .kind = .whitespace, .start = @intCast(start), .end = @intCast(start + len) };
    }
    if (unicode.decode(src, start)) |r| {
        if (unicode.isIdStart(r.cp)) return scanIdentifierScalar(src, start);
    }
    const len = @min(utf8LenScalar(src[start]), src.len - start);
    return .{ .kind = .illegal, .start = @intCast(start), .end = @intCast(start + len) };
}

fn utf8LenScalar(first: u8) usize {
    return switch (first) {
        0xf0...0xf4 => 4,
        0xe0...0xef => 3,
        0xc0...0xdf => 2,
        else => 1,
    };
}

// -- 首字节分发（共享 dispatch 表，跳跃函数换标量版）------------------------

inline fn tokenAtScalar(src: []const u8, start: usize, prev: ?Token) Token {
    const c = src[start];
    const code = scanner.dispatch_table[c];

    if (code & scanner.Dispatch.punct_single != 0) {
        return .{ .kind = .punct, .start = @intCast(start), .end = @intCast(start + 1) };
    }
    if (code & scanner.Dispatch.ident_start != 0) return scanIdentifierScalar(src, start);
    if (code & scanner.Dispatch.digit != 0) return scanner.scanNumber(src, start);
    if (code & scanner.Dispatch.quote != 0) {
        return if (c == '`') scanTemplateScalar(src, start) else scanStringScalar(src, start, c);
    }
    if (code & scanner.Dispatch.slash != 0) {
        if (tryCommentScalar(src, start)) |comment| return comment;
        if (scanner.regexAllowedAfter(prev, src)) return scanner.scanRegex(src, start);
        return scanner.scanPunct(src, start);
    }
    if (code & scanner.Dispatch.hash != 0) return scanPrivateNameScalar(src, start);
    if (c == '\\') {
        if (scanner.decodeIdentEscape(src, start)) |r| {
            if (scanner.isIdentStartRune(r.cp)) return scanIdentifierScalar(src, start);
        }
        return .{ .kind = .illegal, .start = @intCast(start), .end = @intCast(start + 1) };
    }
    if (code & scanner.Dispatch.punct_multi != 0) {
        if (c == '.' and start + 1 < src.len and simd.isDigit(src[start + 1])) {
            return scanner.scanNumber(src, start);
        }
        return scanner.scanPunct(src, start);
    }
    return scanNonAsciiScalar(src, start);
}

// -- 驱动循环 ---------------------------------------------------------------

pub fn scan(allocator: std.mem.Allocator, src: []const u8, options: Options) !Result {
    std.debug.assert(src.len <= std.math.maxInt(u32));
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(allocator);
    const line_count = try scanInto(&tokens, allocator, src, options);
    const lines = try common.buildLineIndex(allocator, src);
    errdefer allocator.free(lines.breaks);
    errdefer allocator.free(lines.prefix);
    return .{
        .tokens = try tokens.toOwnedSlice(allocator),
        .line_count = line_count,
        .lines = lines,
    };
}

/// scan 的复用缓冲版本（与两阶段 scanInto 同签名，bench 同口径驱动）。
/// 返回逻辑行数。
pub fn scanInto(
    tokens: *std.ArrayList(Token),
    allocator: std.mem.Allocator,
    src: []const u8,
    options: Options,
) !usize {
    var pos: usize = 0;
    var prev: ?Token = null; // 上一个非注释 token，供 `/` 的正则/除号判别
    var newlines: usize = 0;

    if (src.len >= 2 and src[0] == '#' and src[1] == '!') {
        const t = scanner.scanShebang(src);
        pos = t.end;
        prev = t;
        try tokens.append(allocator, t);
    }

    while (true) {
        const ws = common.skipWhitespace(src, pos);
        pos = ws.pos;
        newlines += ws.newlines;
        if (pos >= src.len) break;

        const tok = tokenAtScalar(src, pos, prev);
        pos = tok.end;
        if (common.countsNewlines(tok.kind)) {
            newlines += common.countLogicalNewlines(src[tok.start..tok.end]);
        }
        if (tok.kind == .comment or tok.kind == .whitespace) {
            if (options.keep_comments) try tokens.append(allocator, tok);
            continue;
        }
        prev = tok;
        try tokens.append(allocator, tok);
    }
    try tokens.append(allocator, .{ .kind = .eof, .start = @intCast(src.len), .end = @intCast(src.len) });
    return newlines + 1;
}

// -- 测试：与两阶段交叉验证 ---------------------------------------------------

fn crossCheck(src: []const u8) !void {
    var a = try scanner.scan(std.testing.allocator, src, .{});
    defer a.deinit(std.testing.allocator);
    var mine: std.ArrayList(Token) = .empty;
    defer mine.deinit(std.testing.allocator);
    _ = try scanInto(&mine, std.testing.allocator, src, .{});
    try std.testing.expectEqual(a.line_count, (try countLines(src)));
    if (mine.items.len != a.tokens.len) {
        std.debug.print("token 数不一致：两阶段 {d}，scalar {d}\n", .{ a.tokens.len, mine.items.len });
        return error.TestTokenCountMismatch;
    }
    for (a.tokens, mine.items) |x, y| {
        try std.testing.expectEqualDeep(x, y);
    }
}

fn countLines(src: []const u8) !usize {
    var mine: std.ArrayList(Token) = .empty;
    defer mine.deinit(std.testing.allocator);
    return scanInto(&mine, std.testing.allocator, src, .{});
}

test "scalar 变体与两阶段交叉验证" {
    const cases = [_][]const u8{
        "let x = 42;",
        "const s = \"a\\\"b\" + 'c';",
        "/* 块\n注释 */ var t = `模板 ${x + `嵌套${y}`} 尾`;",
        "// 行注释\nfoo?.bar!.baz ?? 1_000n;",
        "a / b / c; let re = /ab[/]/gu;",
        "中文标识符π = 0x1f + 0o17 + 0b101;",
        "#priv in obj;",
        "\\u0041bc = 1;",
        "x = \"未闭合\n",
        "a\r\nb\rc",
    };
    for (cases) |src| try crossCheck(src);
}
