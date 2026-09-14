//! JS/TS scanner 主循环。
//!
//! 性能设计（与 simd.zig 配合）：
//! - 热路径全部是"构造 mask → `@ctz` 停 / `@popCount` 数"的模式：
//!   跳空白、扫标识符、找字符串与模板的结束、找块注释的 `*/`、统计行数。
//! - 冷路径（数字、正则、punctuator）暂时标量：数字 token 平均很短，
//!   punctuator 一次前缀比较就出结果，先求正确，等 profile 说话再向量化。

const std = @import("std");
const token_mod = @import("token.zig");
const simd = @import("simd.zig");

pub const Token = token_mod.Token;
pub const TokenKind = token_mod.TokenKind;

pub const Options = struct {
    /// 输出注释 token（默认把注释当 trivia 跳过）
    keep_comments: bool = false,
};

pub const Result = struct {
    tokens: []Token,
    /// 按 '\n' 计的物理行数（含注释与模板串内部的换行）
    line_count: usize,
};

/// ECMAScript 关键字 + 严格模式保留字 + 未来保留字，
/// 外加 let/static/async/of 这几个上下文关键字（完全合法的标识符，
/// 归入 keyword 只是给上层的提示，文本仍是判别依据）。
/// TS 类型层关键字（interface/type/namespace 等）不在列，留给上层。
const keywords = std.StaticStringMap(void).initComptime(.{
    .{ "async", {} },
    .{ "await", {} },
    .{ "break", {} },
    .{ "case", {} },
    .{ "catch", {} },
    .{ "class", {} },
    .{ "const", {} },
    .{ "continue", {} },
    .{ "debugger", {} },
    .{ "default", {} },
    .{ "delete", {} },
    .{ "do", {} },
    .{ "else", {} },
    .{ "enum", {} },
    .{ "export", {} },
    .{ "extends", {} },
    .{ "finally", {} },
    .{ "for", {} },
    .{ "function", {} },
    .{ "if", {} },
    .{ "implements", {} },
    .{ "import", {} },
    .{ "in", {} },
    .{ "instanceof", {} },
    .{ "interface", {} },
    .{ "let", {} },
    .{ "new", {} },
    .{ "of", {} },
    .{ "package", {} },
    .{ "private", {} },
    .{ "protected", {} },
    .{ "public", {} },
    .{ "return", {} },
    .{ "static", {} },
    .{ "super", {} },
    .{ "switch", {} },
    .{ "this", {} },
    .{ "throw", {} },
    .{ "try", {} },
    .{ "typeof", {} },
    .{ "var", {} },
    .{ "void", {} },
    .{ "while", {} },
    .{ "with", {} },
    .{ "yield", {} },
});

/// 扫描 src，返回 token 序列（以 eof 收尾）。
pub fn scan(allocator: std.mem.Allocator, src: []const u8, options: Options) !Result {
    std.debug.assert(src.len <= std.math.maxInt(u32));
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(allocator);
    const line_count = try scanInto(&tokens, allocator, src, options);
    return .{
        .tokens = try tokens.toOwnedSlice(allocator),
        .line_count = line_count,
    };
}

/// scan 的复用缓冲版本：调用方管理 token 列表（bench 循环里避免反复分配）。
/// 返回物理行数。
pub fn scanInto(
    tokens: *std.ArrayList(Token),
    allocator: std.mem.Allocator,
    src: []const u8,
    options: Options,
) !usize {
    // 阶段 1：一次 SIMD 分类 pass 产出 token 候选起点位图
    var cls = try simd.classifyTokenStarts(allocator, src);
    defer cls.starts.deinit(allocator);

    // 阶段 2：从候选点贪心消费，token 区间内的假起点被自然越过
    var s = Scanner{ .src = src, .options = options, .starts = &cls.starts };
    while (true) {
        const tok = s.next();
        if (tok.kind == .comment and !options.keep_comments) continue;
        try tokens.append(allocator, tok);
        if (tok.kind == .eof) break;
    }
    return cls.newlines + 1;
}

