//! bitmap 变体 —— oxc_lexer 式位图流水线（arm64 NEON）。
//!
//! 架构移植自 oxc 主仓孵化的 oxc_lexer 实验 crate（六趟 unfused 流水线，
//! 见 docs/oxc-bitmap-neon-experiment.md）：classify 一次 SIMD 产出块位图
//! + 每字节 kind，后续 pass 只在字面量 opener / 多字符 token 事件处回读
//! 字节，最后 compress 从位图批量搬运 token。与 oxc 版的三个关键差异：
//!
//! 1. 语义层完全复用 my-scanner（scanString/scanTemplate/scanNumber/
//!    scanPunct/scanRegex/isKeyword——tsc 差分口径），而不是 oxc 的
//!    disambiguate 自决体系；正则决策用位图版 regexAllowedAfter（见下）。
//! 2. NEON 没有 movemask/pshufb 等价单指令（Zig/LLVM 也不合成 vqtbl），
//!    位图提取走 LLVM 对 `@bitCast(bool vector → int)` 的 zip+addv
//!    lowering；分类不用 LUT 而用比较链。
//! 3. 位图从 oxc 的 7 张精简到 5 张：ws 不落盘（st 构造后即弃）、
//!    dot 并入 numch（digit|dot）、kwinit 砍掉（keyword 判定挪到
//!    coalesce 事件处调 isKeyword——成本与 jump_vec 逐 token 判定持平）。
//!
//! token 端点语义：end = 位图上下一个 st 位的位置（stage 流配对，与
//! oxc build_spans 同构；st 位图在 n 处放 sentinel 保证末 token 有配对）。
//! 恒成立的原因：任何 token 尾之后必然是下一 token 起点、trivia 起点
//! 或 EOF，而这三者都有 st 位。
//!
//! 约定：bmClearRange 是 [from, to)（zig 风格）；oxc 原文的
//! bm_clear_range 是 inclusive [from, to]，移植时调用点统一 +1。

const std = @import("std");
const scanner = @import("../scanner.zig");
const simd = @import("../simd.zig");
const token = @import("../token.zig");
const unicode = @import("../unicode.zig");

const Token = token.Token;
const TokenKind = token.TokenKind;
const Options = scanner.Options;

const Chunk = simd.Chunk; // @Vector(32, u8)
const Mask = simd.Mask; // u32

fn splat(c: u8) Chunk {
    return @splat(c);
}

// ---------------------------------------------------------------------------
// 位图容器：每 64 字节块一个 u64 word（多 1 word 给 n 处 sentinel），
// kind 每字节一个 u8（长度补齐到 64 倍数再 +64，尾块向量整存 + sentinel）
// ---------------------------------------------------------------------------

pub const Bitmaps = struct {
    word: []u64,
    st: []u64,
    opch: []u64,
    numch: []u64, // digit | dot
    misc: []u64,
    kind: []u8,
    n: usize,

    pub fn alloc(allocator: std.mem.Allocator, n: usize) !Bitmaps {
        const nb = (n + 63) / 64 + 1; // +1：sentinel 位 n 与越界读兜底 word
        const bm = Bitmaps{
            .word = try allocator.alloc(u64, nb),
            .st = try allocator.alloc(u64, nb),
            .opch = try allocator.alloc(u64, nb),
            .numch = try allocator.alloc(u64, nb),
            .misc = try allocator.alloc(u64, nb),
            .kind = try allocator.alloc(u8, nb * 64),
            .n = n,
        };
        // 位图 word [0, ceil(n/64)) 由 classify 全量写入；只有兜底 word
        // （bmNext0/bmNext1 越界读会触达）需要清零
        bm.word[nb - 1] = 0;
        bm.st[nb - 1] = 0;
        bm.opch[nb - 1] = 0;
        bm.numch[nb - 1] = 0;
        bm.misc[nb - 1] = 0;
        return bm;
    }

    pub fn deinit(self: *Bitmaps, allocator: std.mem.Allocator) void {
        allocator.free(self.word);
        allocator.free(self.st);
        allocator.free(self.opch);
        allocator.free(self.numch);
        allocator.free(self.misc);
        allocator.free(self.kind);
    }
};

/// 低 n 位全 1 掩码（n=64 → 全 1；避免 1<<64 溢出）
inline fn lowBits(n: usize) u64 {
    if (n >= 64) return ~@as(u64, 0);
    return (@as(u64, 1) << @intCast(n)) - 1;
}

inline fn bmGet(bm: []const u64, i: usize) bool {
    return (bm[i >> 6] >> @intCast(i & 63)) & 1 != 0;
}

inline fn bmSet(bm: []u64, i: usize) void {
    bm[i >> 6] |= @as(u64, 1) << @intCast(i & 63);
}

inline fn bmClear(bm: []u64, i: usize) void {
    bm[i >> 6] &= ~(@as(u64, 1) << @intCast(i & 63));
}

