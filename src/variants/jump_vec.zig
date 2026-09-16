//! 架构变体二：**单阶段驱动 + SIMD 长跳跃**（对标 yuku main、swc、oxc）。
//!
//! 无候选位图，主循环逐 lexeme 顺序分发。设计假设（A/B 计量验证）：
//! SIMD 预分类的收益只在"跳跃"——长 run（空白/标识符）与长 lexeme
//! （字符串/注释/模板）由各自扫描器内部直接向前跳；单字符 punct 这类
//! 短 lexeme 跳 1-2 字节，预计算候选位图的一次全文件 pass 盖不过省下的
//! 迭代成本，标量分发反而更便宜。此外单阶段没有假候选：每次循环迭代
//! 必产真实进展（lexeme 或空白 run），字符串/注释内部的字节根本不进入
//! 主循环。
//!
//! 跳跃手段：dispatch_table 空白位一次表查合并「是否空白」与分发判断；
//! ASCII 空白 run 短者逐字节展开、长者 SIMD 块扫；注释 trivia 有快跳路径
//! （找终点直接落盘 comment lexeme，不过 tokenAt）；字符串/模板/块注释/
//! 正则的终点查找复用共享语义层已有的 SIMD 原语。
//!
//! 行号是惰性交付：扫描期零行跟踪成本（对齐 yuku 的交付物——它扫描期
//! 只带 1-bit line_terminator_before flag，行号由下游按需重算），首次
//! lineAt/lineCount 查询时才由 LineIndex 跑 simd.classifyLineBreaks
//! 物化。增量逐 span 补计与独立换行 pass 两方案均经实测否决/淘汰，
//! 实验弧见 docs/class-code-and-simd-lookup.md。
//!
//! 首字节分发与全部语义函数共享 scanner.scanAt/tokenAt：这条线的演化
//! 空间在跳跃原语与驱动循环，语义修复由共享层单点生效。

const std = @import("std");
const lexeme_mod = @import("../lexeme.zig");
const scanner = @import("../scanner.zig");
const simd = @import("../simd.zig");

const Lexeme = lexeme_mod.Lexeme;
const LexemeKind = lexeme_mod.LexemeKind;
const Result = scanner.Result;
const TemplateStack = scanner.TemplateStack;

pub fn scan(allocator: std.mem.Allocator, src: []const u8) !Result {
    std.debug.assert(src.len <= std.math.maxInt(u32));
    var tokens: std.ArrayList(Lexeme) = .empty;
    errdefer tokens.deinit(allocator);

    try consumeDirect(&tokens, allocator, src);

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
    try consumeDirect(tokens, allocator, src);
}

/// 单阶段驱动：无候选位图，主循环逐 lexeme 顺序分发。
/// trivia 与两阶段同模型：ASCII 空白 run 原地累积，unicode ws 经
/// scanNonAscii 产 whitespace kind 并入，遇显著 lexeme（含注释）
/// 由 emitTriviaRun 切成 whitespace/newline 落盘。
fn consumeDirect(
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
    // lexeme 密度启发式：真实代码 ≈ 1 lexeme / 4-6 字节（trivia 常驻后的
    // 语料实测口径待 bench 复测），按 src.len/6 一次性预留，之后每轮
    // 迭代只留一条内联容量检查
    try tokens.ensureUnusedCapacity(allocator, src.len / 6 + 2);
    while (pos < src.len) {
        const code = scanner.dispatch_table[src[pos]];
        if (code & scanner.Dispatch.whitespace != 0) {
            pos = skipWhitespace(src, pos + 1); // ASCII run 累积进 pending
            continue;
        }
        // 注释快跳：终点本来就要找，构造 comment lexeme 直接落盘，
        // 不过 tokenAt（未闭合块注释落到正常路径产 illegal，错误可见）
        if (code & scanner.Dispatch.slash != 0 and pos + 1 < src.len) {
            const n = src[pos + 1];
            if (n == '/' or n == '*') {
                const kind: LexemeKind = if (n == '/') .line_comment else .block_comment;
                const end = if (n == '/') scanner.lineEnd(src, pos) else simd.findBlockCommentEnd(src, pos + 2) orelse 0;
                if (end != 0) {
                    if (tokens.items.len + 3 > tokens.capacity) {
                        try tokens.ensureUnusedCapacity(allocator, 3);
                    }
                    scanner.emitTriviaRun(tokens, src, trivia_from, pos);
                    tokens.appendAssumeCapacity(.{ .kind = kind, .start = @intCast(pos) });
                    pos = end;
                    trivia_from = pos;
                    continue;
                }
            }
        }
        // 内联容量检查（冷路径才进增长函数）；一轮最多落盘 3 个
        if (tokens.items.len + 3 > tokens.capacity) {
            try tokens.ensureUnusedCapacity(allocator, 3);
        }
        const start = pos;
        const s = scanner.scanAt(src, start, prev_kind, prev_text, &tpl);
        pos = s.end;
        if (s.kind == .whitespace) continue; // unicode ws：并入 pending run
        scanner.emitTriviaRun(tokens, src, trivia_from, start);
        tokens.appendAssumeCapacity(.{ .kind = s.kind, .start = @intCast(start) });
        trivia_from = pos;
        if (s.kind != .line_comment and s.kind != .block_comment) {
            tpl.track(s.kind, src[start]);
            prev_kind = s.kind;
            prev_text = src[start..s.end];
        }
    }
    // 尾部空白已在循环内累积，pos == src.len；落盘后 eof 收尾
    try tokens.ensureUnusedCapacity(allocator, 2);
    scanner.emitTriviaRun(tokens, src, trivia_from, src.len);
    try tokens.append(allocator, .{ .kind = .eof, .start = @intCast(src.len) });
}

