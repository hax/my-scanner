//! 首字节分发（共享 dispatch 表，跳跃函数换标量版）：tokenAtScalar +
//! 模板收尾拦截（scanAtScalar）。

const std = @import("std");
const lexeme_mod = @import("../../lexeme.zig");
const scanner = @import("../../scanner.zig");
const simd = @import("../../simd.zig");
const jumps = @import("jumps.zig");

const LexemeKind = lexeme_mod.LexemeKind;
const TemplateStack = scanner.TemplateStack;

fn tokenAtScalar(src: []const u8, start: usize, prev_kind: ?LexemeKind, prev_text: []const u8, prev2_text: []const u8) scanner.Scan {
    const c = src[start];
    const code = scanner.dispatch_table[c];

    if (code & scanner.Dispatch.punct_single != 0) {
        return .{ .kind = .punct, .end = start + 1 };
    }
    if (code & scanner.Dispatch.ident_start != 0) return jumps.scanIdentifierScalar(src, start);
    if (code & scanner.Dispatch.digit != 0) return scanner.scanNumber(src, start);
    if (code & scanner.Dispatch.quote != 0) {
        return if (c == '`') jumps.scanTemplatePartScalar(src, start) else jumps.scanStringScalar(src, start, c);
    }
    if (code & scanner.Dispatch.slash != 0) {
        // 除号、正则两解（注释由驱动循环前置判别，不到这里）
        if (scanner.regexAllowedAfter(prev_kind, prev_text, prev2_text)) return scanner.scanRegex(src, start);
        return scanner.scanPunct(src, start);
    }
    if (c == '\\') {
        if (scanner.decodeIdentEscape(src, start)) |r| {
            if (scanner.isIdentStartRune(r.cp)) return jumps.scanIdentifierScalar(src, start);
        }
        return .{ .kind = .illegal, .end = start + 1 };
    }
    if (code & scanner.Dispatch.punct_multi != 0) {
        if (c == '.' and start + 1 < src.len and simd.isDigit(src[start + 1])) {
            return scanner.scanNumber(src, start);
        }
        return scanner.scanPunct(src, start);
    }
    return jumps.scanNonAsciiScalar(src, start);
}

/// scanner.scanAt 的标量版：tokenAtScalar + 模板收尾拦截（`}` 在花括号
/// 计数归零的帧里是模板续片起点）。
pub inline fn scanAtScalar(
    src: []const u8,
    start: usize,
    prev_kind: ?LexemeKind,
    prev_text: []const u8,
    prev2_text: []const u8,
    tpl: *TemplateStack,
) scanner.Scan {
    const s = tokenAtScalar(src, start, prev_kind, prev_text, prev2_text);
    // 栈空（不在任何模板内）时短路全部模板逻辑（同 scanner.scanAt）
    if (tpl.len > 0 and s.kind == .punct and src[start] == '}' and tpl.closesTemplate()) {
        return jumps.scanTemplatePartScalar(src, start);
    }
    return s;
}
