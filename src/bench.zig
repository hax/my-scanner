//! 架构矩阵对比基准：my-scanner 各变体 vs yuku lexer。
//!
//! 同进程、同文件、同计时器，口径对称：所有 Zig 实现都把产出的每个
//! token append 到复用的 ArrayList（读文件与初始化不计入），取 N 轮
//! 最优。由 scripts/bench.sh 驱动（负责把 yuku 源码放到 .bench-deps/）。
//!
//! 矩阵（架构族 → 自有实现 + 第三方参照）：
//!   全标量单阶段        → scalar     vs yuku-old（0.10.1 快照）
//!   单阶段 + SIMD 长跳跃 → jump_vec   vs yuku-main（perf(lexer) 之后）
//!   两阶段 SIMD         → two_phase  （主线）
//! swc / oxc 由 tools/lexbench-rs 独立计时，报告在 scripts/make-report.mjs
//! 汇总（跨语言进程无法同进程对拍）。
//!
//! 注意 yuku 纯 scanner 与 tsc 同款设计：`>` 家族不合并、`/` 保守判除号，
//! 因此各实现的 token 数不同，吞吐按各自 token 数计，互不影响对比。

const std = @import("std");
const Io = std.Io;
const my_scanner = @import("my_scanner");
const yuku_old = @import("yuku_lexer");
const yuku_main = @import("yuku_lexer_main");

const usage_text =
    \\bench — my-scanner 架构矩阵 vs yuku lexer 对比基准
    \\
    \\用法:
    \\  bench [--repeats=N] [--json=<path>] [--prim] <file>...
    \\
;

/// 一个实现的计时结果；yuku 中途报错记 null（输出里注明）
const RunResult = struct { best_ns: i96, tokens: usize };

const NamedResult = struct { name: []const u8, result: ?RunResult };

const FileRun = struct {
    path: []const u8,
    bytes: usize,
    results: []NamedResult,
};

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    var repeats: usize = 10;
    var prim = false;
    var json_path: ?[]const u8 = null;
    var files: std.ArrayList([]const u8) = .empty;
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--repeats=")) {
            repeats = std.fmt.parseInt(usize, arg["--repeats=".len..], 10) catch 10;
        } else if (std.mem.startsWith(u8, arg, "--json=")) {
            json_path = arg["--json=".len..];
        } else if (std.mem.eql(u8, arg, "--prim")) {
            prim = true;
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

    var runs: std.ArrayList(FileRun) = .empty;
    for (files.items) |path| {
        const run = try benchFile(arena, init.io, out, path, repeats, prim);
        try runs.append(arena, run);
    }
    try out.flush();

    if (json_path) |p| try writeJson(arena, init.io, p, runs.items);
}

