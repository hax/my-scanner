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
