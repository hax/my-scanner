//! 单阶段变体的公共层：标量空白跳过。
//!
//! 行号不在此层维护——全变体的行索引统一走惰性 LineIndex（扫描期零
//! 行跟踪成本，首次查询时由 simd.classifyLineBreaks 物化；两阶段引擎
//! 则用 classify 副产品预填）。历史上这里做过「跳跃区间逐 span 补计
//! 换行」并计入 scanInto 计时，其依据（yuku 逐字符判换行、殊途同归）
//! 经源码核查不成立——yuku 扫描期只交付 1-bit flag，行号是下游按需
//! 重算；详见 docs/class-code-and-simd-lookup.md 单阶段一节。

const std = @import("std");
const simd = @import("../simd.zig");

/// 空白 run 扫描结果：end 是 run 终点；saw_lf 表示 run 内是否含行终止符
/// （\n、\r、U+2028、U+2029）。换行检测融合同一趟跳过，省掉二次扫描。
pub const WsRun = struct { end: usize, saw_lf: bool };

/// 跳过 pos 处开始的空白（ASCII + Unicode whitespace），返回新 pos 与
/// 换行事实。lexeme 起点在返回 pos 处（或文件尾）。
pub fn skipWhitespace(src: []const u8, pos0: usize) WsRun {
    var pos = pos0;
    var saw_lf = false;
    while (pos < src.len) {
        const c = src[pos];
        switch (c) {
            '\n', '\r' => {
                saw_lf = true;
                pos += 1;
            },
            ' ', '\t', 0x0b, 0x0c => pos += 1,
            else => {
                if (c >= 0x80) {
                    if (simd.unicodeWhitespaceLen(src, pos)) |len| {
                        // U+2028/U+2029 是行终止符（E2 80 A8/A9）
                        if (c == 0xE2 and src[pos + 1] == 0x80 and
                            (src[pos + 2] == 0xA8 or src[pos + 2] == 0xA9)) saw_lf = true;
                        pos += len;
                        continue;
                    }
                }
                return .{ .end = pos, .saw_lf = saw_lf };
            },
        }
    }
    return .{ .end = pos, .saw_lf = saw_lf };
}

test "skipWhitespace 跳过 ASCII 与 Unicode 空白" {
    const src = "  \t\n\u{00a0}\u{2028}x ";
    const run = skipWhitespace(src, 0);
    try std.testing.expectEqual(@as(usize, src.len - 2), run.end); // 停在 x
    try std.testing.expect(run.saw_lf); // \n 与 U+2028
    const tail = skipWhitespace(src, src.len - 1);
    try std.testing.expectEqual(src.len, tail.end); // 尾部空格到 EOF
    try std.testing.expect(!tail.saw_lf);
    const only_ws = skipWhitespace(" \t", 0);
    try std.testing.expect(!only_ws.saw_lf);
}