const Scanner = struct {
    src: []const u8,
    pos: usize = 0,
    options: Options = .{},
    /// 阶段 1 产出的 token 候选起点位图
    starts: *const simd.TokenStarts,
    /// 上一个非注释 token，用于判断 `/` 是正则还是除号
    prev: ?Token = null,

    fn next(s: *Scanner) Token {
        const src = s.src;

        // shebang 只允许出现在整个文件的最前面
        if (s.pos == 0 and src.len >= 2 and src[0] == '#' and src[1] == '!') {
            return s.scanShebang();
        }

        const start = s.starts.nextAt(s.pos) orelse {
            s.pos = src.len;
            return s.emit(src.len, .eof);
        };
        s.pos = start;

        const c = src[start];
        return switch (c) {
            '"', '\'' => s.scanString(c),
            '`' => s.scanTemplate(),
            '0'...'9' => s.scanNumber(),
            '.' => blk: {
                // `.5` 是数字，`.` 单独是 punctuator
                if (start + 1 < src.len and simd.isDigit(src[start + 1])) {
                    break :blk s.scanNumber();
                }
                break :blk s.scanPunct();
            },
            'a'...'z', 'A'...'Z', '_', '$' => s.scanIdentifier(),
            '#' => s.scanPrivateName(),
            '/' => blk: {
                // 注释、除号、正则三解
                if (s.tryComment()) |comment| break :blk comment;
                if (regexAllowedAfter(s.prev, src)) break :blk s.scanRegex();
                break :blk s.scanPunct();
            },
            else => blk: {
                if (isPunctByte(c)) break :blk s.scanPunct();
                // 非 ASCII：按完整 UTF-8 码点消费，避免中文注释碎成一堆 illegal
                s.pos = start + @min(utf8Len(c), src.len - start);
                break :blk s.emit(start, .illegal);
            },
        };
    }

    // -- trivia ----------------------------------------------------------

    /// 当前位置若是注释则消费掉并返回 token；否则不动、返回 null。
    /// 只在候选起点为 `/` 时被调用。
    fn tryComment(s: *Scanner) ?Token {
        const src = s.src;
        const start = s.pos;
        if (start + 1 >= src.len or src[start] != '/') return null;

        if (src[start + 1] == '/') {
            s.pos = lineEnd(src, start);
            return s.emit(start, .comment);
        }
        if (src[start + 1] == '*') {
            if (simd.findBlockCommentEnd(src, start + 2)) |end| {
                s.pos = end;
                return s.emit(start, .comment);
            }
            // 未闭合的块注释：吞掉余下全部，容错继续（与真实引擎行为一致）
            s.pos = src.len;
            return s.emit(start, .illegal);
        }
        return null;
    }

    // -- token 扫描 --------------------------------------------------------

    /// 单/双引号字符串。SIMD 定位 `引号|反斜杠|换行`，转义对直接跳 2 字节。
    /// 合法字符串不跨行，所以中途不用维护行数。
    fn scanString(s: *Scanner, quote: u8) Token {
        const start = s.pos;
        const src = s.src;
        var i = start + 1;
        while (i < src.len) {
            const chunk = simd.load(src, i);
            const m = simd.stringStopMask(chunk, quote);
            if (m == 0) {
                i += simd.block_size;
                continue;
            }
            const idx = i + @as(usize, @ctz(m));
            const c = src[idx];
            if (c == quote) {
                s.pos = idx + 1;
                return s.emit(start, .string);
            }
            if (c == '\\') {
                // TODO: 行继续 `\<newline>` 的换行数目前漏计（编辑器物理行视角）
                i = idx + 2;
                continue;
            }
            // 裸换行：非法字符串，吞到行尾当 illegal，容错继续
            s.pos = lineEnd(src, idx);
            return s.emit(start, .illegal);
        }
        s.pos = src.len; // EOF 未闭合
        return s.emit(start, .illegal);
    }

    /// 模板字面量：允许跨行。SIMD 定位 `` ` ``、`\`、`$`。
    /// `${}` 子表达式用简易花括号平衡扫描（TODO: 子表达式里的嵌套模板、
    /// 注释等还会骗过计数，后续改为递归调用 scanner 本体）。
    fn scanTemplate(s: *Scanner) Token {
        const start = s.pos;
        const src = s.src;
        var i = start + 1;
        while (i < src.len) {
            const chunk = simd.load(src, i);
            const m = simd.templateStopMask(chunk);
            if (m == 0) {
                i += simd.block_size;
                continue;
            }
            const idx = i + @as(usize, @ctz(m));
            switch (src[idx]) {
                '`' => {
                    s.pos = idx + 1;
                    return s.emit(start, .template);
                },
                '\\' => i = idx + 2,
                '$' => {
                    if (idx + 1 < src.len and src[idx + 1] == '{') {
                        i = scanTemplateSubstitution(src, idx + 2);
                    } else {
                        i = idx + 1;
                    }
                },
                else => unreachable, // mask 只含以上三种
            }
        }
        s.pos = src.len; // EOF 未闭合
        return s.emit(start, .illegal);
    }

    /// `${...}` 简易平衡扫描：返回配对 `}` 之后的位置。
    /// 顺带跳过子表达式里的普通字符串，防止其中的花括号干扰计数。
    fn scanTemplateSubstitution(src: []const u8, from: usize) usize {
        var depth: usize = 1;
        var i = from;
        while (i < src.len and depth > 0) {
            const c = src[i];
            if (c == '{') {
                depth += 1;
                i += 1;
            } else if (c == '}') {
                depth -= 1;
                i += 1;
            } else if (c == '\'' or c == '"') {
                i = skipQuoted(src, i);
            } else {
                i += 1;
            }
        }
        return i;
    }

    /// 标识符/关键字。SIMD 定位结尾：`@ctz(~identPartMask)` 直接给出长度。
    fn scanIdentifier(s: *Scanner) Token {
        const start = s.pos;
        const src = s.src;
        var i = start + 1; // 首字符合法性由 next() 的分发保证
        while (i < src.len) {
            if (src.len - i >= simd.block_size) {
                const chunk = simd.load(src, i);
                const inv = ~simd.identPartMask(chunk);
                if (inv == 0) {
                    i += simd.block_size;
                    continue;
                }
                i += @as(usize, @ctz(inv));
                break;
            }
            if (simd.isIdentPart(src[i])) {
                i += 1;
            } else break;
        }
        s.pos = i;
        const kind: TokenKind =
            if (keywords.has(src[start..i])) .keyword else .identifier;
        return s.emit(start, kind);
    }

    /// 私有名 `#foo`；`#` 后不是标识符起始则整个算 illegal。
    fn scanPrivateName(s: *Scanner) Token {
        const start = s.pos;
        if (start + 1 < s.src.len and simd.isIdentStart(s.src[start + 1])) {
            s.pos = start + 1;
            const body = s.scanIdentifier();
            return .{
                .kind = .private_name,
                .start = @intCast(start),
                .end = body.end,
            };
        }
        s.pos = start + 1;
        return s.emit(start, .illegal);
    }

    /// 数字字面量：0x/0o/0b、十进制、小数、指数、`_` 分隔符、BigInt `n` 后缀。
    /// 标量实现：数字 token 平均只有几字节，SIMD 收益存疑，先求正确。
    /// TODO: legacy 八进制、`1.e3`、紧跟标识符字符的非法恢复。
    fn scanNumber(s: *Scanner) Token {
        const start = s.pos;
        const src = s.src;
        var i = start;
        if (src[i] == '0' and i + 1 < src.len) {
            switch (src[i + 1]) {
                'x', 'X' => i = scanRadixDigits(src, i + 2, simd.isHexDigit),
                'o', 'O' => i = scanRadixDigits(src, i + 2, simd.isOctalDigit),
                'b', 'B' => i = scanRadixDigits(src, i + 2, simd.isBinaryDigit),
                else => i = scanDecimal(src, i),
            }
        } else {
            i = scanDecimal(src, i);
        }
        if (i < src.len and src[i] == 'n') i += 1; // BigInt 后缀
        while (i < src.len and src[i] == '_') i += 1; // 尾部非法分隔符一并吞掉
        s.pos = i;
        return s.emit(start, .number);
    }

    /// 正则字面量 `/pattern/flags`：不能跨行，字符类 `[...]` 里的 `/` 不算结束。
    fn scanRegex(s: *Scanner) Token {
        const start = s.pos;
        const src = s.src;
        var i = start + 1;
        var in_class = false;
        var closed = false;
        while (i < src.len) {
            const c = src[i];
            if (c == '\\') {
                i += 2;
                continue;
            }
            if (c == '\n' or c == '\r') break;
            if (c == '[') {
                in_class = true;
            } else if (c == ']') {
                in_class = false;
            } else if (c == '/' and !in_class) {
                i += 1;
                while (i < src.len and simd.isIdentPart(src[i])) i += 1; // flags
                closed = true;
                break;
            }
            i += 1;
        }
        if (closed) {
            s.pos = i;
            return s.emit(start, .regex);
        }
        s.pos = lineEnd(src, start); // 失败：吞到行尾当 illegal，容错继续
        return s.emit(start, .illegal);
    }

    /// punctuator，最长匹配（4→3→2→1）。
    fn scanPunct(s: *Scanner) Token {
        const start = s.pos;
        s.pos = start + punctLen(s.src[start..]);
        return s.emit(start, .punct);
    }

    fn scanShebang(s: *Scanner) Token {
        const start = s.pos;
        s.pos = lineEnd(s.src, start);
        return s.emit(start, .shebang);
    }

    fn emit(s: *Scanner, start: usize, kind: TokenKind) Token {
        const t = Token{
            .kind = kind,
            .start = @intCast(start),
            .end = @intCast(s.pos),
        };
        if (kind != .comment) s.prev = t;
        return t;
    }
};

