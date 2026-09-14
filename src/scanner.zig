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
///
/// 判别用 isKeyword（长度 + 首字符两级分发，无 hash）；本表仅作
/// 交叉验证与文档。
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

/// 关键字判别的热路径：长度先排除（2..11），再按首字符分发到
/// 少量 memcmp 候选。与 keywords 表的等价性由测试交叉验证。
fn isKeyword(text: []const u8) bool {
    const eql = std.mem.eql;
    if (text.len < 2 or text.len > 10) return false;
    return switch (text.len) {
        2 => switch (text[0]) {
            'd' => eql(u8, text, "do"),
            'i' => eql(u8, text, "if") or eql(u8, text, "in"),
            'o' => eql(u8, text, "of"),
            else => false,
        },
        3 => switch (text[0]) {
            'f' => eql(u8, text, "for"),
            'l' => eql(u8, text, "let"),
            'n' => eql(u8, text, "new"),
            't' => eql(u8, text, "try"),
            'v' => eql(u8, text, "var"),
            else => false,
        },
        4 => switch (text[0]) {
            'c' => eql(u8, text, "case"),
            'e' => eql(u8, text, "else") or eql(u8, text, "enum"),
            't' => eql(u8, text, "this"),
            'v' => eql(u8, text, "void"),
            'w' => eql(u8, text, "with"),
            else => false,
        },
        5 => switch (text[0]) {
            'a' => eql(u8, text, "async") or eql(u8, text, "await"),
            'b' => eql(u8, text, "break"),
            'c' => eql(u8, text, "catch") or eql(u8, text, "class") or eql(u8, text, "const"),
            's' => eql(u8, text, "super"),
            't' => eql(u8, text, "throw"),
            'w' => eql(u8, text, "while"),
            'y' => eql(u8, text, "yield"),
            else => false,
        },
        6 => switch (text[0]) {
            'd' => eql(u8, text, "delete"),
            'e' => eql(u8, text, "export"),
            'i' => eql(u8, text, "import"),
            'p' => eql(u8, text, "public"),
            'r' => eql(u8, text, "return"),
            's' => eql(u8, text, "static") or eql(u8, text, "switch"),
            't' => eql(u8, text, "typeof"),
            else => false,
        },
        7 => switch (text[0]) {
            'd' => eql(u8, text, "default"),
            'e' => eql(u8, text, "extends"),
            'f' => eql(u8, text, "finally"),
            'p' => eql(u8, text, "package") or eql(u8, text, "private"),
            else => false,
        },
        8 => switch (text[0]) {
            'c' => eql(u8, text, "continue"),
            'd' => eql(u8, text, "debugger"),
            'f' => eql(u8, text, "function"),
            else => false,
        },
        9 => switch (text[0]) {
            'i' => eql(u8, text, "interface"),
            'p' => eql(u8, text, "protected"),
            else => false,
        },
        10 => eql(u8, text, "implements") or eql(u8, text, "instanceof"),
        else => false,
    };
}

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

    // 阶段 2：按块迭代候选位，贪心消费。token 区间内的假起点用
    // `start < pos` 越过。所有状态（pos/prev）都是循环局部变量，
    // 由编译器驻进寄存器——这是数据流化的核心：扫描函数全是纯函数，
    // 没有隐藏的 store/load 链。
    var pos: usize = 0;
    var prev: ?Token = null; // 上一个非注释 token，供 `/` 的正则/除号判别

    if (src.len >= 2 and src[0] == '#' and src[1] == '!') {
        const t = scanShebang(src);
        pos = t.end;
        prev = t;
        try tokens.append(allocator, t);
    }
    for (cls.starts.masks, 0..) |mask, bi| {
        // 一块最多 32 个候选 → 每 token 的容量检查摊薄为每块一次
        try tokens.ensureUnusedCapacity(allocator, simd.block_size);
        var m = mask;
        while (m != 0) {
            const start = bi * simd.block_size + @as(usize, @ctz(m));
            m &= m - 1;
            if (start < pos) continue; // 上一个 token 已越过该假候选
            const tok = tokenAt(src, start, prev);
            pos = tok.end;
            if (tok.kind == .comment) {
                if (options.keep_comments) tokens.appendAssumeCapacity(tok);
                continue;
            }
            prev = tok;
            tokens.appendAssumeCapacity(tok);
        }
    }
    // 尾部空白不是候选起点，pos 可能落后于 src.len；eof 固定 start == end == src.len
    try tokens.append(allocator, .{ .kind = .eof, .start = @intCast(src.len), .end = @intCast(src.len) });
    return cls.newlines + 1;
}

