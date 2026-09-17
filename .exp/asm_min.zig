const std = @import("std");
const V16 = @Vector(16, u8);

pub fn movOnly(x: V16) V16 {
    return asm ("mov $0.16b, $1.16b"
        : [ret] "=w" (-> V16),
        : [a] "w" (x),
    );
}
pub fn tblNoSuffix(table: V16, idx: V16) V16 {
    return asm ("tbl $0.16b, { $1 }, $2"
        : [ret] "=w" (-> V16),
        : [tab] "w" (table),
          [idx] "w" (idx),
    );
}
export fn useMov(x: V16) V16 { return movOnly(x); }
export fn useTbl(t: V16, i: V16) V16 { return tblNoSuffix(t, i); }
