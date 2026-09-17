//! 架构变体一：**全标量单阶段**（对标 yuku 0.10.1）。
//!
//! 一条直线走到底：pos 循环扫空白 run → dispatch 首字节 → 贪心扫到
//! lexeme 终点。每个字节只被触碰一次，无位图、无第二趟。所有跳跃函数
//! （字符串/模板/注释/长标识符，jumps.zig）都是纯标量循环——刻意不用
//! simd.zig 的向量原语：这条线的意义就是"零 SIMD 的地基"，它与
//! jump_vec / 两阶段的差值 = 各向量化层的净贡献。
//!
//! 语义层（数字/标点/正则/Unicode 表/模板栈）与两阶段共享同一套函数，
//! 保证语义修复单点生效；架构层（驱动循环、dispatch.zig 分发与
//! jumps.zig 跳跃函数）本目录自治，可独立演化。差分测试由
//! compare-tsc（--variant=scalar）在 CI 兜底。

const std = @import("std");
const lexeme_mod = @import("../../lexeme.zig");
const scanner = @import("../../scanner.zig");
const common = @import("../common.zig");
const jumps = @import("jumps.zig");
const dispatch = @import("dispatch.zig");

const Lexeme = lexeme_mod.Lexeme;
const LexemeKind = lexeme_mod.LexemeKind;
const Result = scanner.Result;
const TemplateStack = scanner.TemplateStack;

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
                pos = jumps.lineEndScalar(src, pos);
                continue;
            }
            if (n == '*') {
                if (jumps.findBlockCommentEndScalar(src, pos + 2)) |end| {
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
        const s = dispatch.scanAtScalar(src, start, prev_kind, prev_text, prev2_text, &tpl);
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
