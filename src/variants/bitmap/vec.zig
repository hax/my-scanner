//! 本变体的共享向量小件：32B 主块类型与 16B NEON 子块类型、常量
//! splat、尾块安全加载（越界填 0x7f——不命中任何分类位图）、vqtbl1q
//! 动态查表（pshufb 的 NEON 等价，仅 aarch64 classify 路径引用）。

pub const Chunk = @import("../../simd.zig").Chunk; // @Vector(32, u8)
pub const Mask = @import("../../simd.zig").Mask; // u32

pub inline fn splat(c: u8) Chunk {
    return @splat(c);
}

pub const V16 = @Vector(16, u8);

pub inline fn splat16(c: u8) V16 {
    return @splat(c);
}

/// 16B 版尾块安全加载（越界填 0x7f）
pub inline fn loadPad16(src: []const u8, i: usize) V16 {
    if (i + 16 <= src.len) return src[i..][0..16].*;
    var buf: [16]u8 = @splat(0x7f);
    if (i < src.len) {
        const k = @min(16, src.len - i);
        @memcpy(buf[0..k], src[i..][0..k]);
    }
    return buf;
}

/// vqtbl1q：16B 表内动态查表（pshufb 的 NEON 等价）。与 pshufb 的差异：
/// 索引 ≥16 输出 0（pshufb 按 16 取模）——nibble 分解查找时索引须 & 15。
pub inline fn tbl1(table: V16, idx: V16) V16 {
    return asm ("tbl %[ret].16b, { %[tab].16b }, %[idx].16b"
        : [ret] "=w" (-> V16),
        : [tab] "w" (table),
          [idx] "w" (idx),
    );
}

/// 尾块安全加载：越界部分填 0x7f（不命中任何分类位图；st 幻影由
/// classify 的 rem mask 清除）。i > src.len 时返回全 pad。
pub inline fn loadPad(src: []const u8, i: usize) Chunk {
    if (i + 32 <= src.len) return src[i..][0..32].*;
    var buf: [32]u8 = @splat(0x7f);
    if (i < src.len) {
        const k = @min(32, src.len - i);
        @memcpy(buf[0..k], src[i..][0..k]);
    }
    return buf;
}