/// `/` 出现在什么 token 之后时是正则开头，否则是除号。
/// 经典共识规则（V8 用精确表）：
/// - 值类 token（标识符/数字/字符串/模板/正则/`)`/`]`）之后是除号；
/// - 表达式位置的关键字（return/typeof/case 等）之后是正则；
/// - `}` 之后本有歧义（块尾 vs 对象字面量尾），先按除号处理。TODO:
///   像 V8 一样在 scanner 里维护花括号栈做精确判定。
fn regexAllowedAfter(prev: ?Token, src: []const u8) bool {
    const t = prev orelse return true; // 文件开头
    return switch (t.kind) {
        .identifier, .number, .string, .template, .regex, .private_name => false,
        .punct => switch (t.slice(src)[0]) {
            ')', ']', '}' => false,
            else => true,
        },
        .keyword => blk: {
            // this/super 是值；其余关键字（return/typeof/in/...）都把 `/` 放进表达式位置
            const text = t.slice(src);
            break :blk !std.mem.eql(u8, text, "this") and !std.mem.eql(u8, text, "super");
        },
        else => true,
    };
}

fn isPunctByte(c: u8) bool {
    return switch (c) {
        '{', '}', '(', ')', '[', ']', ';', ',', '<', '>', '+', '-', '*', '/', '%', '&', '|', '^', '!', '~', '?', ':', '.', '=', '@' => true,
        else => false,
    };
}

