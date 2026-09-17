const std = @import("std");
const V16 = @Vector(16, u8);

// A: 基线 add（纯 NEON，无花括号）
pub fn tAdd(a: V16, b: V16) V16 {
    return asm ("add $0.16b, $1.16b, $2.16b"
        : [ret] "=w" (-> V16),
        : [x] "w" (a),
          [y] "w" (b),
    );
}
// B: tbl 双花括号转义
pub fn tTbl2(table: V16, idx: V16) V16 {
    return asm ("tbl $0.16b, {{$1.16b}}, $2.16b"
        : [ret] "=w" (-> V16),
        : [tab] "w" (table),
          [idx] "w" (idx),
    );
}
// C: tbl 无花括号（非法语法，对照）
pub fn tTbl3(table: V16, idx: V16) V16 {
    return asm ("tbl $0.16b, $1.16b, $2.16b"
        : [ret] "=w" (-> V16),
        : [tab] "w" (table),
          [idx] "w" (idx),
    );
}
// D: pmull 显式 crypto
pub fn tPmull(a: @Vector(2, u64), b: @Vector(2, u64)) @Vector(2, u64) {
    return asm ("pmull $0.1d, $1.1d, $2.1d"
        : [ret] "=w" (-> @Vector(2, u64)),
        : [x] "w" (a),
          [y] "w" (b),
    );
}
export fn useA(a: V16, b: V16) V16 { return tAdd(a, b); }
export fn useB(a: V16, b: V16) V16 { return tTbl2(a, b); }
export fn useC(a: V16, b: V16) V16 { return tTbl3(a, b); }
export fn useD(a: @Vector(2, u64), b: @Vector(2, u64)) @Vector(2, u64) { return tPmull(a, b); }
