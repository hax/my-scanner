const std = @import("std");
const V16 = @Vector(16, u8);
pub fn f_add(a: V16, b: V16) V16 {
    return asm ("add $0.16b, $1.16b, $2.16b"
        : [ret] "=w" (-> V16),
        : [x] "w" (a),
          [y] "w" (b),
    );
}
export fn e_add(a: V16, b: V16) V16 {
    return f_add(a, b);
}
