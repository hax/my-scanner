// 实验：Zig inline asm 封装 NEON 指令（vqtbl / pmull movemask）
const std = @import("std");
const V16 = @Vector(16, u8);

/// vqtbl1q：16B 表内动态查表（pshufb 的 NEON 等价物）
pub inline fn tbl1(table: V16, idx: V16) V16 {
    return asm ("tbl $0.16b, { $1.16b }, $2.16b"
        : [ret] "=w" (-> V16),
        : [tab] "w" (table),
          [idx] "w" (idx),
    );
}

/// vqtbl4q：4×16B = 64 项表查表（oxc compress 的 pair_luts 需要）
pub inline fn tbl4(t0: V16, t1: V16, t2: V16, t3: V16, idx: V16) V16 {
    return asm (
        \\tbl $0.16b, { $1.16b, $2.16b, $3.16b, $4.16b }, $5.16b
        : [ret] "=w" (-> V16),
        : [a] "w" (t0),
          [b] "w" (t1),
          [c] "w" (t2),
          [d] "w" (t3),
          [i] "w" (idx),
    );
}

/// pmull movemask：16B 掩码（0x00/0x80）→ 16 位
/// 字节 i 的最高位 → 结果位 i。两次 pmull.8b 折叠高低 8 字节。
pub inline fn movemaskPmull(v: V16) u16 {
    // 权重：字节 i 系数 2^i（0x01,0x02,...,0x80）
    const W: V16 = .{ 1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128 };
    const lo: u64 = asm ("pmull $0.8b, $1.8b, $2.8b"
        : [ret] "=w" (-> u64),
        : [a] "w" (v),
          [w] "w" (W),
    );
    const hi: u64 = asm ("pmull2 $0.8b, $1.16b, $2.16b"
        : [ret] "=w" (-> u64),
        : [a] "w" (v),
          [w] "w" (W),
    );
    // pmull.8b 是无进位乘：每字节 = 各位与权重的 AND 折叠到 64 位结果？
    // 不对——pmull.8b 逐字节多项式乘，8 字节结果在低 64 位。
    // 正确用法：把 v 拆成 0x01/0x00（>>7），与权重 0x01,0x02,... 做 pmull
    // 需要不同构造。此实现先测 tbl，pmull 后置。
    _ = lo;
    _ = hi;
    return 0;
}

test "tbl1 基本正确性" {
    const table: V16 = .{ 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25 };
    const idx: V16 = .{ 0, 1, 2, 3, 15, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 };
    const r = tbl1(table, idx);
    try std.testing.expectEqual(@as(u8, 10), r[0]);
    try std.testing.expectEqual(@as(u8, 11), r[1]);
    try std.testing.expectEqual(@as(u8, 25), r[4]);
}

test "tbl4 64 项表" {
    const t0: V16 = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    const t1: V16 = @splat(16);
    const t2: V16 = @splat(32);
    const t3: V16 = @splat(48);
    const idx: V16 = .{ 0, 15, 16, 31, 32, 48, 63, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    const r = tbl4(t0, t1, t2, t3, idx);
    try std.testing.expectEqual(@as(u8, 0), r[0]);
    try std.testing.expectEqual(@as(u8, 15), r[1]);
    try std.testing.expectEqual(@as(u8, 16), r[2]);
    try std.testing.expectEqual(@as(u8, 63), r[6]);
}
