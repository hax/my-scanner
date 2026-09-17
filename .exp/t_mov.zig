const std = @import("std");
const V16 = @Vector(16, u8);
pub fn f_mov(x: V16) V16 {
    return asm ("mov $0.16b, $1.16b"
        : [ret] "=w" (-> V16),
        : [a] "w" (x),
    );
}
export fn e_mov(x: V16) V16 {
    return f_mov(x);
}
