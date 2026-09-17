//! bitmap 变体 —— oxc_lexer 式位图流水线（arm64 NEON）。
//!
//! 架构移植自 oxc 主仓孵化的 oxc_lexer 实验 crate（六趟 unfused 流水线，
//! 见 docs/oxc-bitmap-neon-experiment.md）：classify 一次 SIMD 产出块位图
//! + 每字节 kind，后续 pass 只在字面量 opener / 多字符 token 事件处回读
//! 字节，最后 compress 从位图批量搬运 lexeme。与 oxc 版的关键差异：
//!
//! 1. 语义层完全复用 my-scanner（scanString/scanTemplatePart/scanNumber/
//!    scanPunct/scanRegex/isKeyword——tsc 差分测试口径），而不是 oxc 的
//!    disambiguate 自决体系；正则决策用位图版 regexAllowedAfter
//!    （regex_allowed.zig，对齐 scanner.regexAllowedAfter 的双回看口径，
//!    prev/prev2 文本从位图现场重建）。
//! 2. NEON 没有 movemask/pshufb 等价单指令（Zig/LLVM 也不合成 vqtbl），
//!    位图提取走 LLVM 对 `@bitCast(bool vector → int)` 的 zip+addv
//!    lowering；classify 的 nibble LUT 查表用 inline asm vqtbl1q 补齐
//!    （仅 aarch64——其它架构回退到比较链 classify，见 classify 分流）。
//! 3. 位图 6 张：word/st/opch/numch(digit|dot)/misc/nl。ws 不落盘（st
//!    构造后即弃）；nl（\n、\r + miscPass 补 U+2028/29）服务交付口径的
//!    newline_before flag（trivia 不落盘，换行压成 1 bit 挂到下一个显著
//!    lexeme）。粗流不再区分 keyword/identifier（全归 identifier），
//!    oxc 的 kwinit 位图与 keywords pass 一并取消——`/` 判别按文本现查。
//!
//! 模板拆片（head/middle/tail）下的 carve：opener 扫描只经 `` ` `` 起
//! 模板 part（scanTemplatePart），`${` 后进入 TemplateStack 跟踪模式
//! （opener 之外还找 `{`/`}`），花括号计数归零的 `}` 是续片起点——与
//! scanner.scanAt 同一口径，位图 pass 结构不变。
//!
//! 目录内分文件：bits.zig（容器与位图原语）、vec.zig（向量小件）、
//! classify.zig、misc_pass.zig、carve.zig、regex_allowed.zig、
//! coalesce.zig、compress.zig；本文件是驱动（scan/scanInto + 位图缓冲
//! 复用）与对外入口，各 pass 经下述 re-export 保持原有访问路径
//! （tools/bitmap-passes-prof.zig 依赖）。

const std = @import("std");
const lexeme_mod = @import("../../lexeme.zig");
const scanner = @import("../../scanner.zig");
const bits = @import("bits.zig");
const classify_mod = @import("classify.zig");
const misc_pass = @import("misc_pass.zig");
const carve_mod = @import("carve.zig");
const coalesce_mod = @import("coalesce.zig");
const compress_mod = @import("compress.zig");

const Lexeme = lexeme_mod.Lexeme;

pub const Bitmaps = bits.Bitmaps;
pub const Kind = bits.Kind;
pub const classify = classify_mod.classify;
pub const miscPass = misc_pass.miscPass;
pub const carve = carve_mod.carve;
pub const findOpener = carve_mod.findOpener;
pub const findTemplateStop = carve_mod.findTemplateStop;
pub const coalesce = coalesce_mod.coalesce;
pub const compress = compress_mod.compress;

// -- 驱动 -------------------------------------------------------------------

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
            bm.nl[nb - 1] = 0;
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
    tokens: *std.ArrayList(Lexeme),
    allocator: std.mem.Allocator,
    src: []const u8,
) !void {
    std.debug.assert(src.len <= std.math.maxInt(u32));

    const bm = try acquireBitmaps(allocator, src.len);

    classify(bm, src);
    miscPass(bm, src);

    // shebang 特判（对齐 jump_vec/主循环：文件头 `#!` 是独立 lexeme），
    // 并把 carve 起点推到行尾（shebang 行内不做 opener 扫描）
    var carve_from: usize = 0;
    if (src.len >= 2 and src[0] == '#' and src[1] == '!') {
        const end = scanner.lineEnd(src, 0);
        try tokens.append(allocator, .{ .kind = .shebang, .start = 0, .end = @intCast(end) });
        bits.bmClearRange(bm.st, 1, end);
        bm.kind[0] = @intFromEnum(Kind.whitespace); // compress 按 trivia 跳过
        carve_from = end;
    }

    carve(bm, src, carve_from);
    coalesce(bm, src);
    try compress(bm, tokens, allocator);
}

pub fn scan(allocator: std.mem.Allocator, src: []const u8) !scanner.Result {
    std.debug.assert(src.len <= std.math.maxInt(u32));
    var tokens: std.ArrayList(Lexeme) = .empty;
    errdefer tokens.deinit(allocator);
    try scanInto(&tokens, allocator, src);
    return .{
        .tokens = try tokens.toOwnedSlice(allocator),
        // 行索引留空：首次查询时由 LineIndex 跑 classifyLineBreaks 物化
        .lines = .{ .src = src, .allocator = allocator },
    };
}

// -- 测试：与两阶段 scanner 逐 lexeme 交叉验证（含 newline_before flags） --

