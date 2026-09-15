//! 架构变体二：**单阶段驱动 + SIMD 长跳跃**（对标 yuku main、swc、oxc）。
//!
//! 无候选位图，主循环逐 token 顺序分发。设计假设（A/B 计量验证）：
//! SIMD 预分类的收益只在"跳跃"——长 run（空白/标识符）与长 token
//! （字符串/注释/模板）由各自扫描器内部直接向前跳；单字符 punct 这类
//! 短 token 跳 1-2 字节，预计算候选位图的一次全文件 pass 盖不过省下的
//! 迭代成本，标量分发反而更便宜。此外单阶段没有假候选：每次循环迭代
//! 必产真实进展（token 或空白 run），字符串/注释内部的字节根本不进入
//! 主循环。
//!
//! 跳跃手段：dispatch_table 空白位一次表查合并「是否空白」与分发判断；
//! ASCII 空白 run 短者逐字节展开、长者 SIMD 块扫；注释 trivia 不保留时
//! 连 token 都不构造、直接跳（对齐 yuku 的 skipWsAndComments）；字符串/
//! 模板/块注释/正则的终点查找复用共享语义层已有的 SIMD 原语。
//!
//! 行号按主干口径（计入 scanInto 计时）由 simd.classifyLineBreaks
//! 独立 pass 统一维护——增量逐 span 补计方案经实测为负收益，实验弧见
//! docs/roadmap.md。
//!
//! 首字节分发与全部语义函数共享 scanner.tokenAt：这条线的演化空间在
//! 跳跃原语与驱动循环，语义修复由共享层单点生效。

const std = @import("std");
const token_mod = @import("../token.zig");
const scanner = @import("../scanner.zig");
const simd = @import("../simd.zig");

const Token = token_mod.Token;
const Options = scanner.Options;
const Result = scanner.Result;

pub fn scan(allocator: std.mem.Allocator, src: []const u8, options: Options) !Result {
    std.debug.assert(src.len <= std.math.maxInt(u32));
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(allocator);

    // 换行 pass 的位图直接作 LineIndex 的地基（line_breaks 转移给 Result）
    const cls = try simd.classifyLineBreaks(allocator, src);
    errdefer allocator.free(cls.line_breaks);

    if (options.regex_starts) |list| try scanner.reserveRegexStarts(allocator, src, list);
    try consumeDirect(&tokens, allocator, src, options);

    const prefix = try allocator.alloc(u32, cls.line_breaks.len);
    errdefer allocator.free(prefix);
    var acc: u32 = 0;
    for (cls.line_breaks, 0..) |m, b| {
        prefix[b] = acc;
        acc += @popCount(m);
    }
    std.debug.assert(acc == cls.newlines); // 与单值计数交叉验证

    return .{
        .tokens = try tokens.toOwnedSlice(allocator),
        .line_count = @as(usize, acc) + 1,
        .lines = .{ .breaks = cls.line_breaks, .prefix = prefix, .len = src.len },
    };
}

/// scan 的复用缓冲版本（与两阶段 scanInto 同签名，bench 同口径驱动）。
/// 返回逻辑行数；换行 pass 计入计时（单阶段为行号付出的成本，如实反映
/// 架构差异）。
pub fn scanInto(
    tokens: *std.ArrayList(Token),
    allocator: std.mem.Allocator,
    src: []const u8,
    options: Options,
) !usize {
    const cls = try simd.classifyLineBreaks(allocator, src);
    defer allocator.free(cls.line_breaks);
    if (options.regex_starts) |list| try scanner.reserveRegexStarts(allocator, src, list);
    try consumeDirect(tokens, allocator, src, options);
    return cls.newlines + 1;
}

