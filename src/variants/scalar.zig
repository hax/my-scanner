//! 架构变体一：**全标量单阶段**（对标 yuku 0.10.1）。
//!
//! 一条直线走到底：pos 循环扫空白 run → dispatch 首字节 → 贪心扫到
//! lexeme 终点。每个字节只被触碰一次，无位图、无第二趟。所有跳跃函数
//! （字符串/模板/注释/长标识符）都是纯标量循环——刻意不用 simd.zig 的
//! 向量原语，哪怕它就在手边：这条线的意义就是"零 SIMD 的地基"，
//! 它与 jump_vec / 两阶段的差值 = 各向量化层的净贡献。
//!
//! 语义层（数字/标点/正则/Unicode 表/模板栈）与两阶段共享同一套函数，
//! 保证语义修复单点生效；架构层（驱动循环与跳跃函数）本文件自治，
//! 可独立演化。差分正确性由 compare-tsc（--variant=scalar）在 CI 兜底。

const std = @import("std");
const lexeme_mod = @import("../lexeme.zig");
const scanner = @import("../scanner.zig");
const unicode = @import("../unicode.zig");
const simd = @import("../simd.zig");
const common = @import("common.zig");

const Lexeme = lexeme_mod.Lexeme;
const LexemeKind = lexeme_mod.LexemeKind;
const Scan = scanner.Scan;
const Result = scanner.Result;
const TemplateStack = scanner.TemplateStack;

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

/// start 处若是注释则返回 Scan；否则 null。
fn tryCommentScalar(src: []const u8, start: usize) ?Scan {
    if (start + 1 >= src.len or src[start] != '/') return null;
    if (src[start + 1] == '/') {
        return .{ .kind = .line_comment, .end = lineEndScalar(src, start) };
    }
    if (src[start + 1] == '*') {
        if (findBlockCommentEndScalar(src, start + 2)) |end| {
            return .{ .kind = .block_comment, .end = end };
        }
        return .{ .kind = .illegal, .end = src.len };
    }
    return null;
}