/// 清空 [from, to)
fn bmClearRange(bm: []u64, from: usize, to: usize) void {
    if (to <= from) return;
    const wf = from >> 6;
    const wt = (to - 1) >> 6;
    if (wf == wt) {
        const m = lowBits(to - from) << @intCast(from & 63);
        bm[wf] &= ~m;
        return;
    }
    bm[wf] &= lowBits(from & 63);
    for (bm[wf + 1 .. wt]) |*w| w.* = 0;
    bm[wt] &= ~lowBits(to - (wt << 6)); // 1..64
}

/// [from, to) 内是否有置位
fn bmAny(bm: []const u64, from: usize, to: usize) bool {
    if (to <= from) return false;
    var w = from >> 6;
    const wt = (to - 1) >> 6;
    const cur0 = bm[w] >> @intCast(from & 63);
    if (w == wt) {
        return cur0 & lowBits(to - from) != 0;
    }
    if (cur0 != 0) return true;
    w += 1;
    while (w < wt) : (w += 1) {
        if (bm[w] != 0) return true;
    }
    return bm[wt] & lowBits(to - (wt << 6)) != 0;
}

/// 下一个置位位（i 起含 i）；逻辑长度 limit（位 i < limit），找不到返回 null
fn bmNext1(bm: []const u64, i: usize, limit: usize) ?usize {
    var w = i >> 6;
    const wt = (limit + 63) >> 6;
    var cur = bm[w] >> @intCast(i & 63); // 首字先对齐到 i，ctz 是段内偏移
    var add: usize = i & 63;
    while (true) {
        if (cur != 0) {
            const pos = (w << 6) + add + @ctz(cur);
            return if (pos < limit) pos else null;
        }
        w += 1;
        if (w >= wt) return null;
        cur = bm[w];
        add = 0;
    }
}

/// 上一个置位位（< i），找不到返回 null
fn bmPrev1(bm: []const u64, i: usize) ?usize {
    if (i == 0) return null;
    var w = (i - 1) >> 6;
    // 保留 [w<<6, i) 的位；i 恰为 64 倍数时整 word（避免 1<<64 溢出）
    var cur = bm[w] & lowBits(i - (w << 6)); // 1..64
    while (true) {
        if (cur != 0) return (w << 6) + 63 - @clz(cur);
        if (w == 0) return null;
        w -= 1;
        cur = bm[w];
    }
}

/// 下一个 0 位（i 起含 i）；永不失败（容器尾部多 1 word 全 0）
fn bmNext0(bm: []const u64, i: usize) usize {
    var w = i >> 6;
    var cur = ~bm[w] >> @intCast(i & 63); // 首字对齐到 i，ctz 是段内偏移
    var add: usize = i & 63;
    while (true) {
        if (cur != 0) return (w << 6) + add + @ctz(cur);
        w += 1;
        cur = ~bm[w];
        add = 0;
    }
}

// ---------------------------------------------------------------------------
// classify：SIMD 比较链产 5 张位图 + kind 数组
// ---------------------------------------------------------------------------

inline fn wsBool(c: Chunk) @Vector(32, bool) {
    return (c == splat(' ')) | ((c >= splat(0x09)) & (c <= splat(0x0d)));
}

inline fn wordBool(c: Chunk) @Vector(32, bool) {
    const lower = (c >= splat('a')) & (c <= splat('z'));
    const upper = (c >= splat('A')) & (c <= splat('Z'));
    const digit = (c >= splat('0')) & (c <= splat('9'));
    return lower | upper | digit | (c == splat('_')) | (c == splat('$')) | (c >= splat(0x80));
}

/// 多字符标点潜在首字符（my-scanner dispatch 的 punct_multi：`=<>+-*%&|^!?.`）。
/// `/` 不在此（carve 三义处理后 `/=` 自并，普通 `/` 单字节）；`.` 在
/// （`...` 合并），事件处按 scanPunct 口径消化（`.5` 归数字）。
inline fn opchBool(c: Chunk) @Vector(32, bool) {
    var r: @Vector(32, bool) = c == splat('=');
    inline for ([_]u8{ '<', '>', '+', '-', '*', '%', '&', '|', '^', '!', '?', '.' }) |ch| {
        r |= c == splat(ch);
    }
    return r;
}

inline fn miscBool(c: Chunk) @Vector(32, bool) {
    return (c == splat('#')) | (c == splat('\\')) | (c >= splat(0x80));
}

/// 尾块安全加载：越界部分填 0x7f（不命中任何分类位图；st 幻影由
/// classify 的 rem mask 清除）。i > src.len 时返回全 pad。
inline fn loadPad(src: []const u8, i: usize) Chunk {
    if (i + 32 <= src.len) return src[i..][0..32].*;
    var buf: [32]u8 = @splat(0x7f);
    if (i < src.len) {
        const k = @min(32, src.len - i);
        @memcpy(buf[0..k], src[i..][0..k]);
    }
    return buf;
}

