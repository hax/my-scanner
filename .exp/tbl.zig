// 实验：Zig @Vector 动态查表能否被 LLVM/AArch64 合成为 vqtbl
const std = @import("std");

const V16 = @Vector(16, u8);

// 方案 A：数组索引展开（期望 LLVM 合成 tbl）
pub fn tblArray(t: V16, idx: V16) V16 {
    var r: [16]u8 = undefined;
    const ti: [16]u8 = @bitCast(t);
    const ii: [16]u8 = @bitCast(idx);
    inline for (0..16) |i| r[i] = if (ii[i] < 16) ti[ii[i]] else 0;
    return @bitCast(r);
}

// 方案 B：select 树（4 层 blend）
pub fn tblSelect(t: V16, idx: V16) V16 {
    const idx_and: V16 = idx & @as(V16, @splat(0x0f));
    const in_range = (idx & @as(V16, @splat(0xf0))) == @as(V16, @splat(0));
    // 逐层：按 bit3/2/1/0 选半表
    const b3: V16 = @select(u8, (idx_and & @as(V16, @splat(8))) != @as(V16, @splat(0)), @shuffle(u8, t, undefined, @as([16]i32, .{8,9,10,11,12,13,14,15,8,9,10,11,12,13,14,15})), @shuffle(u8, t, undefined, @as([16]i32, .{0,1,2,3,4,5,6,7,0,1,2,3,4,5,6,7})));
    const b2: V16 = @select(u8, (idx_and & @as(V16, @splat(4))) != @as(V16, @splat(0)), @shuffle(u8, b3, undefined, @as([16]i32, .{4,5,6,7,4,5,6,7,12,13,14,15,12,13,14,15})), @shuffle(u8, b3, undefined, @as([16]i32, .{0,1,2,3,0,1,2,3,8,9,10,11,8,9,10,11})));
    const b1: V16 = @select(u8, (idx_and & @as(V16, @splat(2))) != @as(V16, @splat(0)), @shuffle(u8, b2, undefined, @as([16]i32, .{2,3,2,3,10,11,10,11,2,3,2,3,10,11,10,11})), @shuffle(u8, b2, undefined, @as([16]i32, .{0,1,0,1,8,9,8,9,0,1,0,1,8,9,8,9})));
    const b0: V16 = @select(u8, (idx_and & @as(V16, @splat(1))) != @as(V16, @splat(0)), @shuffle(u8, b1, undefined, @as([16]i32, .{1,1,9,9,1,1,9,9,1,1,9,9,1,1,9,9})), @shuffle(u8, b1, undefined, @as([16]i32, .{0,0,8,8,0,0,8,8,0,0,8,8,0,0,8,8})));
    return @select(u8, in_range, b0, @as(V16, @splat(0)));
}

// movemask 方案 C：vand 权重 + @reduce
pub fn movemaskReduce(v: V16) u16 {
    const w: V16 = @bitCast(@as(u128, 0x0008_0004_0002_0001_0008_0004_0002_0001));
    const m = v & w;
    const lo: @Vector(8, u8) = @shuffle(u8, m, undefined, @as([8]i32, .{ 0, 1, 2, 3, 4, 5, 6, 7 }));
    const hi: @Vector(8, u8) = @shuffle(u8, m, undefined, @as([8]i32, .{ 8, 9, 10, 11, 12, 13, 14, 15 }));
    const l: u8 = @reduce(.Add, lo);
    const h: u8 = @reduce(.Add, hi);
    return @as(u16, l) | (@as(u16, h) << 8);
}

// movemask 方案 D：bitcast u128 + SWAR 乘法（GPR）
pub fn movemaskSwar(v: V16) u16 {
    const x: u128 = @bitCast(v);
    const lo: u64 = @truncate(x);
    const hi: u64 = @truncate(x >> 64);
    const magic: u64 = 0x0102_0408_1020_4080;
    const l = ((lo & 0x0101_0101_0101_0101) *% magic) >> 56;
    const h = ((hi & 0x0101_0101_0101_0101) *% magic) >> 56;
    return @as(u16, @intCast(l)) | (@as(u16, @intCast(h)) << 8);
}

export fn useTblArray(t: V16, i: V16) V16 { return tblArray(t, i); }
export fn useTblSelect(t: V16, i: V16) V16 { return tblSelect(t, i); }
export fn useMaskReduce(v: V16) u16 { return movemaskReduce(v); }
export fn useMaskSwar(v: V16) u16 { return movemaskSwar(v); }
