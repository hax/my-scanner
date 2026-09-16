const std = @import("std");
const Io = std.Io;
const my_scanner = @import("my_scanner");
pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    _ = init.minimal;
    const src = "#!/usr/bin/env node\nconsole.log('hi');";
    var tokens: std.ArrayList(my_scanner.Token) = .empty;
    defer tokens.deinit(arena);
    try my_scanner.Variant.bitmap.scanInto(&tokens, arena, src, .{});
    var want = try my_scanner.scanner.scan(arena, src, .{});
    defer want.deinit(arena);
    std.debug.print("got={d} want={d}\n", .{ tokens.items.len, want.tokens.len });
    for (want.tokens, tokens.items[0..@min(want.tokens.len, tokens.items.len)]) |w, g| {
        const mark = if (w.kind != g.kind or w.start != g.start or w.end != g.end) " <<<" else "";
        std.debug.print("  want {s} [{d},{d}) got {s} [{d},{d}){s}\n", .{ @tagName(w.kind), w.start, w.end, @tagName(g.kind), g.start, g.end, mark });
    }
}
