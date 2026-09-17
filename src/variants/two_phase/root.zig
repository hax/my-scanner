//! 架构变体零：**两阶段 SIMD**（项目基座，语义层的同源实现）。
//!
//! 阶段 1（simd.classifyTokenStarts）：纯 SIMD、无分支地为每个字节建立
//! 分类位平面，推导 token 候选起点位图；换行位图是同趟副产品，扫描期
//! 零行跟踪成本，预填交付物 LineIndex（本引擎相对单阶段变体的独有红利：
//! 行号查询免二次 pass）。
//!
//! 阶段 2（consume）：按块 `@ctz` 迭代候选起点，scanAt 按首字节类别码
//! 贪心消费；lexeme 区间内的假起点用 `start < pos` 越过，整块被长
//! lexeme 覆盖时直接跳块（JSDoc 密集样本的主要成本在此）。所有状态
//! （pos/prev/tpl/nl_before）都是循环局部变量，由编译器驻进寄存器——
//! 数据流化的核心：扫描函数全是纯函数，没有隐藏的 store/load 链。
//!
//! 语义层（scanAt/tokenAt + 全部 scanXxx 纯函数 + dispatch 表 + 模板栈）
//! 在 ../../scanner.zig 单点共享：jump_vec 直接复用 scanner.scanAt 作为
//! 分发，scalar/bitmap 换跳跃实现但语义同源。差分测试以本变体为参考
//! 实现（crossCheck/expectSame 的 `want`）。
//!
//! trivia 不落盘（交付口径对齐 yuku）：候选间隙即 ASCII 空白 run，
//! unicode whitespace 走 tokenAt 的 ws 标记、注释由驱动循环前置判别——
//! 三者只顺路累积 newline_before，挂到下一个显著 lexeme 的 flags 上。

const std = @import("std");
const lexeme_mod = @import("../../lexeme.zig");
const scanner = @import("../../scanner.zig");
const simd = @import("../../simd.zig");

const Lexeme = scanner.Lexeme;
const LexemeKind = scanner.LexemeKind;
const Result = scanner.Result;
const TemplateStack = scanner.TemplateStack;

/// 扫描 src，返回 lexeme 序列（以 eof 收尾）+ 惰性行号索引。
pub fn scan(allocator: std.mem.Allocator, src: []const u8) !Result {
    std.debug.assert(src.len <= std.math.maxInt(u32));
    var tokens: std.ArrayList(Lexeme) = .empty;
    errdefer tokens.deinit(allocator);

    var cls = try simd.classifyTokenStarts(allocator, src);
    // masks 只在扫描期间使用（成功路径也释放）；line_breaks 是 classify
    // 的顺带产物，预填给 LineIndex（本引擎的行号地基零额外成本）
    defer cls.starts.deinit(allocator);
    errdefer allocator.free(cls.line_breaks);

    try consume(&tokens, allocator, src, &cls.starts, cls.line_breaks);

    return .{
        .tokens = try tokens.toOwnedSlice(allocator),
        .lines = .{ .src = src, .allocator = allocator, .breaks = cls.line_breaks },
    };
}

/// scan 的复用缓冲版本：调用方管理 lexeme 列表（bench 循环里避免反复分配）。
/// 不产出任何行号信息（行索引是惰性设计，纯词法化路径零行跟踪成本；
/// 本引擎的 classify 顺带算换行位图，用完即弃）。
pub fn scanInto(
    tokens: *std.ArrayList(Lexeme),
    allocator: std.mem.Allocator,
    src: []const u8,
) !void {
    var cls = try simd.classifyTokenStarts(allocator, src);
    defer cls.starts.deinit(allocator);
    defer allocator.free(cls.line_breaks);
    try consume(tokens, allocator, src, &cls.starts, cls.line_breaks);
}