/// 分发类别码：token 首字节 → 位集，comptime 打进 256 项标量表。
/// 表在 L1 常驻，替代字符 range switch，并给纯单字节 punctuator
/// 提供零调用快路径。
const Dispatch = struct {
    /// 单字节 punctuator（`{}()[];,:~@`）：token 恒为 (start, start+1)，
    /// 无需 punctLen。注意 `.` 不在此列（`.5` 是数字）。
    pub const punct_single: u8 = 1 << 0;
    pub const quote: u8 = 1 << 1; // ' " `
    pub const digit: u8 = 1 << 2; // 0-9
    pub const ident_start: u8 = 1 << 3; // A-Za-z_$
    /// 多字节潜在 punctuator（=<>+-*%&|^!?%.，需要 punctLen 贪心）
    pub const punct_multi: u8 = 1 << 4;
    pub const slash: u8 = 1 << 5; // / 注释/正则/除号三义
    pub const hash: u8 = 1 << 6; // #
    // 其余（非 ASCII 等）为 0，走容错路径
};

const dispatch_table: [256]u8 = blk: {
    var t: [256]u8 = @splat(0);
    for ("{}()[];,:~@") |ch| t[ch] |= Dispatch.punct_single;
    for ("'\"`") |ch| t[ch] |= Dispatch.quote;
    // 注意 Zig 的 a..b 是半开区间（会漏掉 'z'/'Z'/'9'），用显式集合
    for ("0123456789") |ch| t[ch] |= Dispatch.digit;
    for ("abcdefghijklmnopqrstuvwxyz") |ch| t[ch] |= Dispatch.ident_start;
    for ("ABCDEFGHIJKLMNOPQRSTUVWXYZ") |ch| t[ch] |= Dispatch.ident_start;
    for ("_$") |ch| t[ch] |= Dispatch.ident_start;
    for ("=<>+-*%&|^!?") |ch| t[ch] |= Dispatch.punct_multi;
    t['.'] |= Dispatch.punct_multi;
    t['/'] |= Dispatch.slash;
    t['#'] |= Dispatch.hash;
    break :blk t;
};

inline fn tokenAt(src: []const u8, start: usize, prev: ?Token) Token {
    const c = src[start];
    const code = dispatch_table[c];

    // 最高频先行：纯单字节 punctuator，直接构造，零函数调用
    if (code & Dispatch.punct_single != 0) {
        return .{ .kind = .punct, .start = @intCast(start), .end = @intCast(start + 1) };
    }
    if (code & Dispatch.ident_start != 0) return scanIdentifier(src, start);
    if (code & Dispatch.digit != 0) return scanNumber(src, start);
    if (code & Dispatch.quote != 0) {
        return if (c == '`') scanTemplate(src, start) else scanString(src, start, c);
    }
    if (code & Dispatch.slash != 0) {
        // 注释、除号、正则三解
        if (tryComment(src, start)) |comment| return comment;
        if (regexAllowedAfter(prev, src)) return scanRegex(src, start);
        return scanPunct(src, start);
    }
    if (code & Dispatch.hash != 0) return scanPrivateName(src, start);
    if (code & Dispatch.punct_multi != 0) {
        // `.5` 是数字，`.` 单独是 punctuator
        if (c == '.' and start + 1 < src.len and simd.isDigit(src[start + 1])) {
            return scanNumber(src, start);
        }
        return scanPunct(src, start);
    }
    return scanNonAscii(src, start);
}

