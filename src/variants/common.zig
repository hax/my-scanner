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

/// 跳过 pos 处开始的空白（ASCII + Unicode whitespace），返回新 pos。
/// token 起点在返回 pos 处（或文件尾）。
pub fn skipWhitespace(src: []const u8, pos0: usize) usize {
    var pos = pos0;
    while (pos < src.len) {
        const c = src[pos];
        switch (c) {
            '\n', '\r', ' ', '\t', 0x0b, 0x0c => pos += 1,
            else => {
                if (c >= 0x80) {
                    if (simd.unicodeWhitespaceLen(src, pos)) |len| {
                        pos += len;
                        continue;
                    }
                }
                return pos;
            },
        }
    }
    return pos;
}

test "skipWhitespace 跳过 ASCII 与 Unicode 空白" {
    const src = "  \t\n\u{00a0}\u{2028}x ";
    try std.testing.expectEqual(@as(usize, src.len - 2), skipWhitespace(src, 0)); // 停在 x
    try std.testing.expectEqual(@as(usize, 0), skipWhitespace(src, 0) -| src.len); // 防御
    try std.testing.expectEqual(src.len, skipWhitespace(src, src.len - 1)); // 尾部空格到 EOF
}