/// punctuator 长度：按首字符分发的手写前缀树，O(1) 且无查表循环。
/// 调用方保证 rest 非空、首字符是 punct。
fn punctLen(rest: []const u8) usize {
    const b1 = at(rest, 1);
    const b2 = at(rest, 2);
    const b3 = at(rest, 3);
    return switch (rest[0]) {
        '.' => if (b1 == '.' and b2 == '.') 3 else 1,
        '=' => if (b1 == '=') (if (b2 == '=') 3 else 2) else if (b1 == '>') 2 else 1,
        '!' => if (b1 == '=') (if (b2 == '=') 3 else 2) else 1,
        '<' => if (b1 == '<') (if (b2 == '=') 3 else 2) else if (b1 == '=') 2 else 1,
        '>' => if (b1 == '>') (if (b2 == '>') (if (b3 == '=') 4 else 3) else if (b2 == '=') 3 else 2) else if (b1 == '=') 2 else 1,
        '&' => if (b1 == '&') (if (b2 == '=') 3 else 2) else if (b1 == '=') 2 else 1,
        '|' => if (b1 == '|') (if (b2 == '=') 3 else 2) else if (b1 == '=') 2 else 1,
        '?' => if (b1 == '?') (if (b2 == '=') 3 else 2) else if (b1 == '.' and !(b2 == '.' or simd.isDigit(b2))) 2 else 1,
        '+' => if (b1 == '+' or b1 == '=') 2 else 1,
        '-' => if (b1 == '-' or b1 == '=') 2 else 1,
        '*' => if (b1 == '*') (if (b2 == '=') 3 else 2) else if (b1 == '=') 2 else 1,
        '/' => if (b1 == '=') 2 else 1,
        '%' => if (b1 == '=') 2 else 1,
        '^' => if (b1 == '=') 2 else 1,
        // '{' '}' '(' ')' '[' ']' ';' ',' ':' '~' '@' 等单字符
        else => 1,
    };
}

