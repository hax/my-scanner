//! ASCII 空白 run 扫描（单阶段驱动的空白跳跃原语）：短 run 逐字节展开、
//! 长 run SIMD 块扫，换行检测融合同一趟（省掉对 run 的二次扫描）；
//! SIMD 块命中 run 终点时换行位只计 ws 前缀，尾随的非空白不污染 saw_lf。

const std = @import("std");
const simd = @import("../../simd.zig");

inline fn isAsciiWs(c: u8) bool {
    return c == ' ' or (c >= 0x09 and c <= 0x0D);
}

/// ASCII 空白 run 扫描结果：end 是 run 终点；saw_lf 表示 run 内是否含
/// 行终止符（\n、\r；U+2028/29 不走此路径——它们在主循环经 ws 标记
/// 单独判定，见 scanner.wsIsLineTerminator）。
pub const WsRun = struct { end: usize, saw_lf: bool };

/// ASCII 空白 run 的结尾（from 处可以是任意字节，按实际跳过）。
/// 短 run 逐字节展开（格式化代码的空白多为 0-2 字节：紧跟 lexeme、
/// 单空格或换行+缩进），长 run 转 SIMD 块扫。
pub fn skipWhitespace(src: []const u8, from: usize) WsRun {
    var i = from;
    var saw_lf = false;
    inline for (0..4) |_| {
        if (i >= src.len or !isAsciiWs(src[i])) return .{ .end = i, .saw_lf = saw_lf };
        saw_lf = saw_lf or (src[i] == '\n' or src[i] == '\r');
        i += 1;
    }
    while (i < src.len) {
        if (src.len - i >= simd.block_size) {
            const chunk = simd.load(src, i);
            const inv = ~simd.whitespaceMask(chunk);
            const term = simd.newlineMask(chunk) |
                @as(simd.Mask, @bitCast(chunk == @as(simd.Chunk, @splat('\r'))));
            if (inv == 0) {
                saw_lf = saw_lf or (term != 0);
                i += simd.block_size;
                continue;
            }
            const stop: u5 = @intCast(@ctz(inv));
            const ws_prefix = (@as(simd.Mask, 1) << stop) - 1;
            saw_lf = saw_lf or ((term & ws_prefix) != 0);
            i += stop;
            break;
        }
        if (isAsciiWs(src[i])) {
            saw_lf = saw_lf or (src[i] == '\n' or src[i] == '\r');
            i += 1;
        } else break;
    }
    return .{ .end = i, .saw_lf = saw_lf };
}
