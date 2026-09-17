const std = @import("std");
const V16 = @Vector(16, u8);
// pmull .8b 形式
pub fn tPmull8b(a: V16, b: V16) V16 {
    return asm ("pmull $0.8b, $1.8b, $2.8b"
        : [ret] "=w" (-> V16),
        : [x] "w" (a),
          [y] "w" (b),
    );
}
// uzp1（无花括号的 NEON 指令，movemask 链一部分）
pub fn tUzp(a: V16, b: V16) V16 {
    return asm ("uzp1 $0.16b, $1.16b, $2.16b"
        : [ret] "=w" (-> V16),
        : [x] "w" (a),
          [y] "w" (b),
    );
}
// tbl 花括号内无空格
pub fn tTblNs(table: V16, idx: V16) V16 {
    return asm ("tbl $0.16b, {$1.16b}, $2.16b"
        : [ret] "=w" (-> V16),
        : [tab] "w" (table),
          [idx] "w" (idx),
    );
}
export fn u8b(a: V16, b: V16) V16 { return tPmull8b(a, b); }
export fn uuzp(a: V16, b: V16) V16 { return tUzp(a, b); }
export fn utns(a: V16, b: V16) V16 { return tTblNs(a, b); }
