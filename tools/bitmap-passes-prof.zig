const std = @import("std");
const Io = std.Io;
const my_scanner = @import("my_scanner");
const bitmap = my_scanner.variants.bitmap; // 分 pass 计时 harness（zig build-exe 手动构建，见 docs/oxc-bitmap-neon-experiment.md）

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return error.NeedFile;
    const src = try std.Io.Dir.readFileAlloc(.cwd(), io, args[1], arena, .limited(1 << 32));

    const repeats: usize = 30;
    var acc = Passes{};

    for (0..repeats) |_| {
        const t0 = Io.Timestamp.now(io, .awake);
        var bm = try bitmap.Bitmaps.alloc(arena, src.len);
        const c0 = Io.Timestamp.now(io, .awake);
        bitmap.classify(&bm, src);
        const c1 = Io.Timestamp.now(io, .awake);
        bitmap.miscPass(&bm, src);
        const c2 = Io.Timestamp.now(io, .awake);
        try bitmap.carve(&bm, src, .{}, 0);
        const c3 = Io.Timestamp.now(io, .awake);
        bitmap.coalesce(&bm, src);
        bitmap.keywords(&bm, src);
        const c4 = Io.Timestamp.now(io, .awake);
        var tokens: std.ArrayList(my_scanner.Token) = .empty;
        defer tokens.deinit(arena);
        try bitmap.compress(&bm, &tokens, arena, .{});
        const c5 = Io.Timestamp.now(io, .awake);
        acc.classify += c0.durationTo(c1).nanoseconds;
        acc.misc += c1.durationTo(c2).nanoseconds;
        acc.carve += c2.durationTo(c3).nanoseconds;
        acc.coalesce += c3.durationTo(c4).nanoseconds;
        acc.compress += c4.durationTo(c5).nanoseconds;
        acc.total += t0.durationTo(c5).nanoseconds;
        const tot = t0.durationTo(c5).nanoseconds;
        if (tot < acc.best) acc.best = tot;
        bm.deinit(arena);
    }
    acc.report(args[1], src.len, repeats);
}

const Passes = struct {
    classify: i96 = 0,
    misc: i96 = 0,
    carve: i96 = 0,
    coalesce: i96 = 0,
    compress: i96 = 0,
    total: i96 = 0,
    best: i96 = std.math.maxInt(i96),

    fn report(self: *const Passes, name: []const u8, bytes: usize, repeats: usize) void {
        const f = struct {
            fn ms(x: i96) f64 {
                return @as(f64, @floatFromInt(x)) / 1e6;
            }
            fn gbps(x: i96, b: anytype) f64 {
                return @as(f64, @floatFromInt(b)) / @as(f64, @floatFromInt(@divTrunc(x, 1)));
            }
            fn pct(x: i96, t: i96) f64 {
                return @as(f64, @floatFromInt(x)) * 100.0 / @as(f64, @floatFromInt(t));
            }
        };
        std.debug.print("{s}: {d} bytes\n", .{ name, bytes });
        std.debug.print("  classify {d:>7.2} ms  {d:>5.2} GB/s  ({d:>4.1}%)\n", .{ f.ms(@divTrunc(self.classify, repeats)), f.gbps(@divTrunc(self.classify, repeats), bytes), f.pct(self.classify, self.total) });
        std.debug.print("  misc     {d:>7.2} ms            ({d:>4.1}%)\n", .{ f.ms(@divTrunc(self.misc, repeats)), f.pct(self.misc, self.total) });
        std.debug.print("  carve    {d:>7.2} ms            ({d:>4.1}%)\n", .{ f.ms(@divTrunc(self.carve, repeats)), f.pct(self.carve, self.total) });
        std.debug.print("  coalesce {d:>7.2} ms            ({d:>4.1}%)\n", .{ f.ms(@divTrunc(self.coalesce, repeats)), f.pct(self.coalesce, self.total) });
        std.debug.print("  compress {d:>7.2} ms            ({d:>4.1}%)\n", .{ f.ms(@divTrunc(self.compress, repeats)), f.pct(self.compress, self.total) });
        std.debug.print("  total    {d:>7.2} ms  {d:>5.2} GB/s   best {d:.2} GB/s\n", .{ f.ms(@divTrunc(self.total, repeats)), f.gbps(@divTrunc(self.total, repeats), bytes), f.gbps(self.best, bytes) });
    }
};