pub fn classify(bm: *Bitmaps, src: []const u8) void {
    const n = src.len;
    const nb = (n + 63) / 64;
    var cw: u64 = 0;
    var cs: u64 = 0;
    var b: usize = 0;
    while (b < nb) : (b += 1) {
        const base = b * 64;
        const c0 = loadPad(src, base);
        const c1 = loadPad(src, base + 32);

        const w0: Mask = @bitCast(wordBool(c0));
        const w1: Mask = @bitCast(wordBool(c1));
        const s0: Mask = @bitCast(wsBool(c0));
        const s1: Mask = @bitCast(wsBool(c1));
        const d0: Mask = @bitCast((c0 >= splat('0')) & (c0 <= splat('9')));
        const d1: Mask = @bitCast((c1 >= splat('0')) & (c1 <= splat('9')));
        const t0: Mask = @bitCast(c0 == splat('.'));
        const t1: Mask = @bitCast(c1 == splat('.'));
        const o0: Mask = @bitCast(opchBool(c0));
        const o1: Mask = @bitCast(opchBool(c1));
        const m0: Mask = @bitCast(miscBool(c0));
        const m1: Mask = @bitCast(miscBool(c1));

        const wordm = @as(u64, w1) << 32 | w0;
        const wsm = @as(u64, s1) << 32 | s0;
        bm.word[b] = wordm;
        bm.numch[b] = (@as(u64, d1) << 32 | d0) | (@as(u64, t1) << 32 | t0);
        bm.opch[b] = @as(u64, o1) << 32 | o0;
        bm.misc[b] = @as(u64, m1) << 32 | m0;

        const wprev = (wordm << 1) | cw;
        const sprev = (wsm << 1) | cs;
        cw = wordm >> 63;
        cs = wsm >> 63;
        bm.st[b] = (wsm & ~sprev) | (wordm & ~wprev) | (~wsm & ~wordm);

        bm.kind[base..][0..32].* = kindVec(c0);
        bm.kind[base + 32 ..][0..32].* = kindVec(c1);
    }
    // 尾块越读位清零（simd.load 用 0x7f pad：0x7f 非 word 非 ws 非 opch 非
    // misc → st=1，必须按 rem mask 掉，否则 compress 会产出幻影 token）
    const rem = n & 63;
    if (rem != 0) {
        const last = nb - 1;
        const m = (@as(u64, 1) << @intCast(rem)) - 1;
        bm.word[last] &= m;
        bm.st[last] &= m;
        bm.opch[last] &= m;
        bm.numch[last] &= m;
        bm.misc[last] &= m;
    }
}

/// kind 覆盖序（从底到顶）：punct → word(identifier) → digit(number) →
/// `#`(private_name) → `\`(illegal) → ws(whitespace)。
inline fn kindVec(c: Chunk) @Vector(32, u8) {
    const kp: u8 = @intFromEnum(TokenKind.punct);
    const kw: u8 = @intFromEnum(TokenKind.identifier);
    const kn: u8 = @intFromEnum(TokenKind.number);
    const kh: u8 = @intFromEnum(TokenKind.private_name);
    const ke: u8 = @intFromEnum(TokenKind.illegal);
    const ks: u8 = @intFromEnum(TokenKind.whitespace);
    const V = @Vector(32, u8);
    var k: V = @splat(kp);
    k = @select(u8, wordBool(c), @as(V, @splat(kw)), k);
    k = @select(u8, (c >= splat('0')) & (c <= splat('9')), @as(V, @splat(kn)), k);
    k = @select(u8, c == splat('#'), @as(V, @splat(kh)), k);
    k = @select(u8, c == splat('\\'), @as(V, @splat(ke)), k);
    k = @select(u8, wsBool(c), @as(V, @splat(ks)), k);
    return k;
}

// ---------------------------------------------------------------------------
// misc pass：unicode（空白拆位 / ID_Start 保留 / illegal 拆位）、`#`、`\`
// ---------------------------------------------------------------------------

pub fn miscPass(bm: *Bitmaps, src: []const u8) void {
    const n = src.len;
    var i: usize = 0;
    while (bmNext1(bm.misc, i, n)) |j| {
        i = j + 1;
        const c = src[j];
        if (c >= 0x80) {
            i = j + miscUnicode(bm, src, j);
            continue;
        } else if (c == '#') {
            miscHash(bm, src, j);
        } else if (c == '\\') {
            miscBackslash(bm, src, j);
        }
    }
}