fn benchFile(
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    path: []const u8,
    repeats: usize,
    prim: bool,
) !FileRun {
    const src = std.Io.Dir.readFileAlloc(.cwd(), io, path, arena, .limited(1 << 32)) catch |err| {
        try out.print("{s}: 读取失败: {s}\n", .{ path, @errorName(err) });
        std.process.exit(1);
    };

    var results: std.ArrayList(NamedResult) = .empty;
    defer results.deinit(arena);

    // ---- 自家矩阵：two_phase / scalar / jump_vec（同一驱动跑三遍）----
    const zig_impls = [_]struct { name: []const u8, variant: my_scanner.Variant }{
        .{ .name = "two_phase", .variant = .two_phase },
        .{ .name = "scalar", .variant = .scalar },
        .{ .name = "jump_vec", .variant = .jump_vec },
    };
    for (zig_impls) |impl| {
        var tokens: std.ArrayList(my_scanner.Token) = .empty;
        defer tokens.deinit(arena);
        var best: i96 = std.math.maxInt(i96);
        var count: usize = 0;
        for (0..repeats) |_| {
            const t0 = Io.Timestamp.now(io, .awake);
            _ = try impl.variant.scanInto(&tokens, arena, src, .{});
            const ns = t0.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds;
            best = @min(best, ns);
            count = tokens.items.len;
            tokens.clearRetainingCapacity();
        }
        try results.append(arena, .{ .name = impl.name, .result = .{ .best_ns = best, .tokens = count } });
    }

    // 阶段 1（SIMD 分类 pass）单独计时，隔离它在总扫描里的占比。
    // page_allocator 直接 alloc/free，避免 arena 的 no-op free 累积内存。
    // 同场加标量对照（classifyTokenStartsScalar，语义与 SIMD 版经交叉
    // 验证逐位一致），量化 SIMD 在分类 pass 的贡献。
    var cls_best: i96 = std.math.maxInt(i96);
    var scalar_best: i96 = std.math.maxInt(i96);
    for (0..repeats) |_| {
        {
            const t0 = Io.Timestamp.now(io, .awake);
            var cls = try my_scanner.simd.classifyTokenStarts(std.heap.page_allocator, src);
            const ns = t0.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds;
            cls.starts.deinit(std.heap.page_allocator);
            cls_best = @min(cls_best, ns);
        }
        {
            const t0 = Io.Timestamp.now(io, .awake);
            var cls = try my_scanner.simd.classifyTokenStartsScalar(std.heap.page_allocator, src);
            const ns = t0.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds;
            cls.starts.deinit(std.heap.page_allocator);
            scalar_best = @min(scalar_best, ns);
        }
    }

    // ---- yuku（基线快照 + 主干，同一驱动逻辑跑两遍）----

    // yuku 纯 scanner 与 tsc 同款设计：`/` 保守判除号，正则由 parser 在表达式
    // 位置调 reScanAsRegex 重扫。为保证两个 lexer 做出完全相同的正则/除号
    // 决策，用 my-scanner 的结果确定正则起点集合，命中时按其 parser 方式重扫。
    var regex_starts = std.AutoHashMap(u32, void).init(arena);
    defer regex_starts.deinit();
    {
        const result = try my_scanner.scan(arena, src, .{});
        defer arena.free(result.tokens);
        for (result.tokens) |t| {
            if (t.kind == .regex) try regex_starts.put(t.start, {});
        }
    }

    const find = struct {
        fn byName(list: []const NamedResult, name: []const u8) RunResult {
            for (list) |nr| {
                if (std.mem.eql(u8, nr.name, name)) return nr.result.?;
            }
            unreachable;
        }
    };

    try out.print("{s}  ({d} bytes, x{d} 轮取最优)\n", .{ path, src.len, repeats });
    for (zig_impls) |impl| {
        const r = find.byName(results.items, impl.name);
        try printRow(out, impl.name, r.best_ns, src.len, r.tokens);
    }
    {
        const mine = find.byName(results.items, "two_phase");
        const pct = @as(f64, @floatFromInt(cls_best)) * 100.0 / @as(f64, @floatFromInt(mine.best_ns));
        const ms = @as(f64, @floatFromInt(cls_best)) / 1e6;
        const gbps = @as(f64, @floatFromInt(src.len)) / @as(f64, @floatFromInt(cls_best));
        try out.print("  {s: <10} best {d:>8.2} ms   {d:>6.2} GB/s   （两阶段的阶段 1 分类 pass，占总扫描 {d:>5.1}%）\n", .{ "cls", ms, gbps, pct });
        const sms = @as(f64, @floatFromInt(scalar_best)) / 1e6;
        const sgbps = @as(f64, @floatFromInt(src.len)) / @as(f64, @floatFromInt(scalar_best));
        const speedup = @as(f64, @floatFromInt(scalar_best)) / @as(f64, @floatFromInt(cls_best));
        try out.print("  {s: <10} best {d:>8.2} ms   {d:>6.2} GB/s   （标量对照，SIMD {d:.1}x）\n", .{ "cls-s", sms, sgbps, speedup });
    }

    {
        const r = try runYuku(yuku_old, "yuku-old", arena, io, out, src, regex_starts, repeats);
        try printRow(out, "yuku-old", r.best, src.len, r.count);
        if (r.err) |e| try out.print("  （yuku-old 中途报 {s}，计扫到出错为止）\n", .{e});
        try results.append(arena, .{ .name = "yuku_old", .result = .{ .best_ns = r.best, .tokens = r.count } });
    }
    {
        const r = try runYuku(yuku_main, "yuku-main", arena, io, out, src, regex_starts, repeats);
        try printRow(out, "yuku-main", r.best, src.len, r.count);
        if (r.err) |e| try out.print("  （yuku-main 中途报 {s}，计扫到出错为止）\n", .{e});
        try results.append(arena, .{ .name = "yuku_main", .result = .{ .best_ns = r.best, .tokens = r.count } });
    }

    // 相对值一览（锚点：yuku-main）
    {
        const anchor = find.byName(results.items, "yuku_main");
        try out.print("  ", .{});
        for ([_][]const u8{ "two_phase", "scalar", "jump_vec" }) |name| {
            const r = find.byName(results.items, name);
            const ratio = @as(f64, @floatFromInt(anchor.best_ns)) / @as(f64, @floatFromInt(r.best_ns));
            try out.print("{s}/yuku-main={d:.2}x ", .{ name, ratio });
        }
        const yuku_gain = @as(f64, @floatFromInt(find.byName(results.items, "yuku_old").best_ns)) / @as(f64, @floatFromInt(anchor.best_ns));
        try out.print("（yuku 向量化收益 {d:.2}x）\n\n", .{yuku_gain});
    }

    if (prim) try primBench(io, out, src, repeats);
    return .{ .path = path, .bytes = src.len, .results = try results.toOwnedSlice(arena) };
}

