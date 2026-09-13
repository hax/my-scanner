//! 对比基准：my-scanner vs yuku lexer。
//!
//! 同进程、同文件、同计时器，口径对称：两个 lexer 都把产出的每个 token
//! append 到复用的 ArrayList（读文件与初始化不计入），取 N 轮最优。
//! 由 scripts/bench.sh 驱动（负责把 yuku 源码放到 .bench-deps/）。
//!
//! 注意 yuku 纯 scanner 与 tsc 同款设计：`>` 家族不合并、`/` 保守判除号，
//! 因此它的 token 数偏多，吞吐按各自 token 数计，互不影响对比。

const std = @import("std");
const Io = std.Io;
const my_scanner = @import("my_scanner");
const yuku = @import("yuku_lexer");

// yuku 的 lexer.zig 不导出 Token/SourceType（root.zig 也只导出 parser 层），
// 从函数签名里提取，避免把整个 parser 模块拉进来（连带 semantic/codegen）。
const YukuSourceType = @typeInfo(@TypeOf(yuku.Lexer.init)).@"fn".params[2].type.?;
const YukuToken = blk: {
    const ret = @typeInfo(@TypeOf(yuku.Lexer.nextToken)).@"fn".return_type.?;
    break :blk @typeInfo(ret).error_union.payload;
};

const usage_text =
    \\bench — my-scanner vs yuku lexer 对比基准
    \\
    \\用法:
    \\  bench [--repeats=N] <file>...
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    var repeats: usize = 10;
    var files: std.ArrayList([]const u8) = .empty;
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--repeats=")) {
            repeats = std.fmt.parseInt(usize, arg["--repeats=".len..], 10) catch 10;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try out.writeAll(usage_text);
            try out.flush();
            return;
        } else {
            try files.append(arena, arg);
        }
    }
    if (files.items.len == 0) {
        try out.writeAll(usage_text);
        try out.flush();
        return;
    }

    for (files.items) |path| {
        try benchFile(arena, init.io, out, path, repeats);
    }
    try out.flush();
}

