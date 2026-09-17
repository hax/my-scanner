const std = @import("std");
pub fn f_uzp1(a: V16, b: V16) V16 { return asm ("uzp1 $0.16b, $1.16b, $2.16b" : [ret] "=w" (-> V16), : [x] "w" (a), [y] "w" (b)); }
export fn e_uzp1(a: V16, b: V16) V16 { return f_uzp1(a, b); }
