const std = @import("std");
const V16 = @Vector(16, u8);

pub fn f_add(a: V16, b: V16) V16 {
    return asm ("add %[ret].16b, %[x].16b, %[y].16b"
        : [ret] "=w" (-> V16),
        : [x] "w" (a),
          [y] "w" (b),
    );
}
pub fn f_tbl(table: V16, idx: V16) V16 {
    return asm ("tbl %[ret].16b, { %[tab].16b }, %[idx].16b"
        : [ret] "=w" (-> V16),
        : [tab] "w" (table),
          [idx] "w" (idx),
    );
}
pub fn f_pmull(a: @Vector(2, u64), b: @Vector(2, u64)) @Vector(2, u64) {
    return asm ("pmull %[ret].1d, %[x].1d, %[y].1d"
        : [ret] "=w" (-> @Vector(2, u64)),
        : [x] "w" (a),
          [y] "w" (b),
    );
}
pub fn f_movemask(v: V16) u16 {
    // CLMUL movemask（V8 版 _mm_movemask_epi8）
    const v2: @Vector(2, u64) = @bitCast(v);
    const magic: @Vector(2, u64) = @splat(0x8040_2010_0804_0201);
    const lo_in: @Vector(2, u64) = .{ v2[0], 0 };
    const hi_in: @Vector(2, u64) = .{ v2[1], 0 };
    const lo: @Vector(2, u64) = asm ("pmull %[ret].1d, %[a].1d, %[b].1d"
        : [ret] "=w" (-> @Vector(2, u64)),
        : [a] "w" (lo_in),
          [b] "w" (magic),
    );
    const hi: @Vector(2, u64) = asm ("pmull %[ret].1d, %[a].1d, %[b].1d"
        : [ret] "=w" (-> @Vector(2, u64)),
        : [a] "w" (hi_in),
          [b] "w" (magic),
    );
    return @as(u16, @truncate(lo[1] >> 56)) | @as(u16, @truncate(hi[1] >> 56)) << 8;
}
test "add" {
    const r = f_add(@splat(1), @splat(2));
    try std.testing.expectEqual(@as(u8, 3), r[0]);
}
test "tbl" {
    const table: V16 = .{ 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25 };
    const idx: V16 = .{ 0, 1, 15, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 2 };
    const r = f_tbl(table, idx);
    try std.testing.expectEqual(@as(u8, 10), r[0]);
    try std.testing.expectEqual(@as(u8, 25), r[2]);
}
test "movemask" {
    var v: V16 = @splat(0);
    v[0] = 0x80;
    v[7] = 0x80;
    v[15] = 0x80;
    const m = f_movemask(v);
    try std.testing.expectEqual(@as(u16, 0b1000_0001_1000_0000), m);
}
