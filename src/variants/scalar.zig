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
//! 可独立演化。差分测试由 compare-tsc（--variant=scalar）在 CI 兜底。

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

/// 找行终止符（行注释/shebang/非法恢复的终点）：\n、\r、U+2028/U+2029
/// （与 scanner.lineEnd 同口径的标量版）。
fn lineEndScalar(src: []const u8, from: usize) usize {
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
fn findBlockCommentEndScalar(src: []const u8, from: usize) ?BcEnd {
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
fn scanStringScalar(src: []const u8, start: usize, quote: u8) Scan {
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

/// 非 ASCII：Unicode whitespace → ws 标记（驱动循环跳过，不落盘）；
/// ID_Start → 标识符；其余 illegal。
fn scanNonAsciiScalar(src: []const u8, start: usize) Scan {
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

// -- 首字节分发（共享 dispatch 表，跳跃函数换标量版）------------------------

inline fn tokenAtScalar(src: []const u8, start: usize, prev_kind: ?LexemeKind, prev_text: []const u8, prev2_text: []const u8) Scan {
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
        // 除号、正则两解（注释由驱动循环前置判别，不到这里）
        if (scanner.regexAllowedAfter(prev_kind, prev_text, prev2_text)) return scanner.scanRegex(src, start);
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
    prev2_text: []const u8,
    tpl: *TemplateStack,
) Scan {
    const s = tokenAtScalar(src, start, prev_kind, prev_text, prev2_text);
    // 栈空（不在任何模板内）时短路全部模板逻辑（同 scanner.scanAt）
    if (tpl.len > 0 and s.kind == .punct and src[start] == '}' and tpl.closesTemplate()) {
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
/// trivia 与两阶段同模型：不落盘——空白 run 原地跳过、注释快跳，
/// 只顺路累积 newline_before 挂到下一个显著 lexeme 的 flags 上。
pub fn scanInto(
    tokens: *std.ArrayList(Lexeme),
    allocator: std.mem.Allocator,
    src: []const u8,
) !void {
    var pos: usize = 0;
    var prev_kind: ?LexemeKind = null; // 上一个显著 lexeme，供 `/` 判别
    var prev_text: []const u8 = "";
    var prev2_text: []const u8 = ""; // prev 之前那个显著 lexeme 的文本（名字位置判别）
    var tpl: TemplateStack = .{};
    var nl_before = false; // 上一个显著 lexeme 之后的 trivia 是否含行终止符

    if (src.len >= 2 and src[0] == '#' and src[1] == '!') {
        const s = scanner.scanShebang(src);
        pos = s.end;
        prev_kind = s.kind;
        prev_text = src[0..s.end];
        try tokens.append(allocator, .{ .kind = .shebang, .start = 0, .end = @intCast(s.end) });
    }
    while (pos < src.len) {
        // 空白 run（ASCII + Unicode ws）整段跳过，换行检测融合同一趟
        const run = common.skipWhitespace(src, pos);
        if (run.end > pos) {
            if (!nl_before) nl_before = run.saw_lf;
            pos = run.end;
            if (pos >= src.len) break;
        }
        // 注释（标量快跳；块注释的换行检测融合进查找同一趟；未闭合块
        // 注释落到统一落盘路径产 illegal，错误可见）
        const c0 = src[pos];
        if (c0 == '/' and pos + 1 < src.len) {
            const n = src[pos + 1];
            if (n == '/') {
                pos = lineEndScalar(src, pos);
                continue;
            }
            if (n == '*') {
                if (findBlockCommentEndScalar(src, pos + 2)) |end| {
                    if (!nl_before) nl_before = end.saw_lf;
                    pos = end.end;
                    continue;
                }
            }
        }
        // 内联容量检查（冷路径才进增长函数）；一轮最多产一个 lexeme
        if (tokens.items.len == tokens.capacity) {
            try tokens.ensureUnusedCapacity(allocator, 1);
        }
        const start = pos;
        const s = scanAtScalar(src, start, prev_kind, prev_text, prev2_text, &tpl);
        pos = s.end;
        tokens.appendAssumeCapacity(.{
            .kind = s.kind,
            .flags = if (nl_before) lexeme_mod.flag_newline_before else 0,
            .start = @intCast(start),
            .end = @intCast(s.end),
        });
        nl_before = false;
        // 栈空且非 head 时 track 必为 no-op，短路省掉 switch（语义同）
        if (tpl.len > 0 or s.kind == .template_head) tpl.track(s.kind, src[start]);
        prev2_text = prev_text;
        prev_text = src[start..s.end];
        prev_kind = s.kind;
    }
    // 尾部空白 run 已跳过；eof 固定 start == end == src.len
    try tokens.append(allocator, .{
        .kind = .eof,
        .flags = if (nl_before) lexeme_mod.flag_newline_before else 0,
        .start = @intCast(src.len),
        .end = @intCast(src.len),
    });
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
        "x.return / v; x?.if / w; this.#return /2/ u",
    };
    for (cases) |src| try crossCheck(src);
}