fn expectSame(src: []const u8) !void {
    const a = std.testing.allocator;
    var want = try scanner.scan(a, src);
    defer want.deinit(a);
    var got_list: std.ArrayList(Lexeme) = .empty;
    defer got_list.deinit(a);
    try scanInto(&got_list, a, src);
    if (want.tokens.len != got_list.items.len) {
        std.debug.print("lexeme 数不一致：两阶段 {d}，bitmap {d}\nsrc: {s}\n", .{ want.tokens.len, got_list.items.len, src });
        return error.TestTokenCountMismatch;
    }
    for (want.tokens, got_list.items, 0..) |w, g, i| {
        std.testing.expectEqualDeep(w, g) catch |e| {
            std.debug.print("第 {d} 个 lexeme 不符（src: {s}）：两阶段 {any}，bitmap {any}\n", .{ i, src, w, g });
            return e;
        };
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
    // 防回归：coalesce 陈旧事件（st 快照在被 gluePunct 消费的字节上残留）——
    // `...` 末字节的 numev 事件（dot 在 numch 位图）曾越界触发 glueNumber，
    // 把 `...`+数字并成一个 punct（typescript.min.js 实测 `[...191===`）
    try expectSame("[...191===t");
    try expectSame("f(...5)");
    // 反例必须保持绿：`?` 后 `.` 按单字节 punct 消费（st 未清），其 numev
    // 事件触发 glueNumber 粘出 `.5`——st 复核放行该路径
    try expectSame("a?.5:b");
    try expectSame("if\\u0041 = 1; // \\u 转义并入词（新口径）");
    try expectSame("a\\u0042c = 1; // ASCII 词中转义并词");
    try expectSame("3\\u0042c = 1; // 数字后转义是新词起点");
    try expectSame("a\\u{41}b = 2; // \\u{...} 不合并（tsc 同口径）");
    try expectSame("#x\\u{41}; // # 恒单字节 punct");
    try expectSame("x\u{2028}y; // LS 逻辑换行（newline flag）");
    try expectSame("\u{00A0}x; // NBSP 空白");
    // 防回归：审查发现的容错路径
    try expectSame("#!/usr/bin/env node\nx = 1;"); // shebang 行不被 carve 扫
    try expectSame("a \u{2603} b"); // emoji 按码点一个 illegal
    try expectSame("a # b"); // 裸 # 是单字节 punct（新口径）
    try expectSame("3.toFixed(2)"); // 数字后词邻接不吞合法标识符
    try expectSame("x.if = 1;"); // `.if` 的 if 参与 prev2 名字位置判别
    // 模板拆片：子表达式内的字符串/注释/正则/花括号配对（carve 模板栈）
    try expectSame("`a${x}b${y}c`");
    try expectSame("tag`a${x}b${ fn`y` }c` / re/g");
    try expectSame("{ t = `a${x}b${y}c`; } f(`a '${x}'`) }");
    try expectSame("x = `a${ /* } ` */ 1 }d`;");
    try expectSame("x = `a${ // }`\n1 }d`;");
    try expectSame("x = `a${ \"}\" }d`;");
    try expectSame("` ${x/y}` + /re/g");
    try expectSame("`a${ /}/.test(x) }b`");
    try expectSame("` ${r.replace(/\\*\\//g,\"*_/\")} `");
    try expectSame("a/b; `x${ /c/ }y${ `z${ /d/ }w` }v`; /e/g");
    // 正则 vs 除法：prev2 名字位置（新口径）
    try expectSame("x.return / v; x?.if / w; this.#return /2/ u");
    try expectSame("if\\u0041 /x/; return /y/;"); // 转义词不是关键字
    try expectSame("x = \"未闭合\n"); // 裸换行非法字符串
    try expectSame("/* 未闭合块注释"); // 吞到 EOF 落 illegal
    try expectSame("a /* x\ny */ b"); // 块注释内换行 → flag
    try expectSame("a\r\nb\rc"); // CRLF 与孤立 \r
    // 位图 word 边界（n 恰为 64/128 倍数与 n=65）
    try expectSame("a" ** 64 ++ ";");
    try expectSame("a" ** 65 ++ ";");
    try expectSame("a" ** 128 ++ ";");
    // 复用收缩：大文件后接小文件
    try expectSame("const abc = 1;" ** 40);
    try expectSame("x;");
    releaseReuse(std.testing.allocator);
}

test "bitmap 复用缓冲跨轮一致" {
    // 大→小→中混合扫描，结果与单独扫描一致
    const a = std.testing.allocator;
    const cases = [_][]const u8{ "const hello = 'world';\n" ** 30, "x = 1;", "var yy = `tpl ${a} end`;\n" ** 10 };
    for (cases) |src| {
        var got_list: std.ArrayList(Lexeme) = .empty;
        defer got_list.deinit(a);
        try scanInto(&got_list, a, src);
        var want = try scanner.scan(a, src);
        defer want.deinit(a);
        if (want.tokens.len != got_list.items.len) {
            std.debug.print("lexeme 数不一致：两阶段 {d}，bitmap {d}\nsrc: {s}\n", .{ want.tokens.len, got_list.items.len, src });
            return error.TestTokenCountMismatch;
        }
        for (want.tokens, got_list.items) |w, g| {
            try std.testing.expectEqualDeep(w, g);
        }
    }
    releaseReuse(a);
}
