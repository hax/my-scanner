const std = @import("std");
pub fn f_pmull8b(a: V16, b: V16) V16 { return asm ("pmull $0.8b, $1.8b, $2.8b" : [ret] "=w" (-> V16), : [x] "w" (a), [y] "w" (b)); }
export fn e_pmull8b(a: V16, b: V16) V16 { return f_pmull8b(a, b); }
