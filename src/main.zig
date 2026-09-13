//! CLI 入口：扫描文件、打印统计；`--dump` 看 token；`--bench=N` 测性能。

const std = @import("std");
const Io = std.Io;

const my_scanner = @import("my_scanner");

const usage_text =
    \\my-scanner — 探索 SIMD 加速的 JS/TS 词法分析器
    \\
    \\用法:
    \\  my-scanner [选项] <file>...
    \\
    \\选项:
    \\  --dump           打印每个 token（偏移、类别、文本）
    \\  --keep-comments  输出注释 token（默认视为 trivia 跳过）
    \\  --bench=N        额外扫描 N 轮，报告 best/avg 耗时与吞吐
    \\  -h, --help       显示本帮助
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    var options: my_scanner.Options = .{};
    var dump = false;
    var bench: usize = 0;
    var files: std.ArrayList([]const u8) = .empty;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try out.writeAll(usage_text);
            try out.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--dump")) {
            dump = true;
        } else if (std.mem.eql(u8, arg, "--keep-comments")) {
            options.keep_comments = true;
        } else if (std.mem.startsWith(u8, arg, "--bench=")) {
            bench = std.fmt.parseInt(usize, arg["--bench=".len..], 10) catch 0;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try out.print("未知参数: {s}\n\n", .{arg});
            try out.writeAll(usage_text);
            try out.flush();
            std.process.exit(2);
        } else {
            try files.append(arena, arg);
        }
    }

    if (files.items.len == 0) {
        try out.writeAll(usage_text);
        try out.flush();
        return;
    }

    var had_error = false;
    for (files.items) |path| {
        had_error = try scanFile(arena, init.io, out, path, options, dump, bench) or had_error;
    }
    try out.flush();
    if (had_error) std.process.exit(1);
}

fn scanFile(
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    path: []const u8,
    options: my_scanner.Options,
    dump: bool,
    bench: usize,
) !bool {
    const src = std.Io.Dir.readFileAlloc(.cwd(), io, path, arena, .limited(1 << 32)) catch |err| {
        try out.print("{s}: 读取失败: {s}\n", .{ path, @errorName(err) });
        return true;
    };

    const result = try my_scanner.scan(arena, src, options);

    if (dump) {
        for (result.tokens) |t| {
            try out.print("{d:>8}  {s}\t{s}\n", .{ t.start, @tagName(t.kind), t.slice(src) });
        }
    }

    // kind 分布摘要（跳过计数为 0 的类别）
    var counts: [@typeInfo(my_scanner.TokenKind).@"enum".fields.len]usize = @splat(0);
    for (result.tokens) |t| counts[@intFromEnum(t.kind)] += 1;

    try out.print("{s}: {d} bytes, {d} tokens, {d} lines (", .{
        path, src.len, result.tokens.len, result.line_count,
    });
    const fields = @typeInfo(my_scanner.TokenKind).@"enum".fields;
    var first = true;
    inline for (fields, 0..) |f, i| {
        if (counts[i] > 0) {
            if (!first) try out.writeAll(", ");
            try out.print("{s}={d}", .{ f.name, counts[i] });
            first = false;
        }
    }
    try out.writeAll(")\n");

    if (bench > 0) {
        var tokens: std.ArrayList(my_scanner.Token) = .empty;
        defer tokens.deinit(arena);
        var best: i96 = std.math.maxInt(i96);
        var total: i96 = 0;
        for (0..bench) |_| {
            const t0 = Io.Timestamp.now(io, .awake);
            _ = try my_scanner.scanInto(&tokens, arena, src, options);
            const ns = t0.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds;
            best = @min(best, ns);
            total += ns;
            tokens.clearRetainingCapacity();
        }
        const avg = @divTrunc(total, @as(i96, @intCast(bench)));
        const gbps = @as(f64, @floatFromInt(src.len)) / @as(f64, @floatFromInt(avg));
        const mtoks = @as(f64, @floatFromInt(result.tokens.len * 1_000_000)) /
            @as(f64, @floatFromInt(avg));
        try out.print(
            "  bench x{d}: best {d} ns, avg {d} ns, {d:.2} GB/s, {d:.2} Mtok/s\n",
            .{ bench, best, avg, gbps, mtoks },
        );
    }
    return false;
}
