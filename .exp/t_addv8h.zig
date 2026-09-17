const std = @import("std");
pub fn f_addv8h(a: V16) V16 { return asm ("addv b$0, $1.8h" : [ret] "=x" (-> V16), : [x] "w" (a)); }
export fn e_addv8h(a: V16) V16 { return f_addv8h(a); }