/// 非 ASCII 字节 j（对齐 scanNonAscii 语义）；返回应跳过的字节数
/// （整码点——续字节也在 misc 位图里，不跳会被单独误判）
fn miscUnicode(bm: *Bitmaps, src: []const u8, j: usize) usize {
    const n = src.len;
    // unicode 空白（含 U+2028/29）：从 word 摘出、标 trivia kind、补断点 st
    if (simd.unicodeWhitespaceLen(src, j)) |len| {
        setTriviaRange(bm, j, @min(j + len, n));
        return len;
    }
    const lead = src[j];
    const len = std.unicode.utf8ByteSequenceLength(lead) catch {
        setIllegalByte(bm, j);
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
        // 坏 UTF-8：单字节 illegal，从 word 摘出
        setIllegalByte(bm, j);
        return 1;
    };
    if (unicode.isIdStart(r.cp)) {
        // 标识符码点：word 保留（kind 已是 identifier），跳过码点续字节
        return r.len;
    }
    // 非 ID_Start 非 ws 的非 ASCII：按码点消费成 illegal（对齐 scanNonAscii）
    const e = @min(j + r.len, n);
    var k = j;
    while (k < e) : (k += 1) {
        setIllegalByte(bm, k);
    }
    return r.len;
}

/// 把 [j, e) 从 word run 摘成 trivia：清 word、kind=whitespace、
/// 首字节补 st（ws run 首）、尾后字节若是 word 补 st（新 run 首）
fn setTriviaRange(bm: *Bitmaps, j: usize, e: usize) void {
    var k = j;
    while (k < e) : (k += 1) {
        bmClear(bm.word, k);
        bm.kind[k] = @intFromEnum(TokenKind.whitespace);
    }
    bmSet(bm.st, j);
    // 尾后接 word 时需要新 run 首 st：classify 时它前一字节 word=1 无 st
    if (e < bm.n and bmGet(bm.word, e)) {
        bmSet(bm.st, e);
    }
}

/// 单字节 illegal：清 word、kind=illegal、st 保留（单字节 token）、
/// 尾后 word 补 run 首 st
fn setIllegalByte(bm: *Bitmaps, j: usize) void {
    bmClear(bm.word, j);
    bm.kind[j] = @intFromEnum(TokenKind.illegal);
    bmSet(bm.st, j);
    if (j + 1 < bm.n and bmGet(bm.word, j + 1)) {
        bmSet(bm.st, j + 1);
    }
}

/// `#`：对齐 scanPrivateName。合法时 body 并入 `#` token（清内部 st）。
fn miscHash(bm: *Bitmaps, src: []const u8, j: usize) void {
    const tok = scanner.scanPrivateName(src, j);
    if (tok.end > j + 1) {
        bmClearRange(bm.st, j + 1, tok.end);
    }
}

/// `\`：对齐 tokenAt 的转义标识符分支。my-scanner 语义：ASCII 词遇
/// `\` 即断词（asciiIdentEnd 不吃 `\`），`\u…` 是独立 token 起点；
/// 只有 unicode 词中段（前字节是 ID_Continue 的续字节）才并入前词
/// （scanIdentifier 的非 ASCII 路径会继续吃转义 part）。
/// decode 失败：单字节 illegal（classify 的 kind 已是，位图无需动）。
fn miscBackslash(bm: *Bitmaps, src: []const u8, j: usize) void {
    const n = src.len;
    if (j + 6 > n or src[j + 1] != 'u') return; // 非 \uXXXX：illegal 单字节
    const r = scanner.decodeIdentEscape(src, j) orelse return;
    if (!scanner.isIdentStartRune(r.cp)) return;

    // private name 内部的转义（`#x\u…`）已由 miscHash 并词，跳过
    if (j > 0 and src[j - 1] == '#' and bm.kind[j - 1] == @intFromEnum(TokenKind.private_name)) return;

    var start = j;
    if (j > 0 and src[j - 1] >= 0x80 and bmGet(bm.word, j - 1)) {
        // unicode 词中段：从词首重放（scanIdentifier 吃转义 part）
        while (start > 0 and bmGet(bm.word, start - 1)) start -= 1;
    }
    const body = scanner.scanIdentifier(src, start);
    if (body.end > start + 1) {
        bmClearRange(bm.st, start + 1, body.end);
    }
    bm.kind[start] = @intFromEnum(body.kind);
}

// ---------------------------------------------------------------------------
// carve：字符串 / 模板 / 注释 / 正则的 opener 事件循环
// ---------------------------------------------------------------------------

