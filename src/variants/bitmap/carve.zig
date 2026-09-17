//! carve：字符串 / 模板 / 注释 / 正则的 opener 事件循环。

const scanner = @import("../../scanner.zig");
const lexeme_mod = @import("../../lexeme.zig");
const simd = @import("../../simd.zig");
const vec = @import("vec.zig");
const bits = @import("bits.zig");
const regex_allowed = @import("regex_allowed.zig");

const Bitmaps = bits.Bitmaps;
const Kind = bits.Kind;
const LexemeKind = lexeme_mod.LexemeKind;
const TemplateStack = scanner.TemplateStack;
const Mask = vec.Mask;
const splat = vec.splat;

/// SIMD 找下一个 `" ' \` /`（32B 窗口 movemask + ctz）
pub fn findOpener(src: []const u8, n: usize, from: usize) usize {
    var i = from;
    while (i + 32 <= n) {
        const m: Mask = @bitCast((simd.load(src, i) == splat('"')) | (simd.load(src, i) == splat('\'')) |
            (simd.load(src, i) == splat('`')) | (simd.load(src, i) == splat('/')));
        if (m != 0) {
            return i + @ctz(m);
        }
        i += 32;
    }
    while (i < n) : (i += 1) {
        const c = src[i];
        if (c == '"' or c == '\'' or c == '`' or c == '/') return i;
    }
    return n;
}

pub fn carve(bm: *Bitmaps, src: []const u8, from: usize) void {
    const n = src.len;
    // shebang 行不参与 opener 扫描（scanInto 传入行尾）：行内的 `/` 会
    // 被误判正则起点，行内未闭合反引号会吞到行外
    var tpl: TemplateStack = .{};
    var i: usize = from;
    while (true) {
        // 模板子表达式内（tpl 非空）还要找 `{`/`}`：花括号计数归零的 `}`
        // 是模板续片（middle/tail）起点，与 scanner.scanAt 同一口径。
        // 模板外短路为零额外成本（模板-free 文件走纯 opener 扫描）
        const s = if (tpl.len > 0) findTemplateStop(src, n, i) else findOpener(src, n, i);
        if (s >= n) break;
        switch (src[s]) {
            '"', '\'' => {
                const tok = scanner.scanString(src, s, src[s]);
                carveLiteral(bm, s, tok.end, fromLexeme(tok.kind));
                i = tok.end;
            },
            '`' => {
                // 模板起点：扫一个 part（head 收尾含 `${`，无子表达式整体
                // 一片）；子表达式内部由主循环按普通 lexeme 流继续扫
                const tok = scanner.scanTemplatePart(src, s);
                carveLiteral(bm, s, tok.end, fromLexeme(tok.kind));
                tpl.track(tok.kind, '`');
                i = tok.end;
            },
            '/' => {
                i = carveSlash(bm, src, s);
            },
            '{' => {
                tpl.track(.punct, '{');
                i = s + 1;
            },
            '}' => {
                if (tpl.closesTemplate()) {
                    // 子表达式收尾：`}` 起续片（middle 到 `${`，tail 到反引号）
                    const tok = scanner.scanTemplatePart(src, s);
                    carveLiteral(bm, s, tok.end, fromLexeme(tok.kind));
                    tpl.track(tok.kind, '}');
                    i = tok.end;
                } else {
                    tpl.track(.punct, '}');
                    i = s + 1;
                }
            },
            else => {
                // 不可达（finder 只停上述字节）；容错跳过
                i = s + 1;
            },
        }
    }
}

/// 模板子表达式内的停靠点：`" ' \` /` 之外加 `{` `}`（花括号计数与续片
/// 判别）。仅 tpl 非空时启用，模板-free 文件零成本。
pub fn findTemplateStop(src: []const u8, n: usize, from: usize) usize {
    var i = from;
    while (i + 32 <= n) {
        const c = simd.load(src, i);
        const m: Mask = @bitCast((c == splat('"')) | (c == splat('\'')) | (c == splat('`')) |
            (c == splat('/')) | (c == splat('{')) | (c == splat('}')));
        if (m != 0) {
            return i + @ctz(m);
        }
        i += 32;
    }
    while (i < n) : (i += 1) {
        const c = src[i];
        if (c == '"' or c == '\'' or c == '`' or c == '/' or c == '{' or c == '}') return i;
    }
    return n;
}

/// 字面量 lexeme 落位：kind[s]=kind、清 [s+1, end) 的 st
/// （oxc 的 inclusive [s+1, end-1] 等价——lexeme 内部全部摘除）。
/// kind 取内部 Kind（含 trivia 标签）；LexemeKind 值经 fromLexeme 转换。
fn carveLiteral(bm: *Bitmaps, s: usize, end: usize, kind: Kind) void {
    bm.kind[s] = @intFromEnum(kind);
    if (end > s + 1) {
        bits.bmClearRange(bm.st, s + 1, end);
    }
}

/// LexemeKind → 内部 Kind（前段同序同值，直接 reinterpret）
inline fn fromLexeme(kind: LexemeKind) Kind {
    return @enumFromInt(@intFromEnum(kind));
}

/// `/` 的三义：行注释 / 块注释 / 正则 / 除号（`/=` 自并）。
/// 注释是 trivia（不落盘）：carve 成 comment kind，compress 跳过；
/// 换行信息由 nl 位图在 compress 统一交付。返回续扫位置。
fn carveSlash(bm: *Bitmaps, src: []const u8, s: usize) usize {
    const n = src.len;
    const d: u8 = if (s + 1 < n) src[s + 1] else 0;
    if (d == '/') {
        const end = scanner.lineEnd(src, s);
        carveLiteral(bm, s, end, .comment);
        return end;
    }
    if (d == '*') {
        if (simd.findBlockCommentEnd(src, s + 2)) |e| {
            carveLiteral(bm, s, e.end, .comment);
            return e.end;
        }
        // 未闭合块注释：吞掉余下全部，illegal 落盘（错误可见，容错不中断）
        carveLiteral(bm, s, n, .illegal);
        return n;
    }
    if (regex_allowed.regexAllowedBitmap(bm, src, s)) {
        const tok = scanner.scanRegex(src, s);
        carveLiteral(bm, s, tok.end, fromLexeme(tok.kind));
        return tok.end;
    }
    if (d == '=') {
        // `/=`：自并成单 punct lexeme（对齐 scanPunct 贪心）
        bits.bmClear(bm.st, s + 1);
        bits.bmClear(bm.opch, s + 1);
        return s + 2;
    }
    return s + 1;
}