inline fn at(rest: []const u8, i: usize) u8 {
    return if (i < rest.len) rest[i] else 0;
}

/// UTF-8 前导字节推断码点长度（非法前导按 1 字节吞掉，容错）。
fn utf8Len(first: u8) usize {
    return switch (first) {
        0xf0...0xf4 => 4,
        0xe0...0xef => 3,
        0xc0...0xdf => 2,
        else => 1,
    };
}

fn scanDecimal(src: []const u8, from: usize) usize {
    var i = scanDigits(src, from);
    if (i < src.len and src[i] == '.') {
        i = scanDigits(src, i + 1);
    }
    if (i < src.len and (src[i] == 'e' or src[i] == 'E')) {
        var j = i + 1;
        if (j < src.len and (src[j] == '+' or src[j] == '-')) j += 1;
        if (j < src.len and simd.isDigit(src[j])) i = scanDigits(src, j);
    }
    return i;
}

fn scanDigits(src: []const u8, from: usize) usize {
    var i = from;
    while (i < src.len and (simd.isDigit(src[i]) or src[i] == '_')) i += 1;
    return i;
}

fn scanRadixDigits(src: []const u8, from: usize, comptime pred: fn (u8) bool) usize {
    var i = from;
    while (i < src.len and (pred(src[i]) or src[i] == '_')) i += 1;
    return i;
}

/// 从一个引号字符起跳过整段字符串（含转义），返回其后位置。
fn skipQuoted(src: []const u8, quote_at: usize) usize {
    const quote = src[quote_at];
    var i = quote_at + 1;
    while (i < src.len) {
        if (src[i] == '\\') {
            i += 2;
            continue;
        }
        if (src[i] == quote or src[i] == '\n') return i + 1;
        i += 1;
    }
    return i;
}