/// 单/双引号字符串：逐字节找 `引号|反斜杠|换行`，转义对跳 2。
fn scanStringScalar(src: []const u8, start: usize, quote: u8) Scan {
    var i = start + 1;
    while (i < src.len) {
        const c = src[i];
        if (c == quote) return .{ .kind = .string, .end = i + 1 };
        if (c == '\\') {
            i += 2;
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
fn scanTemplatePartScalar(src: []const u8, start: usize) Scan {
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
fn scanIdentifierScalar(src: []const u8, start: usize) Scan {
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

/// 非 ASCII：Unicode whitespace → whitespace kind（驱动循环并入空白 run）；
/// ID_Start → 标识符；其余 illegal。
fn scanNonAsciiScalar(src: []const u8, start: usize) Scan {
    if (simd.unicodeWhitespaceLen(src, start)) |len| {
        return .{ .kind = .whitespace, .end = start + len };
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

// -- 首字节分发（共享 dispatch 表，跳跃函数换标量版）------------------------

inline fn tokenAtScalar(src: []const u8, start: usize, prev_kind: ?LexemeKind, prev_text: []const u8) Scan {
    const c = src[start];
    const code = scanner.dispatch_table[c];

    if (code & scanner.Dispatch.punct_single != 0) {
        return .{ .kind = .punct, .end = start + 1 };
    }
    if (code & scanner.Dispatch.ident_start != 0) return scanIdentifierScalar(src, start);
    if (code & scanner.Dispatch.digit != 0) return scanner.scanNumber(src, start);
    if (code & scanner.Dispatch.quote != 0) {
        return if (c == '`') scanTemplatePartScalar(src, start) else scanStringScalar(src, start, c);
    }
    if (code & scanner.Dispatch.slash != 0) {
        if (tryCommentScalar(src, start)) |comment| return comment;
        if (scanner.regexAllowedAfter(prev_kind, prev_text)) return scanner.scanRegex(src, start);
        return scanner.scanPunct(src, start);
    }
    if (c == '\\') {
        if (scanner.decodeIdentEscape(src, start)) |r| {
            if (scanner.isIdentStartRune(r.cp)) return scanIdentifierScalar(src, start);
        }
        return .{ .kind = .illegal, .end = start + 1 };
    }
    if (code & scanner.Dispatch.punct_multi != 0) {
        if (c == '.' and start + 1 < src.len and simd.isDigit(src[start + 1])) {
            return scanner.scanNumber(src, start);
        }
        return scanner.scanPunct(src, start);
    }
    return scanNonAsciiScalar(src, start);
}

/// scanner.scanAt 的标量版：tokenAtScalar + 模板收尾拦截（`}` 在花括号
/// 计数归零的帧里是模板续片起点）。
inline fn scanAtScalar(
    src: []const u8,
    start: usize,
    prev_kind: ?LexemeKind,
    prev_text: []const u8,
    tpl: *TemplateStack,
) Scan {
    const s = tokenAtScalar(src, start, prev_kind, prev_text);
    if (s.kind == .punct and src[start] == '}' and tpl.closesTemplate()) {
        return scanTemplatePartScalar(src, start);
    }
    return s;
}

// -- 驱动循环 ---------------------------------------------------------------

pub fn scan(allocator: std.mem.Allocator, src: []const u8) !Result {
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

/// scan 的复用缓冲版本（与两阶段 scanInto 同签名，bench 同口径驱动）。
/// 不产出任何行号信息（行索引惰性，纯词法化路径零行跟踪成本）。
pub fn scanInto(
    tokens: *std.ArrayList(Lexeme),
    allocator: std.mem.Allocator,
    src: []const u8,
) !void {
    var pos: usize = 0;
    var prev_kind: ?LexemeKind = null; // 上一个非 trivia lexeme，供 `/` 判别
    var prev_text: []const u8 = "";
    var tpl: TemplateStack = .{};

    if (src.len >= 2 and src[0] == '#' and src[1] == '!') {
        const s = scanner.scanShebang(src);
        pos = s.end;
        prev_kind = s.kind;
        prev_text = src[0..s.end];
        try tokens.append(allocator, .{ .kind = .shebang, .start = 0 });
    }
    var trivia_from = pos; // pending 空白 run 起点（== pos 表示无待发射）
    while (pos < src.len) {
        // 整段空白 run（ASCII + Unicode ws）一次吞掉，累积进 pending run
        pos = common.skipWhitespace(src, pos);
        if (pos >= src.len) break;
        // 落盘最多 3 个：whitespace + newline + 本体
        if (tokens.items.len + 3 > tokens.capacity) {
            try tokens.ensureUnusedCapacity(allocator, 3);
        }
        const start = pos;
        const s = scanAtScalar(src, start, prev_kind, prev_text, &tpl);
        pos = s.end;
        scanner.emitTriviaRun(tokens, src, trivia_from, start);
        tokens.appendAssumeCapacity(.{ .kind = s.kind, .start = @intCast(start) });
        trivia_from = pos;
        if (s.kind != .line_comment and s.kind != .block_comment) {
            tpl.track(s.kind, src[start]);
            prev_kind = s.kind;
            prev_text = src[start..s.end];
        }
    }
    // 尾部空白 run 落盘；eof 固定 start == src.len
    try tokens.ensureUnusedCapacity(allocator, 2);
    scanner.emitTriviaRun(tokens, src, trivia_from, src.len);
    try tokens.append(allocator, .{ .kind = .eof, .start = @intCast(src.len) });
}

// -- 测试：与两阶段交叉验证 ---------------------------------------------------

fn crossCheck(src: []const u8) !void {
    var a = try scanner.scan(std.testing.allocator, src);
    defer a.deinit(std.testing.allocator);
    var mine = try scan(std.testing.allocator, src);
    defer mine.deinit(std.testing.allocator);
    // 行号一致：两阶段预填位图 vs scalar 惰性物化，语义必须相同
    try std.testing.expectEqual(try a.lineCount(), try mine.lineCount());
    if (mine.tokens.len != a.tokens.len) {
        std.debug.print("lexeme 数不一致：两阶段 {d}，scalar {d}\n", .{ a.tokens.len, mine.tokens.len });
        return error.TestTokenCountMismatch;
    }
    for (a.tokens, mine.tokens) |x, y| {
        try std.testing.expectEqualDeep(x, y);
    }
    for (a.tokens) |t| {
        try std.testing.expectEqual(try a.lines.lineAt(t.start), try mine.lines.lineAt(t.start));
    }
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
        "`a${({b:1}).b}c${ /}/ }d`",
        "tag`a${x}b${ fn`y` }c` / re/g",
        "{ t = `a${x}b${y}c`; } f(`a '${x}'`) }",
    };
    for (cases) |src| try crossCheck(src);
}
