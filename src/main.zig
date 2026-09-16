//! CLI 入口：扫描文件、打印统计；`--dump` 看 lexeme；`--bench=N` 测性能。

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
    \\  --dump           打印每个 lexeme（偏移、类别、文本）
    \\  --variant=NAME   架构变体: two_phase（默认）| scalar | jump_vec
    \\  --bench=N        额外扫描 N 轮，报告 best/avg 耗时与吞吐
    \\  --emit-regex-starts  只输出正则起点决策集（每行一个偏移，含模板内）
    \\  -h, --help       显示本帮助
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    var variant: my_scanner.Variant = .two_phase;
    var dump = false;
    var bench: usize = 0;
    var emit_regex_starts = false;
    var files: std.ArrayList([]const u8) = .empty;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try out.writeAll(usage_text);
            try out.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--dump")) {
            dump = true;
        } else if (std.mem.startsWith(u8, arg, "--variant=")) {
            const name = arg["--variant=".len..];
            variant = std.meta.stringToEnum(my_scanner.Variant, name) orelse {
                try out.print("未知变体: {s}（可选 two_phase | scalar | jump_vec）\n\n", .{name});
                try out.writeAll(usage_text);
                try out.flush();
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "--bench=")) {
            bench = std.fmt.parseInt(usize, arg["--bench=".len..], 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--emit-regex-starts")) {
            emit_regex_starts = true;
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
        had_error = try scanFile(arena, init.io, out, path, variant, dump, bench, emit_regex_starts) or had_error;
    }
    try out.flush();
    if (had_error) std.process.exit(1);
}

fn writeEscaped(out: *Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '\\' => try out.writeAll("\\\\"),
            '\n' => try out.writeAll("\\n"),
            '\r' => try out.writeAll("\\r"),
            '\t' => try out.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try out.print("\\x{x:0>2}", .{c});
                } else {
                    try out.writeAll(&.{c});
                }
            },
        }
    }
}

fn scanFile(
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    path: []const u8,
    variant: my_scanner.Variant,
    dump: bool,
    bench: usize,
    emit_regex_starts: bool,
) !bool {
    const src = std.Io.Dir.readFileAlloc(.cwd(), io, path, arena, .limited(1 << 32)) catch |err| {
        try out.print("{s}: 读取失败: {s}\n", .{ path, @errorName(err) });
        return true;
    };

    var result = try variant.scan(arena, src);

    // 决策导出：模板拆片后正则全在主流，直接过滤 .regex 即得决策集
    if (emit_regex_starts) {
        for (result.tokens) |t| {
            if (t.kind == .regex) try out.print("{d}\n", .{t.start});
        }
        return false;
    }

    if (dump) {
        // TSV：start \t end \t kind \t 转义后的文本（\n 等控制字符转成 \x 序列）\t 行号
        // lexeme 不存 end：取下一个 lexeme 的 start（连续性不变量；eof 取 src.len）
        for (result.tokens, 0..) |t, i| {
            const end: u32 = if (i + 1 < result.tokens.len) result.tokens[i + 1].start else @intCast(src.len);
            try out.print("{d}\t{d}\t{s}\t", .{ t.start, end, @tagName(t.kind) });
            try writeEscaped(out, t.slice(src, end));
            try out.print("\t{d}\n", .{try result.lines.lineAt(t.start)});
        }
    }

    // kind 分布摘要（跳过计数为 0 的类别）
    var counts: [@typeInfo(my_scanner.LexemeKind).@"enum".fields.len]usize = @splat(0);
    for (result.tokens) |t| counts[@intFromEnum(t.kind)] += 1;

    try out.print("{s}: {d} bytes, {d} lexemes, {d} lines (", .{
        path, src.len, result.tokens.len, try result.lineCount(),
    });
    const fields = @typeInfo(my_scanner.LexemeKind).@"enum".fields;
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
        var tokens: std.ArrayList(my_scanner.Lexeme) = .empty;
        defer tokens.deinit(arena);
        var best: i96 = std.math.maxInt(i96);
        var total: i96 = 0;
        for (0..bench) |_| {
            const t0 = Io.Timestamp.now(io, .awake);
            _ = try variant.scanInto(&tokens, arena, src);
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