// -- trivia --------------------------------------------------------------

/// start 处若是注释则返回 token；否则返回 null。
fn tryComment(src: []const u8, start: usize) ?Token {
    if (start + 1 >= src.len or src[start] != '/') return null;

    if (src[start + 1] == '/') {
        return .{ .kind = .comment, .start = @intCast(start), .end = @intCast(lineEnd(src, start)) };
    }
    if (src[start + 1] == '*') {
        if (simd.findBlockCommentEnd(src, start + 2)) |end| {
            return .{ .kind = .comment, .start = @intCast(start), .end = @intCast(end) };
        }
        // 未闭合的块注释：吞掉余下全部，容错继续（与真实引擎行为一致）
        return unterminatedBlockComment(src, start);
    }
    return null;
}

// -- token 扫描（全部纯函数：src + start 进，Token 出）--------------------

/// 单/双引号字符串。SIMD 定位 `引号|反斜杠|换行`，转义对直接跳 2 字节。
/// 合法字符串不跨行，所以中途不用维护行数。
fn scanString(src: []const u8, start: usize, quote: u8) Token {
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
            return .{ .kind = .string, .start = @intCast(start), .end = @intCast(idx + 1) };
        }
        if (c == '\\') {
            // TODO: 行继续 `\<newline>` 的换行数目前漏计（编辑器物理行视角）
            i = idx + 2;
            continue;
        }
        // 裸换行：非法字符串，吞到行尾当 illegal，容错继续
        return illegalString(start, lineEnd(src, idx));
    }
    return illegalString(start, src.len); // EOF 未闭合
}

/// 模板字面量：允许跨行。SIMD 定位 `` ` ``、`\`、`$`。
/// `${}` 子表达式用简易花括号平衡扫描（TODO: 子表达式里的嵌套模板、
/// 注释等还会骗过计数，后续改为递归调用 scanner 本体）。
fn scanTemplate(src: []const u8, start: usize) Token {
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
            '`' => return .{ .kind = .template, .start = @intCast(start), .end = @intCast(idx + 1) },
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
    return .{ .kind = .illegal, .start = @intCast(start), .end = @intCast(src.len) }; // EOF 未闭合
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

/// 标识符/关键字。快路径标量扫前 8 字节（多数标识符不长），
/// 更长才 SIMD 续扫：`@ctz(~identPartMask)` 直接给出结尾偏移。
fn scanIdentifier(src: []const u8, start: usize) Token {
    var i = start + 1; // 首字符合法性由 tokenAt 的分发保证
    const fast_end = @min(i + 8, src.len);
    while (i < fast_end and simd.isIdentPart(src[i])) i += 1;
    if (i == fast_end and i < src.len) {
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
    }
    const kind: TokenKind =
        if (isKeyword(src[start..i])) .keyword else .identifier;
    return .{ .kind = kind, .start = @intCast(start), .end = @intCast(i) };
}

/// 私有名 `#foo`；`#` 后不是标识符起始则整个算 illegal。
fn scanPrivateName(src: []const u8, start: usize) Token {
    if (start + 1 < src.len and simd.isIdentStart(src[start + 1])) {
        const body = scanIdentifier(src, start + 1);
        return .{ .kind = .private_name, .start = @intCast(start), .end = body.end };
    }
    return .{ .kind = .illegal, .start = @intCast(start), .end = @intCast(start + 1) };
}

/// 数字字面量：0x/0o/0b、十进制、小数、指数、`_` 分隔符、BigInt `n` 后缀。
/// 标量实现：数字 token 平均只有几字节，SIMD 收益存疑，先求正确。
/// TODO: legacy 八进制、`1.e3`、紧跟标识符字符的非法恢复。
fn scanNumber(src: []const u8, start: usize) Token {
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
    return .{ .kind = .number, .start = @intCast(start), .end = @intCast(i) };
}

/// 正则字面量 `/pattern/flags`：不能跨行，字符类 `[...]` 里的 `/` 不算结束。
fn scanRegex(src: []const u8, start: usize) Token {
    var i = start + 1;
    var in_class = false;
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
            return .{ .kind = .regex, .start = @intCast(start), .end = @intCast(i) };
        }
        i += 1;
    }
    // 失败：吞到行尾当 illegal，容错继续
    return illegalRegex(src, start);
}