/// SIMD 找下一个 `" ' \` /`（32B 窗口 movemask + ctz）
fn findOpener(src: []const u8, n: usize, from: usize) usize {
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

/// 供分 pass 计时 harness 使用（dbg_bm.zig）
pub fn carvePub(bm: *Bitmaps, src: []const u8, options: Options) !void {
    return carve(bm, src, options);
}

fn carve(bm: *Bitmaps, src: []const u8, options: Options) !void {
    const n = src.len;
    var i: usize = 0;
    while (true) {
        const s = findOpener(src, n, i);
        if (s >= n) break;
        switch (src[s]) {
            '"', '\'' => {
                const tok = scanner.scanString(src, s, src[s]);
                carveLiteral(bm, s, tok.end, tok.kind);
                i = tok.end;
            },
            '`' => {
                const tok = scanner.scanTemplate(src, s, options.regex_starts);
                carveLiteral(bm, s, tok.end, tok.kind);
                i = tok.end;
            },
            '/' => {
                i = carveSlash(bm, src, s, options);
            },
            else => {
                // `\`：转义标识符起点（misc pass 已并词）或 illegal，
                // 位图已就位，跳过即可
                i = s + 1;
            },
        }
    }
}

/// 字面量 token 落位：kind[s]=kind、清 [s+1, end) 的 st
/// （oxc 的 inclusive [s+1, end-1] 等价——token 内部全部摘除）
fn carveLiteral(bm: *Bitmaps, s: usize, end: usize, kind: TokenKind) void {
    bm.kind[s] = @intFromEnum(kind);
    if (end > s + 1) {
        bmClearRange(bm.st, s + 1, end);
    }
}

/// `/` 的三义：行注释 / 块注释 / 正则 / 除号（`/=` 自并）。
/// 返回续扫位置。
fn carveSlash(bm: *Bitmaps, src: []const u8, s: usize, options: Options) usize {
    const n = src.len;
    const d: u8 = if (s + 1 < n) src[s + 1] else 0;
    if (d == '/') {
        const end = scanner.lineEnd(src, s);
        carveLiteral(bm, s, end, .comment);
        return end;
    }
    if (d == '*') {
        const end: usize = if (simd.findBlockCommentEnd(src, s + 2)) |e| e else n;
        carveLiteral(bm, s, end, .comment);
        return end;
    }
    if (regexAllowedBitmap(bm, src, s)) {
        const tok = scanner.scanRegex(src, s);
        carveLiteral(bm, s, tok.end, tok.kind);
        if (options.regex_starts) |list| {
            list.appendAssumeCapacity(@intCast(s));
        }
        return tok.end;
    }
    if (d == '=') {
        // `/=`：自并成单 punct token（对齐 scanPunct 贪心）
        bmClear(bm.st, s + 1);
        bmClear(bm.opch, s + 1);
        return s + 2;
    }
    return s + 1;
}

// ---------------------------------------------------------------------------
// 位图版 regexAllowedAfter
// ---------------------------------------------------------------------------

/// `/` 在位图上下文里是正则还是除号。语义对齐 scanner.regexAllowedAfter
/// （单 token 回看启发式）。两段式：
///  1. opch run 重放：`/` 紧贴的 punct token（从 opch run 左界正向贪心，
///     maximum munch 天然正确，覆盖 `++/`、`>>>=/`、`x++++/` 等）
///  2. bmPrev1 跳 trivia：值类 token → 除号；keyword this/super → 除号；
///     其他 keyword → 正则；`)`/`]`/`++`/`--` → 除号；其余 → 正则
fn regexAllowedBitmap(bm: *Bitmaps, src: []const u8, p: usize) bool {
    const n = src.len;

    // #1 punct 重放：opch run 左界 s0，正向贪心到 p
    var s0 = p;
    while (s0 > 0 and p - s0 < 8 and bmGet(bm.opch, s0 - 1)) s0 -= 1;
    if (s0 < p) {
        var t = s0;
        var prev_start = s0;
        while (t < p) {
            prev_start = t;
            // `.5` 是数字（对齐 tokenAt 的 punct_multi 分支）
            if (src[t] == '.' and t + 1 < n and simd.isDigit(src[t + 1])) {
                t = scanner.scanNumber(src, t).end;
            } else {
                t = scanner.scanPunct(src, t).end;
            }
        }
        if (t == p) {
            const c0 = src[prev_start];
            if (c0 == ')' or c0 == ']') return false;
            const l = p - prev_start;
            if ((c0 == '+' or c0 == '-') and l == 2 and src[prev_start + 1] == c0) return false;
            return true;
        }
        // t != p：run 内有数字跨界（如 `1.5e+3/`——scanNumber 吃断 opch run），
        // 落到 #2（此时前 token 是数字，#2 的 kind 分支处理）
    }

    // #2：上一个显著 token
    var q = p;
    while (true) {
        q = bmPrev1(bm.st, q) orelse return true; // 文件头
        const k: TokenKind = @enumFromInt(bm.kind[q]);
        if (k == .whitespace or k == .comment) continue;
        switch (k) {
            .identifier => {
                const we = bmNext0(bm.word, q);
                const w = src[q..we];
                if (std.mem.eql(u8, w, "this") or std.mem.eql(u8, w, "super")) return false;
                if (scanner.isKeyword(w)) return true;
                return false;
            },
            .number, .string, .template, .regex, .private_name => return false,
            .punct => {
                const c0 = src[q];
                if (c0 == ')' or c0 == ']') return false;
                if ((c0 == '+' or c0 == '-') and q > 0 and src[q - 1] == c0) {
                    // `+`/`-` 的 opch run 从左两两配对（maximum munch）：
                    // q 在 run 内偏移为奇 = 它是 `++`/`--` 的对尾
                    var rl = q;
                    while (rl > 0 and bmGet(bm.opch, rl - 1)) rl -= 1;
                    if ((q - rl) % 2 == 1) return false;
                }
                return true;
            },
            else => return true,
        }
    }
}

/// [from, to) 是否全是 trivia st 位（whitespace/comment）
fn allTrivia(bm: *Bitmaps, from: usize, to: usize) bool {
    var t = from;
    while (t < to) {
        const i = bmNext1(bm.st, t, bm.n) orelse return true;
        if (i >= to) return true;
        const k: TokenKind = @enumFromInt(bm.kind[i]);
        if (k != .whitespace and k != .comment) return false;
        t = i + 1;
    }
    return true;
}

// ---------------------------------------------------------------------------
// coalesce：多字符 punct 合并 / 数字粘合 / keyword 判定
// ---------------------------------------------------------------------------

pub fn coalesce(bm: *Bitmaps, src: []const u8) void {
    const n = src.len;
    const nb = (n + 63) / 64;
    var opprev: u64 = 0;
    var cursor: usize = 0;
    var w: usize = 0;
    while (w < nb) : (w += 1) {
        const op = bm.opch[w];
        const opnext: u64 = if (w + 1 < nb) bm.opch[w + 1] else 0;
        const stw = bm.st[w];
        // multi：opch run 起点（token start & 前一字节非 opch & 后一字节 opch）
        const multi = op & stw & ~((op << 1) | (opprev >> 63)) & ((op >> 1) | (opnext << 63));
        // numev：数字/`.5` 起点（numch & st；单 `.` 等 punct 形态在事件处分流）
        const numev = bm.numch[w] & stw;
        var ev = multi | numev;
        opprev = op;
        while (ev != 0) {
            const bit: u32 = @ctz(ev);
            ev &= ev - 1;
            const p = (w << 6) + bit;
            if (p < cursor) continue;
            if (simd.isDigit(src[p]) or
                (src[p] == '.' and p + 1 < n and simd.isDigit(src[p + 1])))
            {
                cursor = glueNumber(bm, src, p);
            } else {
                cursor = gluePunct(bm, src, p);
            }
        }
    }
}

/// 多字符 punct 合并（对齐 scanPunct 贪心链）：kind 不变（.punct），清
/// 内部 st。opch run 内连续贪心（`++++` → `++`+`++`，对齐 oxc 的
/// munch_walk）。返回 cursor（最后 token 的尾字节位）。
fn gluePunct(bm: *Bitmaps, src: []const u8, p: usize) usize {
    const n = src.len;
    var pos = p;
    while (true) {
        const end = if (pos + 4 <= n)
            pos + scanner.punctLenW(std.mem.readInt(u32, src[pos..][0..4], .little))
        else
            pos + scanner.punctLenW(blk: {
                var w: u32 = 0;
                for (src[pos..@min(pos + 4, n)], 0..) |c, k| w |= @as(u32, c) << @intCast(8 * k);
                break :blk w;
            });
        if (end > pos + 1) {
            bmClearRange(bm.st, pos + 1, end);
        }
        pos = end;
        if (!(pos < n and bmGet(bm.opch, pos))) break;
    }
    return pos - 1;
}

/// 数字 token 粘合（对齐 scanNumber）：kind=number、清内部 st 与 opch
/// （`1.5e+3` 的 `+` 不许再触发 multi）。词紧邻数字的非法形态（`3in4`）
/// 对齐 my-scanner 容错语义：不补 st、整段吞掉（候选位图里这些字节本
/// 就不再是 token 起点，无 token 产出）。
fn glueNumber(bm: *Bitmaps, src: []const u8, p: usize) usize {
    const end = scanner.scanNumber(src, p).end;
    bm.kind[p] = @intFromEnum(TokenKind.number);
    if (end > p + 1) {
        bmClearRange(bm.st, p + 1, end);
    }
    if (end > p) {
        bmClearRange(bm.opch, p, end);
    }
    if (end < src.len and bmGet(bm.word, end)) {
        // 非法词邻接（`3in4` 的 `in4`）：end 处放 whitespace kind 的 st 位
        // 作 number 的 end 锚点；该位是 trivia，compress 不产 token，
        // 整段词对齐 my-scanner 的「吞掉」语义。
        bmSet(bm.st, end);
        bm.kind[end] = @intFromEnum(TokenKind.whitespace);
    }
    return end - 1;
}

/// keyword 判定：word run 首 & token 起点 → isKeyword 文本判定。
/// 独立 pass（在 coalesce 事件之后跑）：glueNumber 会给 `3in` 的词补
/// st 位，此 pass 才能看到完整的 token 起点集合。成本与 jump_vec 的
/// 逐词 isKeyword 持平（完美哈希，首字节快败）。
pub fn keywords(bm: *Bitmaps, src: []const u8) void {
    const n = src.len;
    const nb = (n + 63) / 64;
    var wprev: u64 = 0;
    var dtprev: u64 = 0;
    var w: usize = 0;
    while (w < nb) : (w += 1) {
        const wd = bm.word[w];
        const wnext: u64 = if (w + 1 < nb) bm.word[w + 1] else 0;
        const dt = bm.numch[w] & ~bm.word[w]; // dot 位（numch 去掉 digit）
        // dot run 首（前一字节非 dot）；`.foo` 的 foo 不是 keyword 候选
        const dm = dt & ~((dt << 1) | (dtprev >> 63));
        const dcarry = ((dtprev >> 63) & ~(dtprev >> 62)) & 1;
        const starts = wd & ~(wd << 1 | wprev >> 63);
        // run 长度 ≤ 10 位并行过滤（对齐 oxc）：位 p 真 ⟺ wd[p..p+11) 全 word
        const r2 = wd & (wd >> 1);
        const r4 = r2 & (r2 >> 2);
        const r8 = r4 & (r4 >> 4);
        const long_run = r8 & (r2 >> 8) & (wd >> 10);
        // 关键字 ≥2 字符：下一字节也是 word 才可能是 keyword（单字符
        // 变量 a/b/c 在 minified 语料里占 word run 首的大头）
        var ev = starts & ~((dm << 1) | dcarry) & ~long_run & ((wd >> 1) | (wnext << 63));
        wprev = wd;
        dtprev = dt;
        while (ev != 0) {
            const bit: u32 = @ctz(ev);
            ev &= ev - 1;
            const p = (w << 6) + bit;
            if (p >= n or !bmGet(bm.st, p)) continue;
            // glueNumber 的吞掉区锚点（kind=whitespace）不是词起点
            if (bm.kind[p] == @intFromEnum(TokenKind.whitespace)) continue;
            const we = bmNext0(bm.word, p);
            if (scanner.isKeyword(src[p..we])) {
                bm.kind[p] = @intFromEnum(TokenKind.keyword);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// 驱动
// ---------------------------------------------------------------------------

/// 位图缓冲的跨轮复用：bench 计时循环里 scanInto 反复调用，每轮重新
/// alloc/memset 约 1.9×n 字节在小文件上占比极高。oxc 的 bench 口径本就
/// 是 arena 跨轮复用（零分配稳态设计意图，见 architecture.md
/// 「oxc_bitmap」节）——这里对齐同一口径。单线程假设与 bench/CLI 一致；
/// classify 全量重写位图 word，复用只需清兜底 word。
var reuse: ?Bitmaps = null;

fn acquireBitmaps(allocator: std.mem.Allocator, n: usize) !*Bitmaps {
    const nb = (n + 63) / 64 + 1;
    if (reuse) |*bm| {
        if (bm.st.len >= nb) {
            bm.n = n;
            bm.word[nb - 1] = 0;
            bm.st[nb - 1] = 0;
            bm.opch[nb - 1] = 0;
            bm.numch[nb - 1] = 0;
            bm.misc[nb - 1] = 0;
            return bm;
        }
        bm.deinit(allocator);
    }
    reuse = try Bitmaps.alloc(allocator, n);
    return &reuse.?;
}

/// 释放复用缓冲（测试的泄漏检测需显式归还；bench/CLI 退出无需调用）
pub fn releaseReuse(allocator: std.mem.Allocator) void {
    if (reuse) |*bm| bm.deinit(allocator);
    reuse = null;
}

pub fn scanInto(
    tokens: *std.ArrayList(Token),
    allocator: std.mem.Allocator,
    src: []const u8,
    options: Options,
) !void {
    if (options.regex_starts) |list| {
        try scanner.reserveRegexStarts(allocator, src, list);
    }

    const bm = try acquireBitmaps(allocator, src.len);

    classify(bm, src);
    miscPass(bm, src);

    // shebang 特判（对齐 jump_vec/主循环：文件头 `#!` 是独立 token）
    if (src.len >= 2 and src[0] == '#' and src[1] == '!') {
        const end = scanner.lineEnd(src, 0);
        try tokens.append(allocator, .{ .kind = .shebang, .start = 0, .end = @intCast(end) });
        bmClearRange(bm.st, 1, end);
        bm.kind[0] = @intFromEnum(TokenKind.whitespace); // compress 按 trivia 跳过
    }

    try carve(bm, src, options);
    coalesce(bm, src);
    keywords(bm, src);
    try compress(bm, tokens, allocator, options);
}

pub fn scan(allocator: std.mem.Allocator, src: []const u8, options: Options) !scanner.Result {
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(allocator);
    try scanInto(&tokens, allocator, src, options);
    return .{ .tokens = try tokens.toOwnedSlice(allocator), .lines = .{ .src = src, .allocator = allocator } };
}

/// st 位图 → token 流：全量 (pos, kind[pos]) 配对 end=下一 st 位，
/// trivia（whitespace/comment）按 Options 过滤。
pub fn compress(bm: *Bitmaps, tokens: *std.ArrayList(Token), allocator: std.mem.Allocator, options: Options) !void {
    const n = bm.n;
    // sentinel：位 n 恒置位，保证每个 token 都有「下一 st 位」可配对。
    // 位 n 所在 word 的高位段可能是复用缓冲的上一轮残留，先清掉。
    bm.st[n >> 6] &= lowBits(n & 63);
    bmSet(bm.st, n);
    bm.kind[n] = @intFromEnum(TokenKind.whitespace); // sentinel 自身按 trivia 跳过

    // st 位总数是产出 token 数的上界（含 trivia entry），一次预留到位，
    // 热循环全部 appendAssumeCapacity（免每 token 的容量分支）
    // 循环界 = 位 n 所在 word（含 sentinel）：classify 覆盖 [0, ceil(n/64))，
    // 复用缓冲中更高 word 是上一轮残留，不可读
    const nb_total = (n >> 6) + 1;
    var total: usize = 0;
    for (bm.st[0..nb_total]) |wd| total += @popCount(wd);
    try tokens.ensureTotalCapacity(allocator, tokens.items.len + total + 1);

    var pending: Token = undefined;
    var has_pending = false;
    var w: usize = 0;
    outer: while (w < nb_total) : (w += 1) {
        var bits = bm.st[w];
        const base = w << 6;
        while (bits != 0) {
            const pos = base + @ctz(bits);
            bits &= bits - 1;
            if (pos > n) break :outer; // 越界兜底（正常到 sentinel 即止）
            if (has_pending) {
                pending.end = @intCast(pos);
                tokens.appendAssumeCapacity(pending);
                has_pending = false;
            }
            const k: TokenKind = @enumFromInt(bm.kind[pos]);
            if (k == .whitespace) continue;
            if (k == .comment and !options.keep_comments) continue;
            pending = .{ .kind = k, .start = @intCast(pos), .end = 0 };
            has_pending = true;
        }
    }
    if (has_pending) {
        pending.end = @intCast(n);
        tokens.appendAssumeCapacity(pending);
    }
    tokens.appendAssumeCapacity(.{ .kind = .eof, .start = @intCast(n), .end = @intCast(n) });
}

// ---------------------------------------------------------------------------
// 测试：与两阶段 scanner 逐 token 交叉验证
// ---------------------------------------------------------------------------

fn expectSame(src: []const u8) !void {
    const a = std.testing.allocator;
    var want = try scanner.scan(a, src, .{});
    defer want.deinit(a);
    var got_list: std.ArrayList(Token) = .empty;
    defer got_list.deinit(a);
    try scanInto(&got_list, a, src, .{});
    try std.testing.expectEqual(want.tokens.len, got_list.items.len);
    for (want.tokens, got_list.items) |w, g| {
        try std.testing.expectEqual(w.kind, g.kind);
        try std.testing.expectEqual(w.start, g.start);
        try std.testing.expectEqual(w.end, g.end);
    }
}

test "bitmap 与两阶段 scanner 交叉验证" {
    try expectSame("const x = 1 + 2;");
    try expectSame("let re = /ab+c/gi; let s = `a${b}c`;");
    try expectSame("// line comment\n/* block */ var y = \"str\\\"esc\";");
    try expectSame("a.5 + ...b");
    try expectSame("if (a) { b() } else { c() }");
    try expectSame("#!/usr/bin/env node\nconsole.log('hi');");
    try expectSame("x++++/re/");
    try expectSame("3in4");
    try expectSame("const π = Math.PI; // unicode");
    try expectSame("class A { #p = 1; m() { return this.#p; } }");
    try expectSame("a = b => `t${ { x: 1 }.x }s`");
    try expectSame("do { x++ } while (x < 10)");
    try expectSame("label: for (const v of xs) { if (v) continue label; }");
    try expectSame("switch (x) { case 1: break; default: }");
    try expectSame("0x1Fn + 0b1010 + 0o17 + 1_000.5e+3n");
    try expectSame("v = v / 2 / 3; w = v++ / 2;");
    try expectSame("`a${`b${c}d`}e`");
    try expectSame("a===b; c!==d; e>>>=f; g<<=h;");
    try expectSame("if\\u0041 = 1; // \\u 转义标识符");
    try expectSame("a\\u{41}b = 2; // 词中转义");
    try expectSame("#x\\u{41}; // private 内转义");
    try expectSame("x\u{2028}y; // LS 逻辑换行");
    try expectSame("\u{00A0}x; // NBSP 空白");
    releaseReuse(std.testing.allocator);
}
