const std = @import("std");
const V16 = @Vector(16, u8);
pub fn tTbl2(table: V16, idx: V16) V16 {
    return asm ("tbl $0.16b, {{$1.16b}}, $2.16b"
        : [ret] "=w" (-> V16),
        : [tab] "w" (table),
          [idx] "w" (idx),
    );
}
export fn useB(a: V16, b: V16) V16 {
    return tTbl2(a, b);
}