/// classify 的换行位图上查 [from, to) 是否含行终止符
/// （\n、孤立 \r、U+2028/U+2029，与 LineIndex 同口径；位标记在行终止
/// 字节上）。两阶段引擎的 newline_before 检测全部走这里——位图是
/// classify 副产品，避免对空白 run / 注释体的二次扫描（单阶段变体
/// 没有位图，走扫描融合版 skipWhitespace/findBlockCommentEnd）。
fn breaksInRange(line_breaks: []const u32, from: usize, to: usize) bool {
    if (from >= to) return false;
    const first = from / simd.block_size;
    const last = (to - 1) / simd.block_size;
    var b = first;
    while (b <= last) : (b += 1) {
        var m = line_breaks[b];
        if (b == first) m &= @as(u32, std.math.maxInt(u32)) << @intCast(from % simd.block_size);
        if (b == last) {
            const hi = (to - 1) % simd.block_size;
            if (hi < simd.block_size - 1) m &= (@as(u32, 1) << @intCast(hi + 1)) - 1;
        }
        if (m != 0) return true;
    }
    return false;
}

/// 阶段 2：块内迭代候选位，贪心消费。lexeme 区间内的假起点用
/// `start < pos` 越过。所有状态（pos/prev/tpl/nl_before）都是循环局部
/// 变量，由编译器驻进寄存器——这是数据流化的核心：扫描函数全是纯函数，
/// 没有隐藏的 store/load 链。
///
/// trivia 不落盘（交付口径对齐 yuku）：候选间隙即 ASCII 空白 run，
/// unicode whitespace 走 tokenAt 的 ws 标记、注释由驱动循环前置判别——
/// 三者只顺路累积 newline_before，挂到下一个显著 lexeme 的 flags 上。
fn consume(
    tokens: *std.ArrayList(Lexeme),
    allocator: std.mem.Allocator,
    src: []const u8,
    starts: *const simd.TokenStarts,
    line_breaks: []const u32,
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
    for (starts.masks, 0..) |mask, bi| {
        // 整块已被上一个 lexeme 覆盖（如长块注释/长字符串的后续块）：
        // 直接跳过整块，避免逐假候选迭代（lib.dom.d.ts 这类 JSDoc 密集
        // 样本里，块注释内的 `*` `/` 全是假候选，这里是主要成本）
        if (bi * simd.block_size + simd.block_size <= pos) continue;
        // 一块最多 32 个候选 → 每 lexeme 的容量检查摊薄为每块一次
        try tokens.ensureUnusedCapacity(allocator, simd.block_size);
        var m = mask;
        while (m != 0) {
            const start = bi * simd.block_size + @as(usize, @ctz(m));
            m &= m - 1;
            if (start < pos) continue; // 上一个 lexeme 已越过该假候选
            if (start > pos and !nl_before) nl_before = breaksInRange(line_breaks, pos, start);
            const c0 = src[start];
            const s = blk: {
                if (c0 == '/' and start + 1 < src.len) {
                    const n = src[start + 1];
                    if (n == '/') {
                        // 行注释：体不含行终止符，结尾 \n 归后续 gap
                        pos = scanner.lineEnd(src, start);
                        continue;
                    }
                    if (n == '*') {
                        if (simd.findBlockCommentEnd(src, start + 2)) |end| {
                            if (!nl_before) nl_before = breaksInRange(line_breaks, start, end.end);
                            pos = end.end;
                            continue;
                        }
                        // 未闭合块注释：吞掉余下全部，illegal 落盘（错误可见）
                        break :blk scanner.unterminatedBlockComment(src);
                    }
                }
                break :blk scanner.scanAt(src, start, prev_kind, prev_text, prev2_text, &tpl);
            };
            if (s.ws) { // unicode whitespace：跳过，顺带置 flag
                if (!nl_before) nl_before = breaksInRange(line_breaks, start, s.end);
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
    }
    // 尾部空白不是候选起点，pos 可能落后于 src.len：补一次行终止符检测
    // （单阶段变体的尾部 run 在循环内自然走到，这里需要显式补），
    // eof 固定 start == end == src.len
    if (src.len > pos and !nl_before) nl_before = breaksInRange(line_breaks, pos, src.len);
    try tokens.append(allocator, .{
        .kind = .eof,
        .flags = if (nl_before) lexeme_mod.flag_newline_before else 0,
        .start = @intCast(src.len),
        .end = @intCast(src.len),
    });
}
