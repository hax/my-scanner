const std = @import("std");
const V16 = @Vector(16, u8);

// pmull movemask：输入 0x80/0x00 字节掩码，输出 16 位（字节 i 高位 → 位 i）
// 原理：pmull.8b(v_lo, W) 是逐字节**无进位**乘——不对，pmull.8b 是 8 个
// 独立的 8x8→16 多项式乘，不能跨字节折叠。经典技巧用 pmull.1d（64x64→128
// 无进位乘）：把 8 字节的 mask 位（每字节 0x80）当作 64 位多项式系数，
// 乘以 {0x80,0x40,...,0x01} 的折叠——即 V8 实现的 _mm_movemask_epi8。
pub inline fn movemaskPmull(v: V16) u16 {
    const v2: @Vector(2, u64) = @bitCast(v);
    const magic2: @Vector(2, u64) = @splat(0x8040_2010_0804_0201);
    const lo_in: @Vector(2, u64) = .{ v2[0], 0 };
    const hi_in: @Vector(2, u64) = .{ v2[1], 0 };
    const lo: @Vector(2, u64) = asm ("pmull $0.1d, $1.1d, $2.1d"
        : [ret] "=w" (-> @Vector(2, u64)),
        : [a] "w" (lo_in),
          [b] "w" (magic2),
    );
    const hi: @Vector(2, u64) = asm ("pmull $0.1d, $1.1d, $2.1d"
        : [ret] "=w" (-> @Vector(2, u64)),
        : [a] "w" (hi_in),
          [b] "w" (magic2),
    );
    const lobits: u8 = @truncate(lo[1] >> 56);
    const hibits: u8 = @truncate(hi[1] >> 56);
    return @as(u16, lobits) | (@as(u16, hibits) << 8);
}

export fn useMask(v: V16) u16 { return movemaskPmull(v); }

// 花括号转义尝试
pub fn tblEscape1(table: V16, idx: V16) V16 {
    return asm ("tbl $0.16b, {{$1.16b}}, $2.16b"
        : [ret] "=w" (-> V16),
        : [tab] "w" (table),
          [idx] "w" (idx),
    );
}
