pub fn f_gpr(a: u64, b: u64) u64 {
    return asm ("add $0, $1, $2"
        : [ret] "=r" (-> u64),
        : [x] "r" (a),
          [y] "r" (b),
    );
}
export fn e_gpr(a: u64, b: u64) u64 {
    return f_gpr(a, b);
}