/// punctuator，最长匹配（4→3→2→1）。
/// 主体路径一次 4 字节加载（无逐字节边界检查），文件尾不足 4 字节走慢版。
fn scanPunct(src: []const u8, start: usize) Token {
    const len = if (start + 4 <= src.len)
        punctLenW(std.mem.readInt(u32, src[start..][0..4], .little))
    else
        punctLen(src[start..]);
    return .{
        .kind = .punct,
        .start = @intCast(start),
        .end = @intCast(start + len),
    };
}

/// punctLen 的无边界检查版本：w 是 src[start..start+4] 的小端 u32，
/// 一次加载后截取出 b1/b2/b3。
fn punctLenW(w: u32) usize {
    const b1: u8 = @truncate(w >> 8);
    const b2: u8 = @truncate(w >> 16);
    const b3: u8 = @truncate(w >> 24);
    return switch (@as(u8, @truncate(w))) {
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
        else => 1,
    };
}

fn scanShebang(src: []const u8) Token {
    return .{ .kind = .shebang, .start = 0, .end = @intCast(lineEnd(src, 0)) };
}

/// 非 ASCII 字节：按完整 UTF-8 码点消费成 illegal，
/// 避免中文注释碎成一堆单字节 illegal。
fn scanNonAscii(src: []const u8, start: usize) Token {
    @branchHint(.unlikely);
    const len = @min(utf8Len(src[start]), src.len - start);
    return .{ .kind = .illegal, .start = @intCast(start), .end = @intCast(start + len) };
}

// 容错路径统一收进冷函数：@branchHint(.unlikely) 等价 cold attribute，
// 编译器把代码放进 cold 段并让调用点按 unlikely 预测。

fn unterminatedBlockComment(src: []const u8, start: usize) Token {
    @branchHint(.unlikely);
    return .{ .kind = .illegal, .start = @intCast(start), .end = @intCast(src.len) };
}

fn illegalString(start: usize, end: usize) Token {
    @branchHint(.unlikely);
    return .{ .kind = .illegal, .start = @intCast(start), .end = @intCast(end) };
}

fn illegalRegex(src: []const u8, start: usize) Token {
    @branchHint(.unlikely);
    return .{ .kind = .illegal, .start = @intCast(start), .end = @intCast(lineEnd(src, start)) };
}

