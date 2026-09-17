const std = @import("std");
pub fn f_pmull1d(a: @Vector(2, u64), b: @Vector(2, u64)) @Vector(2, u64) { return asm ("pmull $0.1d, $1.1d, $2.1d" : [ret] "=w" (-> @Vector(2, u64)), : [x] "w" (a), [y] "w" (b)); }
export fn e_pmull1d(a: @Vector(2, u64), b: @Vector(2, u64)) @Vector(2, u64) { return f_pmull1d(a, b); }