inline fn isAsciiWs(c: u8) bool {
    return c == ' ' or (c >= 0x09 and c <= 0x0D);
}

/// ASCII 空白 run 的结尾（from 处可以是任意字节，按实际跳过）。
/// 短 run 逐字节展开（格式化代码的空白多为 0-2 字节：紧跟 lexeme、
/// 单空格或换行+缩进），长 run 转 SIMD 块扫。Unicode whitespace 不在
/// 此处理：它在主循环经 scanAt → scanNonAscii 走 whitespace kind
/// 路径并入 pending run，语义与两阶段一致。
fn skipWhitespace(src: []const u8, from: usize) usize {
    var i = from;
    inline for (0..4) |_| {
        if (i >= src.len or !isAsciiWs(src[i])) return i;
        i += 1;
    }
    while (i < src.len) {
        if (src.len - i >= simd.block_size) {
            const inv = ~simd.whitespaceMask(simd.load(src, i));
            if (inv == 0) {
                i += simd.block_size;
                continue;
            }
            i += @as(usize, @ctz(inv));
            break;
        }
        if (isAsciiWs(src[i])) {
            i += 1;
        } else break;
    }
    return i;
}

// -- 测试：与两阶段交叉验证 ---------------------------------------------------

fn crossCheck(src: []const u8) !void {
    var a = try scanner.scan(std.testing.allocator, src);
    defer a.deinit(std.testing.allocator);
    var mine = try scan(std.testing.allocator, src);
    defer mine.deinit(std.testing.allocator);
    // 行号一致：两阶段预填位图 vs 单阶段惰性物化，语义必须相同
    try std.testing.expectEqual(try a.lineCount(), try mine.lineCount());
    if (mine.tokens.len != a.tokens.len) {
        std.debug.print("lexeme 数不一致：两阶段 {d}，jump_vec {d}\n", .{ a.tokens.len, mine.tokens.len });
        return error.TestTokenCountMismatch;
    }
    for (a.tokens, mine.tokens) |x, y| {
        try std.testing.expectEqualDeep(x, y);
    }
    // lineAt 抽查（每个 lexeme 起点与两阶段同值）
    for (a.tokens) |t| {
        try std.testing.expectEqual(try a.lines.lineAt(t.start), try mine.lines.lineAt(t.start));
    }
}

test "jump_vec 变体与两阶段交叉验证" {
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
        "// 注释里有孤立\rv\n",
        "/* 未闭合块注释",
        "`a${({b:1}).b}c${ /}/ }d`",
        "tag`a${x}b${ fn`y` }c` / re/g",
        "{ t = `a${x}b${y}c`; } f(`a '${x}'`) }",
    };
    for (cases) |src| try crossCheck(src);
}