fn lineEnd(src: []const u8, from: usize) usize {
    var i = from;
    while (i < src.len and src[i] != '\n') i += 1;
    return i;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

/// (kind, text) 二元组，方便写期望序列
const Expected = struct { TokenKind, []const u8 };

fn expectTokens(src: []const u8, expected: []const Expected) !void {
    const result = try scan(testing.allocator, src, .{});
    defer testing.allocator.free(result.tokens);
    if (result.tokens.len != expected.len) {
        std.debug.print("\nsrc: {s}\n期望 {d} 个 token，实际 {d} 个：\n", .{
            src, expected.len, result.tokens.len,
        });
        for (result.tokens) |t| {
            std.debug.print("  ({s}, \"{s}\")\n", .{ @tagName(t.kind), t.slice(src) });
        }
        return error.TestTokenCountMismatch;
    }
    for (expected, result.tokens) |e, t| {
        if (e[0] != t.kind or !std.mem.eql(u8, e[1], t.slice(src))) {
            std.debug.print(
                "\nsrc: {s}\n第 {d} 个 token 不符：期望 ({s}, \"{s}\")，实际 ({s}, \"{s}\")\n",
                .{ src, t.start, @tagName(e[0]), e[1], @tagName(t.kind), t.slice(src) },
            );
            return error.TestTokenMismatch;
        }
    }
}

test "声明与表达式" {
    try expectTokens("let x = 42;", &.{
        .{ .keyword, "let" },
        .{ .identifier, "x" },
        .{ .punct, "=" },
        .{ .number, "42" },
        .{ .punct, ";" },
        .{ .eof, "" },
    });
}

test "关键字与标识符" {
    try expectTokens("class impl extends Base {", &.{
        .{ .keyword, "class" },
        .{ .identifier, "impl" },
        .{ .keyword, "extends" },
        .{ .identifier, "Base" },
        .{ .punct, "{" },
        .{ .eof, "" },
    });
}

test "字符串与转义" {
    try expectTokens("\"a\\\"b\" + 'c\\'d'", &.{
        .{ .string, "\"a\\\"b\"" },
        .{ .punct, "+" },
        .{ .string, "'c\\'d'" },
        .{ .eof, "" },
    });
}

test "模板字面量（含子表达式与换行）" {
    try expectTokens(
        "const s = `hi ${name + \"!\"}\nnext`;",
        &.{
            .{ .keyword, "const" },
            .{ .identifier, "s" },
            .{ .punct, "=" },
            .{ .template, "`hi ${name + \"!\"}\nnext`" },
            .{ .punct, ";" },
            .{ .eof, "" },
        },
    );
}

test "注释默认跳过" {
    try expectTokens("a // line\n/* block */ b", &.{
        .{ .identifier, "a" },
        .{ .identifier, "b" },
        .{ .eof, "" },
    });
}

test "保留注释" {
    const src = "a /* xx */ b";
    const result = try scan(testing.allocator, src, .{ .keep_comments = true });
    defer testing.allocator.free(result.tokens);
    try testing.expectEqual(TokenKind.comment, result.tokens[1].kind);
    try testing.expectEqualStrings("/* xx */", result.tokens[1].slice(src));
}

test "正则 vs 除法" {
    try expectTokens("var re = /a\\/b/g;", &.{
        .{ .keyword, "var" },
        .{ .identifier, "re" },
        .{ .punct, "=" },
        .{ .regex, "/a\\/b/g" },
        .{ .punct, ";" },
        .{ .eof, "" },
    });
    try expectTokens("x = y / z", &.{
        .{ .identifier, "x" },
        .{ .punct, "=" },
        .{ .identifier, "y" },
        .{ .punct, "/" },
        .{ .identifier, "z" },
        .{ .eof, "" },
    });
    try expectTokens("return /x/.test(s)", &.{
        .{ .keyword, "return" },
        .{ .regex, "/x/" },
        .{ .punct, "." },
        .{ .identifier, "test" },
        .{ .punct, "(" },
        .{ .identifier, "s" },
        .{ .punct, ")" },
        .{ .eof, "" },
    });
}

test "数字字面量" {
    try expectTokens("0x1F_00 0o17 0b1010 1_000_000 3.14 1e-3 .5 2n", &.{
        .{ .number, "0x1F_00" },
        .{ .number, "0o17" },
        .{ .number, "0b1010" },
        .{ .number, "1_000_000" },
        .{ .number, "3.14" },
        .{ .number, "1e-3" },
        .{ .number, ".5" },
        .{ .number, "2n" },
        .{ .eof, "" },
    });
}

test "操作符最长匹配" {
    try expectTokens("a >>>= b === c ?? d?.e ... f**g", &.{
        .{ .identifier, "a" },
        .{ .punct, ">>>=" },
        .{ .identifier, "b" },
        .{ .punct, "===" },
        .{ .identifier, "c" },
        .{ .punct, "??" },
        .{ .identifier, "d" },
        .{ .punct, "?." },
        .{ .identifier, "e" },
        .{ .punct, "..." },
        .{ .identifier, "f" },
        .{ .punct, "**" },
        .{ .identifier, "g" },
        .{ .eof, "" },
    });
    try expectTokens("a ??= b &&= c ||= d => e <<= f >>= g >>> h", &.{
        .{ .identifier, "a" },
        .{ .punct, "??=" },
        .{ .identifier, "b" },
        .{ .punct, "&&=" },
        .{ .identifier, "c" },
        .{ .punct, "||=" },
        .{ .identifier, "d" },
        .{ .punct, "=>" },
        .{ .identifier, "e" },
        .{ .punct, "<<=" },
        .{ .identifier, "f" },
        .{ .punct, ">>=" },
        .{ .identifier, "g" },
        .{ .punct, ">>>" },
        .{ .identifier, "h" },
        .{ .eof, "" },
    });
}

test "非 ASCII 按码点消费" {
    // "中" 的 UTF-8 是 3 字节，应合成一个 illegal 而不是每字节一个
    try expectTokens("a 中 b", &.{
        .{ .identifier, "a" },
        .{ .illegal, "中" },
        .{ .identifier, "b" },
        .{ .eof, "" },
    });
}

test "`?...` 不被误吞成 `?.`" {
    try expectTokens("a ? ...b : c", &.{
        .{ .identifier, "a" },
        .{ .punct, "?" },
        .{ .punct, "..." },
        .{ .identifier, "b" },
        .{ .punct, ":" },
        .{ .identifier, "c" },
        .{ .eof, "" },
    });
}

test "长空白跨块跳过" {
    var buf: [300]u8 = undefined;
    @memset(&buf, ' ');
    buf[0] = 'a';
    buf[299] = 'b';
    try expectTokens(&buf, &.{
        .{ .identifier, "a" },
        .{ .identifier, "b" },
        .{ .eof, "" },
    });
}

test "块注释跨块（各种对齐）" {
    for (0..80) |pad| {
        var buf: [200]u8 = undefined;
        @memset(&buf, ' ');
        const snippet = "/* abcdef */ x";
        @memcpy(buf[pad..][0..snippet.len], snippet);
        const src = buf[0 .. pad + snippet.len];
        try expectTokens(src, &.{
            .{ .identifier, "x" },
            .{ .eof, "" },
        });
    }
}

test "行数统计" {
    const src = "a\n// c\nb\n`multi\nline`";
    const result = try scan(testing.allocator, src, .{});
    defer testing.allocator.free(result.tokens);
    try testing.expectEqual(@as(usize, 5), result.line_count);
}

test "shebang" {
    try expectTokens("#!/usr/bin/env node\nx", &.{
        .{ .shebang, "#!/usr/bin/env node" },
        .{ .identifier, "x" },
        .{ .eof, "" },
    });
}

test "私有名" {
    try expectTokens("this.#x", &.{
        .{ .keyword, "this" },
        .{ .punct, "." },
        .{ .private_name, "#x" },
        .{ .eof, "" },
    });
}

test "非法输入容错（不中断）" {
    try expectTokens("a \x01 b", &.{
        .{ .identifier, "a" },
        .{ .illegal, "\x01" },
        .{ .identifier, "b" },
        .{ .eof, "" },
    });
    try expectTokens("\"abc", &.{
        .{ .illegal, "\"abc" },
        .{ .eof, "" },
    });
    // 未闭合块注释：吞掉剩余全部，产出 illegal（错误可见，容错不中断）
    try expectTokens("/* 未闭合", &.{
        .{ .illegal, "/* 未闭合" },
        .{ .eof, "" },
    });
    try expectTokens("\"ab\ncd", &.{
        .{ .illegal, "\"ab" },
        .{ .identifier, "cd" },
        .{ .eof, "" },
    });
}