/// 把全部 run 写成 JSON（供 scripts/make-report.mjs 汇总；路径由 ASCII
/// 语料名构成，无需转义）。
fn writeJson(arena: std.mem.Allocator, io: Io, path: []const u8, runs: []const FileRun) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(arena);
    const ap = std.fmt.allocPrint;

    try buf.appendSlice(arena, "{\"runs\":[");
    for (runs, 0..) |run, i| {
        if (i > 0) try buf.append(arena, ',');
        try buf.appendSlice(arena, try ap(arena, "{{\"file\":\"{s}\",\"bytes\":{d},\"results\":{{", .{ run.path, run.bytes }));
        for (run.results, 0..) |nr, j| {
            if (j > 0) try buf.append(arena, ',');
            if (nr.result) |r| {
                try buf.appendSlice(arena, try ap(arena, "\"{s}\":{{\"best_ns\":{d},\"tokens\":{d}}}", .{ nr.name, r.best_ns, r.tokens }));
            } else {
                try buf.appendSlice(arena, try ap(arena, "\"{s}\":null", .{nr.name}));
            }
        }
        try buf.appendSlice(arena, "}}");
    }
    try buf.appendSlice(arena, "]}\n");

    // 原子写入：先写临时文件再 rename，避免 CI 上读到半截 JSON
    const tmp = try ap(arena, "{s}.tmp", .{path});
    defer arena.free(tmp);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = buf.items });
    try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, io);
}

/// SIMD 原语 A/B：同一数据上 SIMD mask 版 vs 严格标量逐字节合成版，
/// 量化各原语自身的加速比（工作等价：都产出每块一个 u32 mask）。
fn primBench(io: Io, out: *Io.Writer, src: []const u8, repeats: usize) !void {
    const bs = my_scanner.simd.block_size;
    var acc: u32 = 0;

    inline for (.{ "identPartMask", "stringStopMask", "whitespaceMask" }) |name| {
        var best_s: i96 = std.math.maxInt(i96);
        var best_v: i96 = std.math.maxInt(i96);
        for (0..repeats) |_| {
            {
                var x: u32 = 0;
                const t0 = Io.Timestamp.now(io, .awake);
                var i: usize = 0;
                while (i + bs <= src.len) : (i += bs) {
                    const chunk = my_scanner.simd.load(src, i);
                    x ^= if (comptime std.mem.eql(u8, name, "identPartMask"))
                        my_scanner.simd.identPartMask(chunk)
                    else if (comptime std.mem.eql(u8, name, "stringStopMask"))
                        my_scanner.simd.stringStopMask(chunk, '"')
                    else
                        my_scanner.simd.whitespaceMask(chunk);
                }
                acc +%= x;
                best_s = @min(best_s, t0.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds);
            }
            {
                var x: u32 = 0;
                const t0 = Io.Timestamp.now(io, .awake);
                var i: usize = 0;
                while (i + bs <= src.len) : (i += bs) {
                    var m: u32 = 0;
                    for (src[i .. i + bs], 0..) |c, j| {
                        const hit = if (comptime std.mem.eql(u8, name, "identPartMask"))
                            my_scanner.simd.isIdentPart(c)
                        else if (comptime std.mem.eql(u8, name, "stringStopMask"))
                            (c == '"' or c == '\\' or c == '\n' or c == '\r')
                        else
                            (c == ' ' or (c >= 9 and c <= 13));
                        if (hit) m |= @as(u32, 1) << @intCast(j);
                    }
                    x ^= m;
                }
                acc +%= x;
                best_v = @min(best_v, t0.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds);
            }
        }
        const sgbps = @as(f64, @floatFromInt(src.len)) / @as(f64, @floatFromInt(best_s));
        const vgbps = @as(f64, @floatFromInt(src.len)) / @as(f64, @floatFromInt(best_v));
        try out.print("  prim {s: <16} SIMD {d:>6.2} GB/s   标量 {d:>6.2} GB/s   {d:>5.1}x\n", .{ name, sgbps, vgbps, @as(f64, @floatFromInt(best_v)) / @as(f64, @floatFromInt(best_s)) });
    }
    std.mem.doNotOptimizeAway(acc);
}