/// 单阶段驱动：无候选位图，主循环逐 token 顺序分发。
fn consumeDirect(
    tokens: *std.ArrayList(Token),
    allocator: std.mem.Allocator,
    src: []const u8,
    options: Options,
) !void {
    var pos: usize = 0;
    var prev: ?Token = null; // 上一个非注释 token，供 `/` 的正则/除号判别

    if (src.len >= 2 and src[0] == '#' and src[1] == '!') {
        const t = scanner.scanShebang(src);
        pos = t.end;
        prev = t;
        try tokens.append(allocator, t);
    }
    // token 密度启发式：真实代码 ≈ 1 token / 6-9 字节（语料实测），按
    // src.len/8 一次性预留，之后每 token 只留一条内联容量检查——
    // ensureUnusedCapacity 是独立函数，逐 token 调用的开销实测占 12%
    try tokens.ensureUnusedCapacity(allocator, src.len / 8 + 1);
    while (pos < src.len) {
        const code = scanner.dispatch_table[src[pos]];
        if (code & scanner.Dispatch.whitespace != 0) {
            pos = skipWhitespace(src, pos + 1);
            continue;
        }
        // 注释是 trivia：不保留时连 token 都不构造，直接跳（对齐 yuku 的
        // skipWsAndComments——行注释语料上省掉每注释一次的 token 构造与
        // 分发）。未闭合块注释落到正常路径产 illegal（错误可见）
        if (code & scanner.Dispatch.slash != 0 and !options.keep_comments and pos + 1 < src.len) {
            const n = src[pos + 1];
            if (n == '/') {
                pos = scanner.lineEnd(src, pos);
                continue;
            }
            if (n == '*') {
                if (simd.findBlockCommentEnd(src, pos + 2)) |end| {
                    pos = end;
                    continue;
                }
            }
        }
        // 内联容量检查（冷路径才进增长函数）；一轮最多产一个 token
        if (tokens.items.len == tokens.capacity) {
            try tokens.ensureUnusedCapacity(allocator, 1);
        }
        const tok = scanner.tokenAt(src, pos, prev, options.regex_starts);
        pos = tok.end;
        if (tok.kind == .comment or tok.kind == .whitespace) {
            if (options.keep_comments) tokens.appendAssumeCapacity(tok);
            continue;
        }
        prev = tok;
        tokens.appendAssumeCapacity(tok);
    }
    // 尾部空白已在循环内跳过，pos == src.len；eof 固定 start == end == src.len
    try tokens.append(allocator, .{ .kind = .eof, .start = @intCast(src.len), .end = @intCast(src.len) });
}

inline fn isAsciiWs(c: u8) bool {
    return c == ' ' or (c >= 0x09 and c <= 0x0D);
}

/// ASCII 空白 run 的结尾（from 处可以是任意字节，按实际跳过）。
/// 短 run 逐字节展开（格式化代码的空白多为 0-2 字节：紧跟 token、
/// 单空格或换行+缩进），长 run 转 SIMD 块扫。Unicode whitespace 不在
/// 此处理：它在主循环经 tokenAt → scanNonAscii 走 .whitespace token
/// 路径，语义与两阶段一致。
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

fn crossCheck(src: []const u8, keep_comments: bool) !void {
    var a = try scanner.scan(std.testing.allocator, src, .{ .keep_comments = keep_comments });
    defer a.deinit(std.testing.allocator);
    var mine: std.ArrayList(Token) = .empty;
    defer mine.deinit(std.testing.allocator);
    const line_count = try scanInto(&mine, std.testing.allocator, src, .{ .keep_comments = keep_comments });
    try std.testing.expectEqual(a.line_count, line_count);
    if (mine.items.len != a.tokens.len) {
        std.debug.print("token 数不一致：两阶段 {d}，jump_vec {d}\n", .{ a.tokens.len, mine.items.len });
        return error.TestTokenCountMismatch;
    }
    for (a.tokens, mine.items) |x, y| {
        try std.testing.expectEqualDeep(x, y);
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
    };
    // 注释快跳（!keep_comments）与 tokenAt 注释路径（keep_comments）都要测
    for (cases) |cases_src| {
        try crossCheck(cases_src, false);
        try crossCheck(cases_src, true);
    }
}