fn benchFile(
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    path: []const u8,
    repeats: usize,
) !void {
    const src = std.Io.Dir.readFileAlloc(.cwd(), io, path, arena, .limited(1 << 32)) catch |err| {
        try out.print("{s}: 读取失败: {s}\n", .{ path, @errorName(err) });
        return;
    };
    const src_type: YukuSourceType = @enumFromInt(0); // script

    // ---- my-scanner ----
    var tokens: std.ArrayList(my_scanner.Token) = .empty;
    defer tokens.deinit(arena);
    var mine_best: i96 = std.math.maxInt(i96);
    var mine_count: usize = 0;
    for (0..repeats) |_| {
        const t0 = Io.Timestamp.now(io, .awake);
        _ = try my_scanner.scanInto(&tokens, arena, src, .{});
        const ns = t0.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds;
        mine_best = @min(mine_best, ns);
        mine_count = tokens.items.len;
        tokens.clearRetainingCapacity();
    }

    // ---- yuku ----
    var ytokens: std.ArrayList(YukuToken) = .empty;
    defer ytokens.deinit(arena);
    // yuku 的 Lexer 在 unicode 标识符等场景可能分配，用每轮 reset 的 arena，
    // 稳态下与 my-scanner 同样零系统分配
    var yarena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer yarena.deinit();

    // yuku 纯 scanner 与 tsc 同款设计：`/` 保守判除号，正则由 parser 在表达式
    // 位置调 reScanAsRegex 重扫。为保证两个 lexer 做出完全相同的正则/除号
    // 决策（否则 yuku 会在正则体上报错），用 my-scanner 的结果确定正则起点
    // 集合，yuku 循环命中时按其 parser 的方式重扫。
    var regex_starts = std.AutoHashMap(u32, void).init(arena);
    defer regex_starts.deinit();
    {
        const result = try my_scanner.scan(arena, src, .{});
        defer arena.free(result.tokens);
        for (result.tokens) |t| {
            if (t.kind == .regex) try regex_starts.put(t.start, {});
        }
    }

    var yuku_best: i96 = std.math.maxInt(i96);
    var yuku_count: usize = 0;
    var yuku_err: ?[]const u8 = null;

    // 模板上下文栈（模拟 yuku parser 的驱动）：head/middle 压一层，层内
    // 花括号平衡，平衡归零后的 `}` 是模板自己的 → reScanTemplateContinuation。
    // token 流里字符串/正则都是完整 token，不会干扰括号平衡。
    var tpl_stack: [64]i32 = undefined;
    var tpl_len: usize = 0;

    for (0..repeats) |_| {
        _ = yarena.reset(.retain_capacity);
        var lexer = try yuku.Lexer.init(src, yarena.allocator(), src_type, false);
        tpl_len = 0;
        const t0 = Io.Timestamp.now(io, .awake);
        var n: usize = 0;
        while (true) {
            var t = lexer.nextToken() catch |e| {
                if (yuku_err == null) {
                    const at = @min(lexer.cursor, src.len);
                    const lo = at - @min(at, 48);
                    try out.print("  yuku 报错于 offset {d}: {s}…▶{s}\n", .{
                        at,
                        src[lo..at],
                        src[at..@min(at + 48, src.len)],
                    });
                }
                yuku_err = @errorName(e);
                break;
            };
            if ((t.tag == .slash or t.tag == .slash_assign) and
                regex_starts.contains(t.span.start))
            {
                const re = lexer.reScanAsRegex(t.span.start) catch |e| {
                    yuku_err = @errorName(e);
                    break;
                };
                t = lexer.createToken(.regex_literal, re.span.start, re.span.end);
            }
            if (t.tag == .template_head or t.tag == .template_middle) {
                if (tpl_len < tpl_stack.len) {
                    tpl_stack[tpl_len] = 0;
                    tpl_len += 1;
                }
            } else if (tpl_len > 0) {
                if (t.tag == .left_brace) {
                    tpl_stack[tpl_len - 1] += 1;
                } else if (t.tag == .right_brace) {
                    if (tpl_stack[tpl_len - 1] == 0) {
                        t = lexer.reScanTemplateContinuation(t.span.start) catch |e| {
                            yuku_err = @errorName(e);
                            break;
                        };
                        if (t.tag == .template_tail) tpl_len -= 1;
                    } else {
                        tpl_stack[tpl_len - 1] -= 1;
                    }
                }
            }
            try ytokens.append(arena, t);
            n += 1;
            if (t.tag == .eof) break;
        }
        const ns = t0.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds;
        yuku_best = @min(yuku_best, ns);
        yuku_count = n;
        ytokens.clearRetainingCapacity();
    }

    try out.print("{s}  ({d} bytes, x{d} 轮取最优)\n", .{ path, src.len, repeats });
    try printRow(out, "mine", mine_best, src.len, mine_count);
    try printRow(out, "yuku", yuku_best, src.len, yuku_count);
    if (yuku_err) |e| try out.print("  （yuku 中途报 {s}，计扫到出错为止）\n", .{e});
    const ratio = @as(f64, @floatFromInt(yuku_best)) / @as(f64, @floatFromInt(mine_best));
    try out.print("  吞吐比 mine/yuku = {d:.2}x\n\n", .{ratio});
}

fn printRow(out: *Io.Writer, comptime label: []const u8, ns: i96, bytes: usize, count: usize) !void {
    const ms = @as(f64, @floatFromInt(ns)) / 1e6;
    const gbps = @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(ns));
    const mtoks = @as(f64, @floatFromInt(count)) * 1000.0 / @as(f64, @floatFromInt(ns));
    try out.print("  {s: <5} best {d:>8.2} ms   {d:>6.2} GB/s   {d:>8.1} Mtok/s   ({d} tokens)\n", .{
        label, ms, gbps, mtoks, count,
    });
}
