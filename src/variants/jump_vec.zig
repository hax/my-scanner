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
//! ASCII 空白 run 短者逐字节展开、长者 SIMD 块扫；注释 trivia 快跳
//! （不构造 lexeme 直接跳，对齐 yuku 的 skipWsAndComments）；字符串/
//! 模板/块注释/正则的终点查找复用共享语义层已有的 SIMD 原语。
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
/// trivia 与两阶段同模型：不落盘——ASCII 空白 run 原地跳过、unicode
/// ws 走 tokenAt 的 ws 标记、注释快跳，三者只顺路累积 newline_before，
/// 挂到下一个显著 lexeme 的 flags 上。
fn consumeDirect(
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
    // lexeme 密度启发式：真实代码 ≈ 1 lexeme / 6-9 字节（样本实测），按
    // src.len/8 一次性预留，之后每 lexeme 只留一条内联容量检查——
    // ensureUnusedCapacity 是独立函数，逐 lexeme 调用的开销实测占 12%
    try tokens.ensureUnusedCapacity(allocator, src.len / 8 + 1);
    while (pos < src.len) {
        const code = scanner.dispatch_table[src[pos]];
        if (code & scanner.Dispatch.whitespace != 0) {
            const c = src[pos];
            const run = skipWhitespace(src, pos + 1);
            // run 不含首字节的换行事实（skipWhitespace 从 pos+1 起扫）
            if (!nl_before) nl_before = c == '\n' or c == '\r' or run.saw_lf;
            pos = run.end;
            continue;
        }
        // 注释快跳（不构造 lexeme 直接跳，对齐 yuku 的
        // skipWsAndComments——行注释样本上省掉每注释一次的构造与分发）。
        // 块注释的换行检测融合进 findBlockCommentEnd 同一趟扫描；
        // 未闭合块注释落到统一落盘路径产 illegal（错误可见）
        if (code & scanner.Dispatch.slash != 0 and pos + 1 < src.len) {
            const n = src[pos + 1];
            if (n == '/') {
                pos = scanner.lineEnd(src, pos);
                continue;
            }
            if (n == '*') {
                if (simd.findBlockCommentEnd(src, pos + 2)) |end| {
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
        const s = scanner.scanAt(src, start, prev_kind, prev_text, prev2_text, &tpl);
        if (s.ws) { // unicode whitespace：跳过，顺带置 flag
            if (!nl_before) nl_before = scanner.wsIsLineTerminator(src, start);
            pos = s.end;
            continue;
        }
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
    // 尾部空白已在循环内跳过，pos == src.len；eof 固定 start == end == src.len
    try tokens.append(allocator, .{
        .kind = .eof,
        .flags = if (nl_before) lexeme_mod.flag_newline_before else 0,
        .start = @intCast(src.len),
        .end = @intCast(src.len),
    });
}

inline fn isAsciiWs(c: u8) bool {
    return c == ' ' or (c >= 0x09 and c <= 0x0D);
}

/// ASCII 空白 run 扫描结果：end 是 run 终点；saw_lf 表示 run 内是否含
/// 行终止符（\n、\r；U+2028/29 不走此路径——它们在主循环经 ws 标记
/// 单独判定，见 scanner.wsIsLineTerminator）。
const WsRun = struct { end: usize, saw_lf: bool };

/// ASCII 空白 run 的结尾（from 处可以是任意字节，按实际跳过）。
/// 短 run 逐字节展开（格式化代码的空白多为 0-2 字节：紧跟 lexeme、
/// 单空格或换行+缩进），长 run 转 SIMD 块扫。换行检测融合同一趟
/// 扫描（省掉对 run 的二次扫描）；SIMD 块命中 run 终点时换行位
/// 只计 ws 前缀，尾随的非空白不污染 saw_lf。
fn skipWhitespace(src: []const u8, from: usize) WsRun {
    var i = from;
    var saw_lf = false;
    inline for (0..4) |_| {
        if (i >= src.len or !isAsciiWs(src[i])) return .{ .end = i, .saw_lf = saw_lf };
        saw_lf = saw_lf or (src[i] == '\n' or src[i] == '\r');
        i += 1;
    }
    while (i < src.len) {
        if (src.len - i >= simd.block_size) {
            const chunk = simd.load(src, i);
            const inv = ~simd.whitespaceMask(chunk);
            const term = simd.newlineMask(chunk) |
                @as(simd.Mask, @bitCast(chunk == @as(simd.Chunk, @splat('\r'))));
            if (inv == 0) {
                saw_lf = saw_lf or (term != 0);
                i += simd.block_size;
                continue;
            }
            const stop: u5 = @intCast(@ctz(inv));
            const ws_prefix = (@as(simd.Mask, 1) << stop) - 1;
            saw_lf = saw_lf or ((term & ws_prefix) != 0);
            i += stop;
            break;
        }
        if (isAsciiWs(src[i])) {
            saw_lf = saw_lf or (src[i] == '\n' or src[i] == '\r');
            i += 1;
        } else break;
    }
    return .{ .end = i, .saw_lf = saw_lf };
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
        "x.return / v; x?.if / w; this.#return /2/ u",
    };
    for (cases) |src| try crossCheck(src);
}