fn printRow(out: *Io.Writer, label: []const u8, ns: i96, bytes: usize, count: usize) !void {
    const ms = @as(f64, @floatFromInt(ns)) / 1e6;
    const gbps = @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(ns));
    const mtoks = @as(f64, @floatFromInt(count)) * 1000.0 / @as(f64, @floatFromInt(ns));
    try out.print("  {s: <10} best {d:>8.2} ms   {d:>6.2} GB/s   {d:>8.1} Mtok/s   ({d} tokens)\n", .{
        label, ms, gbps, mtoks, count,
    });
}

fn YukuTokList(comptime mod: type) type {
    return std.ArrayList(YukuTokenOf(mod));
}

fn YukuTokenOf(comptime mod: type) type {
    const ret = @typeInfo(@TypeOf(mod.Lexer.nextToken)).@"fn".return_type.?;
    return @typeInfo(ret).error_union.payload;
}

fn YukuSourceTypeOf(comptime mod: type) type {
    return @typeInfo(@TypeOf(mod.Lexer.init)).@"fn".params[2].type.?;
}

const YukuRun = struct { best: i96, count: usize, err: ?[]const u8 };

/// 用同一套驱动（正则重扫对齐 + 模板上下文栈）跑一个 yuku 版本的 lexer。
/// 两个版本共用 my-scanner 预计算的正则起点集合，决策完全一致。
fn runYuku(
    comptime mod: type,
    comptime label: []const u8,
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    src: []const u8,
    regex_starts: std.AutoHashMap(u32, void),
    repeats: usize,
) !YukuRun {
    const SourceType = YukuSourceTypeOf(mod);
    const src_type: SourceType = @enumFromInt(0); // script
    var ytokens: YukuTokList(mod) = .empty;
    defer ytokens.deinit(arena);

    // yuku 的 Lexer 在 unicode 标识符等场景可能分配，用每轮 reset 的 arena
    var yarena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer yarena.deinit();

    var best: i96 = std.math.maxInt(i96);
    var count: usize = 0;
    var err: ?[]const u8 = null;

    // 模板上下文栈（模拟 yuku parser 的驱动）：head/middle 压一层，层内
    // 花括号平衡，平衡归零后的 `}` 是模板自己的 → reScanTemplateContinuation
    var tpl_stack: [64]i32 = undefined;
    var tpl_len: usize = 0;

    for (0..repeats) |_| {
        _ = yarena.reset(.retain_capacity);
        var lexer = try mod.Lexer.init(src, yarena.allocator(), src_type, false);
        tpl_len = 0;
        const t0 = Io.Timestamp.now(io, .awake);
        var n: usize = 0;
        while (true) {
            var t = lexer.nextToken() catch |e| {
                if (err == null) {
                    const at = @min(lexer.cursor, src.len);
                    const lo = at - @min(at, 48);
                    try out.print("  {s} 报错于 offset {d}: {s}…▶{s}\n", .{
                        label, at, src[lo..at], src[at..@min(at + 48, src.len)],
                    });
                }
                err = @errorName(e);
                break;
            };
            if ((t.tag == .slash or t.tag == .slash_assign) and
                regex_starts.contains(t.span.start))
            {
                const re = lexer.reScanAsRegex(t.span.start) catch |e| {
                    err = @errorName(e);
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
                            err = @errorName(e);
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
        best = @min(best, ns);
        count = n;
        ytokens.clearRetainingCapacity();
    }
    return .{ .best = best, .count = count, .err = err };
}
