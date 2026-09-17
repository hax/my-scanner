//! misc pass：unicode（空白拆位 / ID_Start 保留 / illegal 拆位）、`\`。

const std = @import("std");
const simd = @import("../../simd.zig");
const unicode = @import("../../unicode.zig");
const scanner = @import("../../scanner.zig");
const bits = @import("bits.zig");

const Bitmaps = bits.Bitmaps;
const Kind = bits.Kind;

pub fn miscPass(bm: *Bitmaps, src: []const u8) void {
    const n = src.len;
    var i: usize = 0;
    while (bits.bmNext1(bm.misc, i, n)) |j| {
        i = j + 1;
        const c = src[j];
        if (c >= 0x80) {
            i = j + miscUnicode(bm, src, j);
            continue;
        } else if (c == '\\') {
            miscBackslash(bm, src, j);
        }
        // `#`：恒单字节 punct（新口径），位图已就位，无需处理
    }
}

/// 非 ASCII 字节 j（对齐 scanNonAscii 语义）；返回应跳过的字节数
/// （整码点——续字节也在 misc 位图里，不跳会被单独误判）
fn miscUnicode(bm: *Bitmaps, src: []const u8, j: usize) usize {
    const n = src.len;
    // unicode 空白（含 U+2028/29）：从 word 摘出、标 trivia kind、补断点 st；
    // U+2028/29 是行终止符（trivia 不落盘，newline_before flag 靠 nl 位图）
    if (simd.unicodeWhitespaceLen(src, j)) |len| {
        if (scanner.wsIsLineTerminator(src, j)) bits.bmSet(bm.nl, j);
        setTriviaRange(bm, j, @min(j + len, n));
        return len;
    }
    const lead = src[j];
    const len = std.unicode.utf8ByteSequenceLength(lead) catch {
        // 非 UTF-8 起始字节：单字节 illegal
        setIllegalRange(bm, j, 1);
        return 1;
    };
    // CJK 快路径：0xE4..0xE9 开头的 3 字节码点全部位于 CJK 统一表意文字
    // 区（U+4E00..U+9FFF，ID_Start）——真实中文标识符的绝大多数，免 decode。
    // 对齐 decode 的合法性前提：续字节须是 0x80..0xBF（坏输入仍 decode 判）
    if (len == 3 and lead >= 0xE4 and lead <= 0xE9 and
        j + 2 < src.len and src[j + 1] >= 0x80 and src[j + 1] < 0xC0 and src[j + 2] >= 0x80 and src[j + 2] < 0xC0)
    {
        return 3;
    }
    const r = unicode.decode(src, j) orelse {
        // 坏 UTF-8：按首字节的标称宽度整段消费成 illegal（对齐
        // scanNonAscii 的 utf8Len 吞段）
        setIllegalRange(bm, j, 1);
        return 1;
    };
    if (unicode.isIdStart(r.cp)) {
        // 标识符码点：word 保留（kind 已是 identifier），跳过码点续字节
        return r.len;
    }
    // 非 ID_Start 非 ws 的非 ASCII：按码点消费成**一个** illegal lexeme
    //（对齐 scanNonAscii：首字节 st，续字节只清 word+kind）
    setIllegalRange(bm, j, r.len);
    return r.len;
}

/// 把 [j, e) 从 word run 摘成 trivia：清 word、kind=whitespace、
/// 首字节补 st（ws run 首）、尾后字节若是 word 补 st（新 run 首）
fn setTriviaRange(bm: *Bitmaps, j: usize, e: usize) void {
    var k = j;
    while (k < e) : (k += 1) {
        bits.bmClear(bm.word, k);
        bm.kind[k] = @intFromEnum(Kind.whitespace);
    }
    bits.bmSet(bm.st, j);
    // 尾后接 word 时需要新 run 首 st：classify 时它前一字节 word=1 无 st
    if (e < bm.n and bits.bmGet(bm.word, e)) {
        bits.bmSet(bm.st, e);
    }
}

/// [j, j+len) 消费成**一个** illegal lexeme（对齐 scanNonAscii 的整段
/// 吞法）：首字节 st+kind=illegal，续字节只清 word+kind（st 本就 0），
/// 尾后 word 补 run 首 st
fn setIllegalRange(bm: *Bitmaps, j: usize, len: usize) void {
    const e = @min(j + len, bm.n);
    var k = j;
    while (k < e) : (k += 1) {
        bits.bmClear(bm.word, k);
        bm.kind[k] = @intFromEnum(Kind.illegal);
    }
    bits.bmSet(bm.st, j);
    if (e < bm.n and bits.bmGet(bm.word, e)) {
        bits.bmSet(bm.st, e);
    }
}

/// `\`：对齐 tokenAt 的转义标识符分支 + scanIdentifier 的词中转义合并。
/// `\uXXXX` decode 失败或码点不合格：单字节 illegal（classify 已就位，
/// 无需动）。合法转义分三种位置：
/// - 词外（前字节非 word）：是 ID_Start 才是独立 identifier 起点；
/// - 词中（前字节 word）：只有「首字符之后无 ASCII 快路径字符介入」时
///   才并入前词——scanIdentifier 的循环先判 `\`，但 ASCII 字符走
///   asciiIdentEnd 快路径停在 `\` 即断词（`a\u0042c` 并、`if\u0041` /
///   `ab\u0042c` 断、`a中\u0042` 并、`中a\u0042` 断）；并入条件即
///   [run_start+1, j) 全是非 ASCII 字节（unicode 码点的续字节天然满足），
///   并入时转义须是 ID_Continue，从词首重放 scanIdentifier；
/// - 词首是数字的 word run（数字与词共享 word 位图）：`3\u…` 的数字已被
///   scanNumber 切断，转义按词外处理（对齐 tokenAt 的候选起点判别）。
fn miscBackslash(bm: *Bitmaps, src: []const u8, j: usize) void {
    const r = scanner.decodeIdentEscape(src, j) orelse return;
    if (j > 0 and bits.bmGet(bm.word, j - 1)) {
        var start = j;
        while (start > 0 and bits.bmGet(bm.word, start - 1)) start -= 1;
        if (simd.isDigit(src[start])) {
            if (!scanner.isIdentStartRune(r.cp)) return;
            mergeIdent(bm, src, j);
            return;
        }
        var k = start + 1;
        var merges = true;
        while (k < j) : (k += 1) {
            if (src[k] < 0x80) {
                merges = false;
                break;
            }
        }
        if (merges) {
            if (!scanner.isIdentPartRune(r.cp)) return;
            mergeIdent(bm, src, start);
        } else {
            // 词在 `\` 前已断（asciiIdentEnd 快路径），转义是新词起点
            if (!scanner.isIdentStartRune(r.cp)) return;
            mergeIdent(bm, src, j);
        }
        return;
    }
    if (!scanner.isIdentStartRune(r.cp)) return;
    mergeIdent(bm, src, j);
}

/// scanIdentifier 从 start 重放：清 [start+1, end) 的内部 st、kind[start]
/// 置 identifier（start 处的 st 保留——它就是词首）。
fn mergeIdent(bm: *Bitmaps, src: []const u8, start: usize) void {
    const body = scanner.scanIdentifier(src, start);
    if (body.end > start + 1) {
        bits.bmClearRange(bm.st, start + 1, body.end);
    }
    bm.kind[start] = @intFromEnum(Kind.identifier);
}