/// `/` 出现在什么 token 之后时是正则开头，否则是除号。
/// 单 token 回看的启发式，按真实代码的先验取舍，不追语法完备：
/// - 值类 token（标识符/数字/字符串/模板/正则）之后是除号；
/// - `++`/`--` 之后是除号：前缀形式要求左值，`++/re/` 本就是错误代码，
///   真实代码里只能是后缀，而后缀之后接除法；
/// - `}` 之后是正则：块尾开新语句常见，`{...} / x` 对象除法在语义上无意义；
/// - `)`/`]` 之后是除号：`if (x) /re/.test(y)` 这类无副作用的正则方法
///   调用作为单独语句，真实代码里几乎不出现；
/// - 关键字里 this/super 是值，return/typeof/case 等都把 `/` 放进表达式位置。
fn regexAllowedAfter(prev: ?Token, src: []const u8) bool {
    const t = prev orelse return true; // 文件开头
    return switch (t.kind) {
        .identifier, .number, .string, .template, .regex, .private_name => false,
        .punct => blk: {
            // ++/-- 走除号侧（见上）；其余 punctuator（= ( , : + 等运算符）都在表达式位置
            const text = t.slice(src);
            break :blk text[0] != ')' and text[0] != ']' and
                !std.mem.eql(u8, text, "++") and !std.mem.eql(u8, text, "--");
        },
        .keyword => blk: {
            // this/super 是值；其余关键字（return/typeof/in/...）都把 `/` 放进表达式位置
            const text = t.slice(src);
            break :blk !std.mem.eql(u8, text, "this") and !std.mem.eql(u8, text, "super");
        },
        else => true,
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

test "正则 vs 除法（按真实代码先验取舍）" {
    // 后缀 ++/-- 之后只能是除法：前缀形式要求左值，++/re/ 本就是错误代码
    try expectTokens("a++ / b", &.{
        .{ .identifier, "a" },
        .{ .punct, "++" },
        .{ .punct, "/" },
        .{ .identifier, "b" },
        .{ .eof, "" },
    });
    // 块尾开新语句是常态；对象除法在语义上无意义 → `}` 之后判正则
    try expectTokens("if (x) {} /y/.test(s)", &.{
        .{ .keyword, "if" },
        .{ .punct, "(" },
        .{ .identifier, "x" },
        .{ .punct, ")" },
        .{ .punct, "{" },
        .{ .punct, "}" },
        .{ .regex, "/y/" },
        .{ .punct, "." },
        .{ .identifier, "test" },
        .{ .punct, "(" },
        .{ .identifier, "s" },
        .{ .punct, ")" },
        .{ .eof, "" },
    });
    // `)` 之后保持除号：if (x) /re/.test(y) 这类无副作用的正则语句真实代码里几乎不出现
    try expectTokens("if (x) /y/.length", &.{
        .{ .keyword, "if" },
        .{ .punct, "(" },
        .{ .identifier, "x" },
        .{ .punct, ")" },
        .{ .punct, "/" },
        .{ .identifier, "y" },
        .{ .punct, "/" },
        .{ .punct, "." },
        .{ .identifier, "length" },
        .{ .eof, "" },
    });
}

test "尾部空白与 eof" {
    // 末行换行不是候选起点，eof 仍须 start == end == src.len（曾出过 end 落在
    // 最后一个 token 末尾、slice 越界 panic 的 bug）
    try expectTokens("a\n", &.{
        .{ .identifier, "a" },
        .{ .eof, "" },
    });
    try expectTokens("return /x/  \n\n", &.{
        .{ .keyword, "return" },
        .{ .regex, "/x/" },
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

test "isKeyword 与关键字表交叉验证" {
    // 全表逐项验证
    // StaticStringMap 的 KV 无法直接枚举，改用已知的完整清单
    const all = [_][]const u8{
        "async",      "await",   "break",    "case",       "catch",
        "class",      "const",   "continue", "debugger",   "default",
        "delete",     "do",      "else",     "enum",       "export",
        "extends",    "finally", "for",      "function",   "if",
        "implements", "import",  "in",       "instanceof", "interface",
        "let",        "new",     "of",       "package",    "private",
        "protected",  "public",  "return",   "static",     "super",
        "switch",     "this",    "throw",    "try",        "typeof",
        "var",        "void",    "while",    "with",       "yield",
    };
    for (all) |kw| {
        try testing.expect(keywords.has(kw));
        try testing.expect(isKeyword(kw));
    }
    // 非关键字：长度变体与单字符替换
    for (all) |kw| {
        var buf: [16]u8 = undefined;
        @memcpy(buf[0..kw.len], kw);
        buf[kw.len - 1] ^= 1; // 改尾字符
        try testing.expect(!isKeyword(buf[0..kw.len]));
        if (kw.len < 16) {
            @memcpy(buf[0..kw.len], kw);
            buf[kw.len] = 'x'; // 加长
            try testing.expect(!isKeyword(buf[0 .. kw.len + 1]));
        }
    }
    // 常见标识符与边界
    for ([_][]const u8{
        "a",      "x1",  "foo", "barBaz",      "undefined",  "NaN",  "globalThis",
        "getter", "ofx", "iff", "doo",         "instanceOf", "letx", "_let",
        "$if",    "",    "0",   "constructor",
    }) |word| {
        try testing.expectEqual(keywords.has(word), isKeyword(word));
    }
}
