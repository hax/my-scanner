//! JS/TS scanner 主循环。
//!
//! 产出是粗粒度 Lexeme 流（见 lexeme.zig）：连续覆盖全文，trivia
//! （whitespace / newline / comment）常驻，end 隐含为下一个 lexeme 的 start。
//!
//! 性能设计（与 simd.zig 配合）：
//! - 热路径全部是"构造 mask → `@ctz` 停 / `@popCount` 数"的模式：
//!   跳空白、扫标识符、找字符串与模板的结束、找块注释的 `*/`、统计行数。
//! - 冷路径（数字、正则、punctuator）暂时标量：数字 lexeme 平均很短，
//!   punctuator 一次前缀比较就出结果，先求正确，等 profile 说话再向量化。

const std = @import("std");
const lexeme_mod = @import("lexeme.zig");
const simd = @import("simd.zig");
const unicode = @import("unicode.zig");

pub const Lexeme = lexeme_mod.Lexeme;
pub const LexemeKind = lexeme_mod.LexemeKind;

pub const Result = struct {
    tokens: []Lexeme,
    /// 行号查询索引（惰性构建：不查询则零成本，见 LineIndex）
    lines: LineIndex,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.tokens);
        self.lines.deinit();
        self.* = undefined;
    }

    /// 逻辑换行总数 + 1（\n、孤立 \r、U+2028/U+2029；含注释与字符串内部）
    pub fn lineCount(self: *Result) !usize {
        return self.lines.lineCount();
    }
};

/// 逻辑换行索引（惰性）：扫描期不建任何行数据结构——只要调用方
/// 不查行号，行跟踪成本为零（对齐 yuku 等引擎的交付物：它们扫描期
/// 只顺路带 1-bit「前面有换行」flag，行号是下游按需重算的）。
/// 首次 lineAt/lineCount 时才跑裁剪版换行 pass（classifyLineBreaks）
/// 并构建块前缀数组，之后每次查询 O(1)：一次块查 + 一次 popcount。
/// 行号在真实下游（报错、sourcemap、ASI 判别）本就是按需的。
pub const LineIndex = struct {
    src: []const u8,
    allocator: std.mem.Allocator,
    /// 每块一个换行位图。两阶段引擎扫描时已顺带算出（预填），
    /// 单阶段变体留空、ensure 时才计算
    breaks: []u32 = &.{},
    /// prefix[b] = 块 b 之前的换行总数（ensure 时从 breaks 构建）
    prefix: []u32 = &.{},
    ready: bool = false,

    pub fn lineAt(self: *LineIndex, offset: usize) !usize {
        try self.ensure();
        if (self.prefix.len == 0) return 1;
        if (offset >= self.src.len) return self.lineCount();
        const b = offset / simd.block_size;
        const within = self.breaks[b] & ((@as(u32, 1) << @intCast(offset % simd.block_size)) - 1);
        return @as(usize, self.prefix[b]) + @as(usize, @popCount(within)) + 1;
    }

    pub fn lineCount(self: *LineIndex) !usize {
        try self.ensure();
        if (self.prefix.len == 0) return 1;
        const last = self.prefix.len - 1;
        return @as(usize, self.prefix[last]) + @as(usize, @popCount(self.breaks[last])) + 1;
    }

    fn ensure(self: *LineIndex) !void {
        if (self.ready) return;
        self.ready = true;
        if (self.breaks.len == 0 and self.src.len > 0) {
            const cls = try simd.classifyLineBreaks(self.allocator, self.src);
            self.breaks = cls.line_breaks;
        }
        const prefix = try self.allocator.alloc(u32, self.breaks.len);
        var acc: u32 = 0;
        for (self.breaks, 0..) |m, b| {
            prefix[b] = acc;
            acc += @popCount(m);
        }
        self.prefix = prefix;
    }

    pub fn deinit(self: *LineIndex) void {
        self.allocator.free(self.breaks);
        self.allocator.free(self.prefix);
    }
};

/// ECMAScript 关键字 + 严格模式保留字 + 未来保留字，
/// 外加 let/static/async/of 这几个上下文关键字。
/// 粗流不再区分 keyword/identifier（全归 identifier），本表收缩为内部
/// 设施：`/` 的正则/除号判别需要关键字概念（this/super 是值，其余
/// 关键字把 `/` 放进表达式位置）。
const keyword_list = [_][]const u8{
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

/// 判别用 isKeyword（完美哈希一次探查）；本表仅作测试交叉验证与文档。
const keywords = std.StaticStringMap(void).initComptime(blk: {
    var kvs: [keyword_list.len]struct { []const u8, void } = undefined;
    for (keyword_list, 0..) |kw, i| kvs[i] = .{ kw, {} };
    break :blk kvs;
});

/// 关键字判别的热路径：完美哈希（首 + 次 + 末字符 + 长度）一次探查 +
/// 一次 memcmp 确证。乘数离线搜索到零碰撞（45 词 → 128 槽，构建期
/// @compileError 验证）。只服务 `/` 判别路径（冷），不再挂标识符热路径。
/// 与 keywords 表的等价性由测试交叉验证。
fn keywordHash(text: []const u8) usize {
    return (text[0] +% text[1] +% text[text.len - 1] *% 62 +% text.len *% 27) & 127;
}

const KwEntry = struct { name: [10]u8, len: u8 };

const keyword_table: [128]KwEntry = blk: {
    var t: [128]KwEntry = @splat(.{ .name = @splat(0), .len = 0 });
    for (keyword_list) |kw| {
        const h = keywordHash(kw);
        if (t[h].len != 0) @compileError("完美哈希碰撞: " ++ kw);
        var name: [10]u8 = @splat(0);
        @memcpy(name[0..kw.len], kw);
        t[h] = .{ .name = name, .len = kw.len };
    }
    break :blk t;
};

pub fn isKeyword(text: []const u8) bool {
    if (text.len < 2 or text.len > 10) return false;
    const e = &keyword_table[keywordHash(text)];
    return e.len == text.len and std.mem.eql(u8, text, e.name[0..e.len]);
}

/// 扫描 src，返回 lexeme 序列（以 eof 收尾）+ 惰性行号索引。
pub fn scan(allocator: std.mem.Allocator, src: []const u8) !Result {
    std.debug.assert(src.len <= std.math.maxInt(u32));
    var tokens: std.ArrayList(Lexeme) = .empty;
    errdefer tokens.deinit(allocator);

    var cls = try simd.classifyTokenStarts(allocator, src);
    // masks 只在扫描期间使用（成功路径也释放）；line_breaks 是 classify
    // 的顺带产物，预填给 LineIndex（本引擎的行号地基零额外成本）
    defer cls.starts.deinit(allocator);
    errdefer allocator.free(cls.line_breaks);

    try consume(&tokens, allocator, src, &cls.starts, cls.line_breaks);

    return .{
        .tokens = try tokens.toOwnedSlice(allocator),
        .lines = .{ .src = src, .allocator = allocator, .breaks = cls.line_breaks },
    };
}

/// scan 的复用缓冲版本：调用方管理 lexeme 列表（bench 循环里避免反复分配）。
/// 不产出任何行号信息（行索引是惰性设计，纯词法化路径零行跟踪成本；
/// 本引擎的 classify 顺带算换行位图，用完即弃）。
pub fn scanInto(
    tokens: *std.ArrayList(Lexeme),
    allocator: std.mem.Allocator,
    src: []const u8,
) !void {
    var cls = try simd.classifyTokenStarts(allocator, src);
    defer cls.starts.deinit(allocator);
    defer allocator.free(cls.line_breaks);
    try consume(tokens, allocator, src, &cls.starts, cls.line_breaks);
}

/// 模板上下文栈：template_head 压一层（每个帧代表"在某模板的一个子表达
/// 式内"），层内花括号计数；`}` 在计数归零时是模板续片起点（重扫为
/// middle/tail），否则只是普通块/对象闭合。middle 重开同一模板的下一个
/// 子表达式（帧保持），tail 弹一层。上界 64 层，真实代码嵌套不过几层；
/// 溢出不再压栈（按普通 punct 容错，不中断）。三个驱动循环
/// （两阶段 / jump_vec / scalar）共用。
pub const TemplateStack = struct {
    depths: [64]u32 = undefined,
    len: u32 = 0,

    /// `}` 是否当前帧的模板收尾（花括号计数已归零）
    pub fn closesTemplate(self: *const TemplateStack) bool {
        return self.len > 0 and self.depths[self.len - 1] == 0;
    }

    /// 显著 lexeme 落盘后更新栈（trivia 不调用；c 是 lexeme 首字节，
    /// 仅 punct 用得到）
    pub fn track(self: *TemplateStack, kind: LexemeKind, c: u8) void {
        switch (kind) {
            // head 开新模板压一层；middle 不压栈——它是同一帧内下一个
            // 子表达式的开始（`${` 重开当前模板的子表达式，帧在 `}` 拦截
            // 时已保持归零；多压一层会让模板结束后残留孤帧，把后续普通
            // `}` 误扫成 template_tail）；tail 收尾弹一层
            .template_head => self.push(),
            .template_tail => self.pop(),
            .punct => {
                if (self.len > 0) {
                    if (c == '{') self.depths[self.len - 1] +%= 1;
                    if (c == '}') self.depths[self.len - 1] -%= 1;
                }
            },
            else => {},
        }
    }

    fn push(self: *TemplateStack) void {
        if (self.len < self.depths.len) {
            self.depths[self.len] = 0;
            self.len += 1;
        }
    }

    fn pop(self: *TemplateStack) void {
        self.len -= 1;
    }
};

/// 扫描中的临时结果：kind + end。start 由调用方持有。
/// ws = true 表示 unicode whitespace（此时 kind 字段无效）：驱动循环
/// 跳过并顺带置 newline_before（含 U+2028/29 时），不落盘——trivia
/// 不进交付流，内部信号不占用 LexemeKind。
pub const Scan = struct {
    kind: LexemeKind,
    end: usize,
    ws: bool = false,
};

/// unicode whitespace 码点是否行终止符（U+2028/U+2029 = E2 80 A8/A9；
/// 其余 ws 码点不是）。调用方保证 start 处是完整 ws 码点
/// （unicodeWhitespaceLen 已验证，读取不越界）。
pub inline fn wsIsLineTerminator(src: []const u8, start: usize) bool {
    return src[start] == 0xE2 and src[start + 1] == 0x80 and
        (src[start + 2] == 0xA8 or src[start + 2] == 0xA9);
}

/// classify 的换行位图上查 [from, to) 是否含行终止符
/// （\n、孤立 \r、U+2028/U+2029，与 LineIndex 同口径；位标记在行终止
/// 字节上）。两阶段引擎的 newline_before 检测全部走这里——位图是
/// classify 副产品，避免对空白 run / 注释体的二次扫描（单阶段变体
/// 没有位图，走扫描融合版 skipWhitespace/findBlockCommentEnd）。
fn breaksInRange(line_breaks: []const u32, from: usize, to: usize) bool {
    if (from >= to) return false;
    const first = from / simd.block_size;
    const last = (to - 1) / simd.block_size;
    var b = first;
    while (b <= last) : (b += 1) {
        var m = line_breaks[b];
        if (b == first) m &= @as(u32, std.math.maxInt(u32)) << @intCast(from % simd.block_size);
        if (b == last) {
            const hi = (to - 1) % simd.block_size;
            if (hi < simd.block_size - 1) m &= (@as(u32, 1) << @intCast(hi + 1)) - 1;
        }
        if (m != 0) return true;
    }
    return false;
}

/// 阶段 2：块内迭代候选位，贪心消费。lexeme 区间内的假起点用
/// `start < pos` 越过。所有状态（pos/prev/tpl/nl_before）都是循环局部
/// 变量，由编译器驻进寄存器——这是数据流化的核心：扫描函数全是纯函数，
/// 没有隐藏的 store/load 链。
///
/// trivia 不落盘（交付口径对齐 yuku）：候选间隙即 ASCII 空白 run，
/// unicode whitespace 走 tokenAt 的 ws 标记、注释由驱动循环前置判别——
/// 三者只顺路累积 newline_before，挂到下一个显著 lexeme 的 flags 上。
fn consume(
    tokens: *std.ArrayList(Lexeme),
    allocator: std.mem.Allocator,
    src: []const u8,
    starts: *const simd.TokenStarts,
    line_breaks: []const u32,
) !void {
    var pos: usize = 0;
    var prev_kind: ?LexemeKind = null; // 上一个显著 lexeme，供 `/` 判别
    var prev_text: []const u8 = "";
    var prev2_text: []const u8 = ""; // prev 之前那个显著 lexeme 的文本（名字位置判别）
    var tpl: TemplateStack = .{};
    var nl_before = false; // 上一个显著 lexeme 之后的 trivia 是否含行终止符

    if (src.len >= 2 and src[0] == '#' and src[1] == '!') {
        const s = scanShebang(src);
        pos = s.end;
        prev_kind = s.kind;
        prev_text = src[0..s.end];
        try tokens.append(allocator, .{ .kind = .shebang, .start = 0, .end = @intCast(s.end) });
    }
    for (starts.masks, 0..) |mask, bi| {
        // 整块已被上一个 lexeme 覆盖（如长块注释/长字符串的后续块）：
        // 直接跳过整块，避免逐假候选迭代（lib.dom.d.ts 这类 JSDoc 密集
        // 语料里，块注释内的 `*` `/` 全是假候选，这里是主要成本）
        if (bi * simd.block_size + simd.block_size <= pos) continue;
        // 一块最多 32 个候选 → 每 lexeme 的容量检查摊薄为每块一次
        try tokens.ensureUnusedCapacity(allocator, simd.block_size);
        var m = mask;
        while (m != 0) {
            const start = bi * simd.block_size + @as(usize, @ctz(m));
            m &= m - 1;
            if (start < pos) continue; // 上一个 lexeme 已越过该假候选
            if (start > pos and !nl_before) nl_before = breaksInRange(line_breaks, pos, start);
            const c0 = src[start];
            const s = blk: {
                if (c0 == '/' and start + 1 < src.len) {
                    const n = src[start + 1];
                    if (n == '/') {
                        // 行注释：体不含行终止符，结尾 \n 归后续 gap
                        pos = lineEnd(src, start);
                        continue;
                    }
                    if (n == '*') {
                        if (simd.findBlockCommentEnd(src, start + 2)) |end| {
                            if (!nl_before) nl_before = breaksInRange(line_breaks, start, end.end);
                            pos = end.end;
                            continue;
                        }
                        // 未闭合块注释：吞掉余下全部，illegal 落盘（错误可见）
                        break :blk unterminatedBlockComment(src);
                    }
                }
                break :blk scanAt(src, start, prev_kind, prev_text, prev2_text, &tpl);
            };
            if (s.ws) { // unicode whitespace：跳过，顺带置 flag
                if (!nl_before) nl_before = breaksInRange(line_breaks, start, s.end);
                pos = s.end;
                continue;
            }
            pos = s.end;
            tokens.appendAssumeCapacity(.{
                .kind = s.kind,
                .flags = if (nl_before) lexeme_mod.flag_newline_before else 0,
                .start = @intCast(start),
                .end = @intCast(s.end),
            });
            nl_before = false;
            // 栈空且非 head 时 track 必为 no-op，短路省掉 switch（语义同）
            if (tpl.len > 0 or s.kind == .template_head) tpl.track(s.kind, src[start]);
            prev2_text = prev_text;
            prev_text = src[start..s.end];
            prev_kind = s.kind;
        }
    }
    // 尾部空白不是候选起点，pos 可能落后于 src.len：补一次行终止符检测
    // （单阶段变体的尾部 run 在循环内自然走到，这里需要显式补），
    // eof 固定 start == end == src.len
    if (src.len > pos and !nl_before) nl_before = breaksInRange(line_breaks, pos, src.len);
    try tokens.append(allocator, .{
        .kind = .eof,
        .flags = if (nl_before) lexeme_mod.flag_newline_before else 0,
        .start = @intCast(src.len),
        .end = @intCast(src.len),
    });
}

/// 候选起点处的完整判别：tokenAt + 模板收尾拦截（`}` 在花括号计数归零的
/// 帧里是模板续片起点）。驱动循环共用，语义单点。
pub inline fn scanAt(
    src: []const u8,
    start: usize,
    prev_kind: ?LexemeKind,
    prev_text: []const u8,
    prev2_text: []const u8,
    tpl: *TemplateStack,
) Scan {
    const s = tokenAt(src, start, prev_kind, prev_text, prev2_text);
    // 栈空（不在任何模板内）时短路全部模板逻辑：模板-free 文件每个
    // punct 只付一次比较（曾按 kind/字节顺序判，punct 需两次）
    if (tpl.len > 0 and s.kind == .punct and src[start] == '}' and tpl.closesTemplate()) {
        return scanTemplatePart(src, start);
    }
    return s;
}

/// 分发类别码：lexeme 首字节 → 位集，comptime 打进 256 项标量表。
/// 表在 L1 常驻，替代字符 range switch，并给纯单字节 punctuator
/// 提供零调用快路径。
pub const Dispatch = struct {
    /// 单字节 punctuator（`{}()[];,:~@#`）：lexeme 恒为 (start, start+1)，
    /// 无需 punctLen。注意 `.` 不在此列（`.5` 是数字）；
    /// `#` 恒单字节（私有名的合法性留 parser：`#foo` = `#` + identifier）
    pub const punct_single: u8 = 1 << 0;
    pub const quote: u8 = 1 << 1; // ' " `
    pub const digit: u8 = 1 << 2; // 0-9
    pub const ident_start: u8 = 1 << 3; // A-Za-z_$
    /// 多字节潜在 punctuator（=<>+-*%&|^!?%.，需要 punctLen 贪心）
    pub const punct_multi: u8 = 1 << 4;
    pub const slash: u8 = 1 << 5; // / 注释/正则/除号三义
    /// ASCII 空白（' ' \t \n \r \v \f）：单阶段变体主循环用它一次表查
    /// 合并「是否空白」与「按什么分发」两个判断（tokenAt 本身不消费此位）
    pub const whitespace: u8 = 1 << 6;
    // 其余（非 ASCII 等）为 0，走容错路径
};

pub const dispatch_table: [256]u8 = blk: {
    var t: [256]u8 = @splat(0);
    for ("{}()[];,:~@#") |ch| t[ch] |= Dispatch.punct_single;
    for ("'\"`") |ch| t[ch] |= Dispatch.quote;
    // 注意 Zig 的 a..b 是半开区间（会漏掉 'z'/'Z'/'9'），用显式集合
    for ("0123456789") |ch| t[ch] |= Dispatch.digit;
    for ("abcdefghijklmnopqrstuvwxyz") |ch| t[ch] |= Dispatch.ident_start;
    for ("ABCDEFGHIJKLMNOPQRSTUVWXYZ") |ch| t[ch] |= Dispatch.ident_start;
    for ("_$") |ch| t[ch] |= Dispatch.ident_start;
    for ("=<>+-*%&|^!?") |ch| t[ch] |= Dispatch.punct_multi;
    t['.'] |= Dispatch.punct_multi;
    t['/'] |= Dispatch.slash;
    t[' '] |= Dispatch.whitespace;
    for (0x09..0x0E) |ch| t[ch] |= Dispatch.whitespace; // \t \n \v \f \r
    break :blk t;
};

pub inline fn tokenAt(
    src: []const u8,
    start: usize,
    prev_kind: ?LexemeKind,
    prev_text: []const u8,
    prev2_text: []const u8,
) Scan {
    const c = src[start];
    const code = dispatch_table[c];

    // 最高频先行：纯单字节 punctuator，直接构造，零函数调用
    if (code & Dispatch.punct_single != 0) {
        return .{ .kind = .punct, .end = start + 1 };
    }
    if (code & Dispatch.ident_start != 0) return scanIdentifier(src, start);
    if (code & Dispatch.digit != 0) return scanNumber(src, start);
    if (code & Dispatch.quote != 0) {
        return if (c == '`') scanTemplatePart(src, start) else scanString(src, start, c);
    }
    if (code & Dispatch.slash != 0) {
        // 除号、正则两解（注释由驱动循环前置判别，不到这里）
        if (regexAllowedAfter(prev_kind, prev_text, prev2_text)) {
            return scanRegex(src, start);
        }
        return scanPunct(src, start);
    }
    if (c == '\\') {
        // \uXXXX 转义标识符（tsc 纯 scanner 不合并 \u{...}，对齐）
        if (decodeIdentEscape(src, start)) |r| {
            if (isIdentStartRune(r.cp)) return scanIdentifier(src, start);
        }
        return illegalBackslash(start);
    }
    if (code & Dispatch.punct_multi != 0) {
        // `.5` 是数字，`.` 单独是 punctuator
        if (c == '.' and start + 1 < src.len and simd.isDigit(src[start + 1])) {
            return scanNumber(src, start);
        }
        return scanPunct(src, start);
    }
    return scanNonAscii(src, start);
}

// -- lexeme 扫描（全部纯函数：src + start 进，Scan 出）--------------------

/// 单/双引号字符串。SIMD 定位 `引号|反斜杠|换行`，转义对直接跳 2 字节。
/// 合法字符串不跨行，所以中途不用维护行数。
fn scanString(src: []const u8, start: usize, quote: u8) Scan {
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
            return .{ .kind = .string, .end = idx + 1 };
        }
        if (c == '\\') {
            // `\`+CRLF 是合法行继续：跳 3 字节（`\`+LF / `\`+孤立 \r 跳 2）
            if (idx + 2 < src.len and src[idx + 1] == '\r' and src[idx + 2] == '\n') {
                i = idx + 3;
            } else {
                i = idx + 2;
            }
            continue;
        }
        // 裸换行：非法字符串，吞到行尾当 illegal，容错继续
        return illegalString(lineEnd(src, idx));
    }
    return illegalString(src.len); // EOF 未闭合
}

/// 模板片段：start 在 `` ` ``（模板起点）或 `}`（子表达式收尾、续片起点）。
/// SIMD 定位 `` ` ``、`\`、`$`：`${` 收尾为 head/middle（含 `${`），
/// `` ` `` 收尾为 no_substitution/tail（含反引号），EOF 未闭合为 illegal。
/// 片段内的子表达式由驱动循环按普通 lexeme 流扫描（模板栈判别收尾 `}`）。
pub fn scanTemplatePart(src: []const u8, start: usize) Scan {
    const from_backtick = src[start] == '`';
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
            '`' => return .{
                .kind = if (from_backtick) .no_substitution_template else .template_tail,
                .end = idx + 1,
            },
            '\\' => i = idx + 2,
            '$' => {
                if (idx + 1 < src.len and src[idx + 1] == '{') {
                    return .{
                        .kind = if (from_backtick) .template_head else .template_middle,
                        .end = idx + 2,
                    };
                }
                i = idx + 1;
            },
            else => unreachable, // mask 只含以上三种
        }
    }
    return .{ .kind = .illegal, .end = src.len }; // EOF 未闭合
}

/// 解码 i 处（指向 `\`）的标识符转义 `\uXXXX`，返回码点与总长 6。
/// 只支持四十六进制形式——`\u{...}` 形式 tsc 纯 scanner 不合并
/// （拆成普通 token），对齐该行为。
pub fn decodeIdentEscape(src: []const u8, i: usize) ?unicode.Rune {
    if (i + 6 > src.len or src[i + 1] != 'u') return null;
    var cp: u21 = 0;
    for (src[i + 2 .. i + 6]) |h| {
        const d: u21 = switch (h) {
            '0'...'9' => h - '0',
            'a'...'f' => h - 'a' + 10,
            'A'...'F' => h - 'A' + 10,
            else => return null,
        };
        cp = cp * 16 + d;
    }
    return .{ .cp = cp, .len = 6 };
}

pub inline fn isIdentStartRune(cp: u21) bool {
    return if (cp < 0x80) simd.isIdentStart(@intCast(cp)) else unicode.isIdStart(cp);
}

pub inline fn isIdentPartRune(cp: u21) bool {
    return if (cp < 0x80) simd.isIdentPart(@intCast(cp)) else unicode.isIdContinue(cp);
}

/// 标识符。ASCII 段走快路径（标量 8 字节 + SIMD 续扫），
/// 遇非 ASCII 字节按 UTF-8 解码查 ID_Continue 两级位图续扫。
/// 关键字不在这里判别（粗流全归 identifier；判别只在 `/` 路径按需做）。
pub fn scanIdentifier(src: []const u8, start: usize) Scan {
    // 首字符合法性由分发保证（ASCII ident start、已验证的非 ASCII
    // ID_Start、或已验证的 \uXXXX 转义）；按实际宽度推进，不能假设 +1
    var i = if (src[start] == '\\') start + 6 else if (src[start] < 0x80) start + 1 else start + unicode.decode(src, start).?.len;
    while (i < src.len) {
        const c = src[i];
        if (c == '\\') {
            // \uXXXX 转义：解码后按码点判定（$ _ 等 ASCII 转义合法）
            const r = decodeIdentEscape(src, i) orelse break;
            if (!isIdentPartRune(r.cp)) break;
            i += 6;
            continue;
        }
        if (c < 0x80) {
            i = asciiIdentEnd(src, i);
            if (i < src.len and src[i] >= 0x80) continue;
            break;
        }
        const r = unicode.decode(src, i) orelse break;
        if (!unicode.isIdContinue(r.cp)) break;
        i += r.len;
    }
    return .{ .kind = .identifier, .end = i };
}

/// 非 ASCII 起始标识符的扫描：首字符已由 scanNonAscii decode 并验证
/// ID_Start（直接复用，不再二次 decode）。入口固定成本是 CJK
/// 标识符密集语料的吞吐关键（oxc 同款结构：handler 直达 + 单 decode）。
fn scanUnicodeIdentifier(src: []const u8, start: usize, first: unicode.Rune) Scan {
    var i = start + first.len;
    while (i < src.len) {
        const c = src[i];
        if (c == '\\') {
            const r = decodeIdentEscape(src, i) orelse break;
            if (!isIdentPartRune(r.cp)) break;
            i += 6;
            continue;
        }
        if (c < 0x80) {
            i = asciiIdentEnd(src, i);
            if (i < src.len and src[i] >= 0x80) continue;
            break;
        }
        const r = unicode.decode(src, i) orelse break;
        if (!unicode.isIdContinue(r.cp)) break;
        i += r.len;
    }
    return .{ .kind = .identifier, .end = i };
}

/// ASCII 标识符字符段的结尾：标量快扫前 8 字节（多数标识符不长），
/// 更长才 SIMD 续扫（`@ctz(~identPartMask)` 直接给出结尾偏移）。
/// 遇非 ASCII 字节即停（由调用方走 unicode 路径）。
fn asciiIdentEnd(src: []const u8, from: usize) usize {
    var i = from;
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
    return i;
}

/// 数字字面量：0x/0o/0b、十进制、小数、指数、`_` 分隔符、BigInt `n` 后缀。
/// 标量实现：数字 lexeme 平均只有几字节，SIMD 收益存疑，先求正确。
/// TODO: legacy 八进制、空十六进制 `0x`、指数无数字 `1.e`、`3in` 等
/// 非法形态按容错策略产出 lexeme（边界近似 tsc），不产语义错误标记（goals.md L3）。
pub fn scanNumber(src: []const u8, start: usize) Scan {
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
    return .{ .kind = .number, .end = i };
}

/// 正则字面量 `/pattern/flags`：不能跨行，字符类 `[...]` 里的 `/` 不算结束。
pub fn scanRegex(src: []const u8, start: usize) Scan {
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
            return .{ .kind = .regex, .end = i };
        }
        i += 1;
    }
    // 失败：吞到行尾当 illegal，容错继续
    return illegalRegex(src, start);
}

/// punctuator，最长匹配（4→3→2→1）。
/// 主体路径一次 4 字节加载（无逐字节边界检查），文件尾不足 4 字节走慢版。
pub fn scanPunct(src: []const u8, start: usize) Scan {
    const len = if (start + 4 <= src.len)
        punctLenW(std.mem.readInt(u32, src[start..][0..4], .little))
    else
        punctLen(src[start..]);
    return .{ .kind = .punct, .end = start + len };
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

pub fn scanShebang(src: []const u8) Scan {
    return .{ .kind = .shebang, .end = lineEnd(src, 0) };
}

/// 非 ASCII 字节：Unicode whitespace 置 ws 标记（驱动循环跳过并顺带
/// 检测行终止符，不落盘）；ID_Start 产标识符；其余按完整 UTF-8 码点
/// 消费成 illegal，避免中文注释碎成一堆单字节 illegal。
fn scanNonAscii(src: []const u8, start: usize) Scan {
    @branchHint(.unlikely);
    // Unicode whitespace（含跨块码点）：内部信号，不进交付流
    if (simd.unicodeWhitespaceLen(src, start)) |len| {
        return .{ .kind = .illegal, .end = start + len, .ws = true };
    }
    // Unicode 标识符首字符（ID_Start）
    if (unicode.decode(src, start)) |r| {
        if (unicode.isIdStart(r.cp)) return scanUnicodeIdentifier(src, start, r);
    }
    const len = @min(utf8Len(src[start]), src.len - start);
    return .{ .kind = .illegal, .end = start + len };
}

// 容错路径统一收进冷函数：@branchHint(.unlikely) 等价 cold attribute，
// 编译器把代码放进 cold 段并让调用点按 unlikely 预测。

fn unterminatedBlockComment(src: []const u8) Scan {
    @branchHint(.unlikely);
    return .{ .kind = .illegal, .end = src.len };
}

fn illegalString(end: usize) Scan {
    @branchHint(.unlikely);
    return .{ .kind = .illegal, .end = end };
}

fn illegalBackslash(start: usize) Scan {
    @branchHint(.unlikely);
    return .{ .kind = .illegal, .end = start + 1 };
}

fn illegalRegex(src: []const u8, start: usize) Scan {
    @branchHint(.unlikely);
    return .{ .kind = .illegal, .end = lineEnd(src, start) };
}

/// `/` 出现在什么 lexeme 之后时是正则开头，否则是除号。
/// 双 lexeme 回看的启发式，按真实代码的先验取舍，不追语法完备：
/// - 值类 lexeme（标识符/数字/字符串/模板整体/模板尾片/正则）之后是除号；
/// - `++`/`--` 之后是除号：前缀形式要求左值，`++/re/` 本就是错误代码，
///   真实代码里只能是后缀，而后缀之后接除法；
/// - `}` 之后是正则：块尾开新语句常见，`{...} / x` 对象除法在语义上无意义；
/// - `)`/`]` 之后是除号：`if (x) /re/.test(y)` 这类无副作用的正则方法
///   调用作为单独语句，真实代码里几乎不出现；
/// - 关键字里 this/super 是值，return/typeof/case 等都把 `/` 放进表达式位置
///   （粗流不分 keyword/identifier，这里按文本现查——只在 `/` 路径上付一次）；
/// - 名字位置的关键字不是关键字：`x.return`、`x?.return`、`this.#return`
///   是属性/私有名（prev2 ∈ {`.`、`?.`、`#`}），后跟除号。
pub fn regexAllowedAfter(prev_kind: ?LexemeKind, prev_text: []const u8, prev2_text: []const u8) bool {
    const kind = prev_kind orelse return true; // 文件开头
    return switch (kind) {
        .identifier => blk: {
            if (!isKeyword(prev_text)) break :blk false;
            // this/super 是值；其余关键字（return/typeof/in/...）把 `/` 放进表达式位置
            if (std.mem.eql(u8, prev_text, "this") or std.mem.eql(u8, prev_text, "super")) break :blk false;
            // 名字位置（属性/私有名）的关键字是值
            if (std.mem.eql(u8, prev2_text, ".") or std.mem.eql(u8, prev2_text, "?.") or
                std.mem.eql(u8, prev2_text, "#")) break :blk false;
            break :blk true;
        },
        .number, .string, .regex, .no_substitution_template, .template_tail => false,
        .punct => blk: {
            // ++/-- 走除号侧（见上）；其余 punctuator（= ( , : + 等运算符）都在表达式位置
            break :blk prev_text[0] != ')' and prev_text[0] != ']' and
                !std.mem.eql(u8, prev_text, "++") and !std.mem.eql(u8, prev_text, "--");
        },
        // template_head/middle（`${` 后是表达式位置）、shebang、illegal
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
        // '{' '}' '(' ')' '[' ']' ';' ',' ':' '~' '@' '#' 等单字符
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
pub fn skipQuoted(src: []const u8, quote_at: usize) usize {
    const quote = src[quote_at];
    var i = quote_at + 1;
    while (i < src.len) {
        if (src[i] == '\\') {
            // `\`+CRLF 行继续跳 3 字节（同 scanString）
            if (i + 2 < src.len and src[i + 1] == '\r' and src[i + 2] == '\n') {
                i += 3;
            } else {
                i += 2;
            }
            continue;
        }
        if (src[i] == quote or src[i] == '\n' or src[i] == '\r') return i + 1;
        i += 1;
    }
    return i;
}

/// 找行终止符（\n、\r、U+2028/U+2029）的位置：行注释/shebang/非法恢复
/// 的终点。此前只找 \n——孤立 \r 与 U+2028/29 同为 spec 行终止符，
/// 行注释与非法字符串应在它们处收尾（tsc 同口径；顺带统一了三变体
/// newline_before flag 的口径：注释体按构造不含行终止符）。
/// SIMD 定位候选字节（\n|\r|0xE2），0xE2 标量确证 E2 80 A8/A9。
pub fn lineEnd(src: []const u8, from: usize) usize {
    var i = from;
    while (i < src.len) {
        if (src.len - i >= simd.block_size) {
            const chunk = simd.load(src, i);
            const cand = simd.newlineMask(chunk) |
                @as(simd.Mask, @bitCast(chunk == @as(simd.Chunk, @splat('\r')))) |
                @as(simd.Mask, @bitCast(chunk == @as(simd.Chunk, @splat(0xE2))));
            if (cand == 0) {
                i += simd.block_size;
                continue;
            }
            const idx = i + @as(usize, @ctz(cand));
            if (src[idx] != 0xE2) return idx;
            // U+2028/U+2029 = E2 80 A8/A9（跨块悬挂由逐字节路径兜底）
            if (idx + 2 < src.len and src[idx + 1] == 0x80 and
                (src[idx + 2] == 0xA8 or src[idx + 2] == 0xA9)) return idx;
            i = idx + 1;
            continue;
        }
        const c = src[i];
        if (c == '\n' or c == '\r') return i;
        if (c == 0xE2 and i + 2 < src.len and src[i + 1] == 0x80 and
            (src[i + 2] == 0xA8 or src[i + 2] == 0xA9)) return i;
        i += 1;
    }
    return i;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

/// (kind, text) 二元组，方便写期望序列
const Expected = struct { LexemeKind, []const u8 };

/// 比对 lexeme 序列（交付流不含 trivia，直接全流比对）
fn expectTokens(src: []const u8, expected: []const Expected) !void {
    var result = try scan(testing.allocator, src);
    defer result.deinit(testing.allocator);
    const actual = result.tokens;
    if (actual.len != expected.len) {
        std.debug.print("\nsrc: {s}\n期望 {d} 个 lexeme，实际 {d} 个：\n", .{
            src, expected.len, actual.len,
        });
        for (actual) |t| {
            std.debug.print("  ({s}, \"{s}\")\n", .{ @tagName(t.kind), t.slice(src) });
        }
        return error.TestTokenCountMismatch;
    }
    for (expected, actual, 0..) |e, t, i| {
        if (e[0] != t.kind or !std.mem.eql(u8, e[1], t.slice(src))) {
            std.debug.print(
                "\nsrc: {s}\n第 {d} 个 lexeme 不符：期望 ({s}, \"{s}\")，实际 ({s}, \"{s}\")\n",
                .{ src, i, @tagName(e[0]), e[1], @tagName(t.kind), t.slice(src) },
            );
            return error.TestTokenMismatch;
        }
    }
}

/// 各偏移处 lexeme 的 newline_before flag 断言：{start, 期望 flag}
fn expectNewlineFlags(src: []const u8, expected: []const struct { u32, bool }) !void {
    var result = try scan(testing.allocator, src);
    defer result.deinit(testing.allocator);
    for (expected) |e| {
        const start = e[0];
        var found = false;
        for (result.tokens) |t| {
            if (t.start == start) {
                try testing.expectEqual(e[1], t.newlineBefore());
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("\nsrc: {s}\n没有 start == {d} 的 lexeme：\n", .{ src, start });
            for (result.tokens) |t| {
                std.debug.print("  ({s}, \"{s}\") flags={b}\n", .{ @tagName(t.kind), t.slice(src), t.flags });
            }
            return error.TestTokenMismatch;
        }
    }
}

test "声明与表达式" {
    try expectTokens("let x = 42;", &.{
        .{ .identifier, "let" },
        .{ .identifier, "x" },
        .{ .punct, "=" },
        .{ .number, "42" },
        .{ .punct, ";" },
        .{ .eof, "" },
    });
}

test "关键字全归 identifier" {
    try expectTokens("class impl extends Base {", &.{
        .{ .identifier, "class" },
        .{ .identifier, "impl" },
        .{ .identifier, "extends" },
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

test "字符串行继续（L2 修复：\\ + CRLF 不再截断）" {
    // `\`+CRLF 是合法 LineContinuation：此前只跳 2 字节（\ 与 \r），随后的
    // \n 命中 stop mask 被当裸换行，合法字符串被截断为 illegal
    try expectTokens("\"ab\\\r\ncd\" + e", &.{
        .{ .string, "\"ab\\\r\ncd\"" },
        .{ .punct, "+" },
        .{ .identifier, "e" },
        .{ .eof, "" },
    });
    // `\`+孤立 \r 同样是行继续（跳 2 字节）
    try expectTokens("\"ab\\\rcd\"", &.{
        .{ .string, "\"ab\\\rcd\"" },
        .{ .eof, "" },
    });
    // `\`+LF（原有行为不变）
    try expectTokens("\"ab\\\ncd\"", &.{
        .{ .string, "\"ab\\\ncd\"" },
        .{ .eof, "" },
    });
    // 行继续后字符串未闭合仍按 illegal 容错
    try expectTokens("\"ab\\\r\ncd", &.{
        .{ .illegal, "\"ab\\\r\ncd" },
        .{ .eof, "" },
    });
}

test "模板字面量拆片（含子表达式与换行）" {
    try expectTokens(
        "const s = `hi ${name + \"!\"}\nnext`;",
        &.{
            .{ .identifier, "const" },
            .{ .identifier, "s" },
            .{ .punct, "=" },
            .{ .template_head, "`hi ${" },
            .{ .identifier, "name" },
            .{ .punct, "+" },
            .{ .string, "\"!\"" },
            .{ .template_tail, "}\nnext`" },
            .{ .punct, ";" },
            .{ .eof, "" },
        },
    );
    // 无子表达式模板整体一片
    try expectTokens("`plain`", &.{
        .{ .no_substitution_template, "`plain`" },
        .{ .eof, "" },
    });
    // 多段子表达式：head / middle / tail
    try expectTokens("`a${x}b${y}c`", &.{
        .{ .template_head, "`a${" },
        .{ .identifier, "x" },
        .{ .template_middle, "}b${" },
        .{ .identifier, "y" },
        .{ .template_tail, "}c`" },
        .{ .eof, "" },
    });
}

test "模板子表达式里的正则（回归：pattern 里的 //、/*、} 不再骗过配对）" {
    // 回归：typescript.min.js 实测抓到的形态——子表达式内正则里的 `//` 被
    // 当行注释，吞掉模板收尾反引号，整个模板塌成 illegal 直到 EOF
    try expectTokens("` ${r.replace(/\\*\\//g,\"*_/\")} `", &.{
        .{ .template_head, "` ${" },
        .{ .identifier, "r" },
        .{ .punct, "." },
        .{ .identifier, "replace" },
        .{ .punct, "(" },
        .{ .regex, "/\\*\\//g" },
        .{ .punct, "," },
        .{ .string, "\"*_/\"" },
        .{ .punct, ")" },
        .{ .template_tail, "} `" },
        .{ .eof, "" },
    });
    // 正则 pattern 含 `}`（旧已知限制 tradeoff L1，模板栈根治）
    try expectTokens("`a${ /}/.test(x) }b`", &.{
        .{ .template_head, "`a${" },
        .{ .regex, "/}/" },
        .{ .punct, "." },
        .{ .identifier, "test" },
        .{ .punct, "(" },
        .{ .identifier, "x" },
        .{ .punct, ")" },
        .{ .template_tail, "}b`" },
        .{ .eof, "" },
    });
    // URL 正则：pattern 里的 `//` 不再吞行
    try expectTokens("` ${u.match(/https?:\\/\\//)} `", &.{
        .{ .template_head, "` ${" },
        .{ .identifier, "u" },
        .{ .punct, "." },
        .{ .identifier, "match" },
        .{ .punct, "(" },
        .{ .regex, "/https?:\\/\\//" },
        .{ .punct, ")" },
        .{ .template_tail, "} `" },
        .{ .eof, "" },
    });
    // 子表达式里的除法不能反被误判成正则吞掉收尾反引号
    try expectTokens("` ${x/y}` + /re/g", &.{
        .{ .template_head, "` ${" },
        .{ .identifier, "x" },
        .{ .punct, "/" },
        .{ .identifier, "y" },
        .{ .template_tail, "}`" },
        .{ .punct, "+" },
        .{ .regex, "/re/g" },
        .{ .eof, "" },
    });
    // 嵌套模板 + 内层子表达式的正则（pattern 为 // 本身）
    try expectTokens("`a${ `b${ /\\/\\// }c` }d`", &.{
        .{ .template_head, "`a${" },
        .{ .template_head, "`b${" },
        .{ .regex, "/\\/\\//" },
        .{ .template_tail, "}c`" },
        .{ .template_tail, "}d`" },
        .{ .eof, "" },
    });
    // 子表达式里的对象字面量：花括号配对照常
    try expectTokens("` ${({a:1}).a} `", &.{
        .{ .template_head, "` ${" },
        .{ .punct, "(" },
        .{ .punct, "{" },
        .{ .identifier, "a" },
        .{ .punct, ":" },
        .{ .number, "1" },
        .{ .punct, "}" },
        .{ .punct, ")" },
        .{ .punct, "." },
        .{ .identifier, "a" },
        .{ .template_tail, "} `" },
        .{ .eof, "" },
    });
    // 未闭合：head 已产出，流按既有 lexeme 收尾（容错不中断）
    try expectTokens("` ${x", &.{
        .{ .template_head, "` ${" },
        .{ .identifier, "x" },
        .{ .eof, "" },
    });
}

test "模板栈帧与 middle 不压栈（回归：模板结束后的普通 } 不被误扫成 template_tail）" {
    // 多段模板后跟块收尾 `}`：middle 若多压帧会残留孤帧，这个 `}` 会被
    // 当成模板续片吞到下一个反引号（typescript.js/checker.ts 实测抓回）
    try expectTokens("{ x = `a${y}b${z}c`; }", &.{
        .{ .punct, "{" },
        .{ .identifier, "x" },
        .{ .punct, "=" },
        .{ .template_head, "`a${" },
        .{ .identifier, "y" },
        .{ .template_middle, "}b${" },
        .{ .identifier, "z" },
        .{ .template_tail, "}c`" },
        .{ .punct, ";" },
        .{ .punct, "}" },
        .{ .eof, "" },
    });
    // 模板文本里的单引号没有特殊含义：'${' 仍是子表达式起点（tsc 同口径）
    try expectTokens("f(`a '${x}'`) }", &.{
        .{ .identifier, "f" },
        .{ .punct, "(" },
        .{ .template_head, "`a '${" },
        .{ .identifier, "x" },
        .{ .template_tail, "}'`" },
        .{ .punct, ")" },
        .{ .punct, "}" },
        .{ .eof, "" },
    });
    // 嵌套模板逐层弹帧后，外层之后的 `}` 照常
    try expectTokens("{ `a${ `b${x}c` }d`; }", &.{
        .{ .punct, "{" },
        .{ .template_head, "`a${" },
        .{ .template_head, "`b${" },
        .{ .identifier, "x" },
        .{ .template_tail, "}c`" },
        .{ .template_tail, "}d`" },
        .{ .punct, ";" },
        .{ .punct, "}" },
        .{ .eof, "" },
    });
}

test "模板 ${} 内的正则在主流中（regex_starts 旁路已随拆片删除）" {
    // bench 驱动 yuku 的正则起点集合直接取自主流（曾靠旁路收集，因为
    // 模板整体一个 token；拆片后内部 token 全在主流）
    try expectTokens("a/b; `x${ /c/ }y${ `z${ /d/ }w` }v`; /e/g", &.{
        .{ .identifier, "a" },
        .{ .punct, "/" },
        .{ .identifier, "b" },
        .{ .punct, ";" },
        .{ .template_head, "`x${" },
        .{ .regex, "/c/" },
        .{ .template_middle, "}y${" },
        .{ .template_head, "`z${" },
        .{ .regex, "/d/" },
        .{ .template_tail, "}w`" },
        .{ .template_tail, "}v`" },
        .{ .punct, ";" },
        .{ .regex, "/e/g" },
        .{ .eof, "" },
    });
}

test "注释跳过但不进 prev（trivia 不落盘）" {
    try expectTokens("a // line\n/* block */ b", &.{
        .{ .identifier, "a" },
        .{ .identifier, "b" },
        .{ .eof, "" },
    });
    // 注释不影响 `/` 判别：prev 仍是注释前的 return → 正则
    try expectTokens("return /* c */ /x/", &.{
        .{ .identifier, "return" },
        .{ .regex, "/x/" },
        .{ .eof, "" },
    });
}

test "newline_before flag（trivia 不落盘，换行压成 1 bit）" {
    // 空白 run 含换行
    try expectNewlineFlags("a \n b", &.{ .{ 0, false }, .{ 4, true } });
    // 无换行的空白 run
    try expectNewlineFlags("a \t b", &.{ .{ 0, false }, .{ 4, false } });
    // CRLF / 孤立 \r
    try expectNewlineFlags("a\r\nb", &.{ .{ 0, false }, .{ 3, true } });
    try expectNewlineFlags("a\rb", &.{ .{ 0, false }, .{ 2, true } });
    // \v \f 是空白不是行终止符
    try expectNewlineFlags("a\x0b\x0cb", &.{ .{ 0, false }, .{ 3, false } });
    // 行注释结尾的换行归后续 gap
    try expectNewlineFlags("a // c\nb", &.{ .{ 0, false }, .{ 7, true } });
    // 块注释内部的换行（跨行注释）
    try expectNewlineFlags("a /* x\ny */ b", &.{ .{ 0, false }, .{ 12, true } });
    try expectNewlineFlags("a /* xy */ b", &.{ .{ 0, false }, .{ 11, false } });
    // Unicode whitespace：U+2028 是行终止符，U+00A0 不是
    try expectNewlineFlags("a \xe2\x80\xa8b", &.{ .{ 0, false }, .{ 5, true } });
    try expectNewlineFlags("a\xc2\xa0b", &.{ .{ 0, false }, .{ 3, false } });
    // shebang 自身无 flag，其后 lexeme 有
    try expectNewlineFlags("#!/usr/bin/env node\nx", &.{ .{ 0, false }, .{ 20, true } });
    // 行注释在孤立 \r / U+2028 处收尾（spec 行终止符；tsc 同口径），
    // 后续字节的 flag 由 ws run 给出
    try expectTokens("// a\rb", &.{
        .{ .identifier, "b" },
        .{ .eof, "" },
    });
    try expectTokens("// a\xe2\x80\xa8b", &.{
        .{ .identifier, "b" },
        .{ .eof, "" },
    });
    try expectNewlineFlags("// a\rb", &.{.{ 5, true }});
    try expectNewlineFlags("// a\xe2\x80\xa8b", &.{.{ 7, true }});
    // 文件开头的换行置 flag；尾部换行归 eof
    try expectNewlineFlags("\na \n", &.{ .{ 1, true }, .{ 4, true } });
    // 模板文本内部的换行不算（在 lexeme 体内不在 trivia）
    try expectNewlineFlags("`a\n${x}\n`", &.{ .{ 0, false }, .{ 5, false }, .{ 6, false } });
}

test "正则 vs 除法：名字位置的关键字（prev2 判别）" {
    // x.return / v：属性名不是关键字，`/` 判除号（回归：曾被误判正则塌成 illegal）
    try expectTokens("x.return / v", &.{
        .{ .identifier, "x" },
        .{ .punct, "." },
        .{ .identifier, "return" },
        .{ .punct, "/" },
        .{ .identifier, "v" },
        .{ .eof, "" },
    });
    // 可选链同理（?. 是独立 punct）
    try expectTokens("x?.if / v", &.{
        .{ .identifier, "x" },
        .{ .punct, "?." },
        .{ .identifier, "if" },
        .{ .punct, "/" },
        .{ .identifier, "v" },
        .{ .eof, "" },
    });
    // 私有名允许保留字：this.#return /2/ v 是两次除法
    try expectTokens("this.#return /2/ v", &.{
        .{ .identifier, "this" },
        .{ .punct, "." },
        .{ .punct, "#" },
        .{ .identifier, "return" },
        .{ .punct, "/" },
        .{ .number, "2" },
        .{ .punct, "/" },
        .{ .identifier, "v" },
        .{ .eof, "" },
    });
    // 名字位置之外照常：return 后是正则；x.this 是值跟除号
    try expectTokens("return /x/", &.{
        .{ .identifier, "return" },
        .{ .regex, "/x/" },
        .{ .eof, "" },
    });
    try expectTokens("x.this / v", &.{
        .{ .identifier, "x" },
        .{ .punct, "." },
        .{ .identifier, "this" },
        .{ .punct, "/" },
        .{ .identifier, "v" },
        .{ .eof, "" },
    });
}

test "正则 vs 除法" {
    try expectTokens("var re = /a\\/b/g;", &.{
        .{ .identifier, "var" },
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
        .{ .identifier, "return" },
        .{ .regex, "/x/" },
        .{ .punct, "." },
        .{ .identifier, "test" },
        .{ .punct, "(" },
        .{ .identifier, "s" },
        .{ .punct, ")" },
        .{ .eof, "" },
    });
    // 关键字判别挪进 `/` 路径：this 是值（除号），return 后是表达式（正则）
    try expectTokens("this / x", &.{
        .{ .identifier, "this" },
        .{ .punct, "/" },
        .{ .identifier, "x" },
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
        .{ .identifier, "if" },
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
        .{ .identifier, "if" },
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
    // 模板尾片是值 → 除号
    try expectTokens("`a${x}` / y", &.{
        .{ .template_head, "`a${" },
        .{ .identifier, "x" },
        .{ .template_tail, "}`" },
        .{ .punct, "/" },
        .{ .identifier, "y" },
        .{ .eof, "" },
    });
}

test "尾部空白与 eof" {
    // 末行换行不是候选起点，eof 仍须 start == src.len（曾出过 end 落在
    // 最后一个 lexeme 末尾、slice 越界 panic 的 bug）
    try expectTokens("a\n", &.{
        .{ .identifier, "a" },
        .{ .eof, "" },
    });
    try expectTokens("a  \n", &.{
        .{ .identifier, "a" },
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
    // ☃（U+2603）不是标识符字符：整码点消费成一个 illegal
    try expectTokens("a ☃ b", &.{
        .{ .identifier, "a" },
        .{ .illegal, "☃" },
        .{ .identifier, "b" },
        .{ .eof, "" },
    });
}

test "unicode 标识符（ID_Start/ID_Continue）" {
    // 中文、希腊字母是 ID_Start，整体一个 identifier lexeme
    try expectTokens("let 变量 = 1;", &.{
        .{ .identifier, "let" },
        .{ .identifier, "变量" },
        .{ .punct, "=" },
        .{ .number, "1" },
        .{ .punct, ";" },
        .{ .eof, "" },
    });
    try expectTokens("let π = 3.14;", &.{
        .{ .identifier, "let" },
        .{ .identifier, "π" },
        .{ .punct, "=" },
        .{ .number, "3.14" },
        .{ .punct, ";" },
        .{ .eof, "" },
    });
    // ASCII 与 unicode 字符混排仍是一个标识符
    try expectTokens("xπy_中 = 1", &.{
        .{ .identifier, "xπy_中" },
        .{ .punct, "=" },
        .{ .number, "1" },
        .{ .eof, "" },
    });
    // 非 ID_Continue 的 unicode 字符终止标识符。☃ 本身被静默跳过
    // （boundary v2 把非 ws 非 ASCII 一律按 ID-like 连接，ident 后的
    // 非 ident 非 ASCII 不是候选起点）——这是设计文档「只保证合法源码」
    // 假设下的已知容错差异；☃ 裸用本就是非法 JS
    try expectTokens("变量☃ = 1", &.{
        .{ .identifier, "变量" },
        .{ .punct, "=" },
        .{ .number, "1" },
        .{ .eof, "" },
    });
    // unicode 私有名：`#` 与标识符两个 lexeme
    try expectTokens("this.#π", &.{
        .{ .identifier, "this" },
        .{ .punct, "." },
        .{ .punct, "#" },
        .{ .identifier, "π" },
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
    var result = try scan(testing.allocator, src);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 5), try result.lineCount());
}

test "shebang" {
    try expectTokens("#!/usr/bin/env node\nx", &.{
        .{ .shebang, "#!/usr/bin/env node" },
        .{ .identifier, "x" },
        .{ .eof, "" },
    });
}

test "`#` 恒为单字节 punct（合法性留 parser）" {
    try expectTokens("this.#x", &.{
        .{ .identifier, "this" },
        .{ .punct, "." },
        .{ .punct, "#" },
        .{ .identifier, "x" },
        .{ .eof, "" },
    });
    try expectTokens("#priv in obj;", &.{
        .{ .punct, "#" },
        .{ .identifier, "priv" },
        .{ .identifier, "in" },
        .{ .identifier, "obj" },
        .{ .punct, ";" },
        .{ .eof, "" },
    });
    // 裸 `#`（后不跟标识符起始）：原 1 字节 illegal，现统一 punct
    try expectTokens("a # b", &.{
        .{ .identifier, "a" },
        .{ .punct, "#" },
        .{ .identifier, "b" },
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

test "Unicode whitespace（U+00A0/U+3000/FEFF）是 trivia 不再 illegal" {
    // U+00A0（块内完整）：跳过不落盘
    try expectTokens("a\xc2\xa0b", &.{
        .{ .identifier, "a" },
        .{ .identifier, "b" },
        .{ .eof, "" },
    });
    // U+3000 全角空格
    try expectTokens("x\xe3\x80\x80y", &.{
        .{ .identifier, "x" },
        .{ .identifier, "y" },
        .{ .eof, "" },
    });
    // U+FEFF BOM 式空白
    try expectTokens("\xef\xbb\xbfa=1", &.{
        .{ .identifier, "a" },
        .{ .punct, "=" },
        .{ .number, "1" },
        .{ .eof, "" },
    });
}

test "跨块的 Unicode whitespace 走兜底路径" {
    // 30 个 ident 字节 + `(`（punct 收尾）+ C2 恰在块尾、A0 在下一块首，
    // 分类 pass 只修正块内完整码点，这个跨块码点由阶段 2 兜底跳过
    var buf: [64]u8 = undefined;
    @memset(buf[0..30], 'a');
    buf[30] = '(';
    buf[31] = 0xC2;
    buf[32] = 0xA0;
    buf[33] = 'b';
    const src = buf[0..34];
    try expectTokens(src, &.{
        .{ .identifier, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
        .{ .punct, "(" },
        .{ .identifier, "b" },
        .{ .eof, "" },
    });
}

test "逻辑换行：U+2028/U+2029 与孤立 \\r" {
    // U+2028 是行终止符
    {
        var result = try scan(testing.allocator, "a\xe2\x80\xa8b");
        defer result.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 2), try result.lineCount());
    }
    // U+2029 同样
    {
        var result = try scan(testing.allocator, "a\xe2\x80\xa9b");
        defer result.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 2), try result.lineCount());
    }
    // 孤立 \r 计一次
    {
        var result = try scan(testing.allocator, "a\rb");
        defer result.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 2), try result.lineCount());
    }
    // CRLF 只计一次
    {
        var result = try scan(testing.allocator, "a\r\nb");
        defer result.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 2), try result.lineCount());
    }
}

test "OP 连接关系：多字节 punctuator lexeme 流不受影响" {
    try expectTokens("a%=b;a==b;a<=b;a&&b;a**b;a??b;a|=b", &.{
        .{ .identifier, "a" }, .{ .punct, "%=" }, .{ .identifier, "b" }, .{ .punct, ";" },
        .{ .identifier, "a" }, .{ .punct, "==" }, .{ .identifier, "b" }, .{ .punct, ";" },
        .{ .identifier, "a" }, .{ .punct, "<=" }, .{ .identifier, "b" }, .{ .punct, ";" },
        .{ .identifier, "a" }, .{ .punct, "&&" }, .{ .identifier, "b" }, .{ .punct, ";" },
        .{ .identifier, "a" }, .{ .punct, "**" }, .{ .identifier, "b" }, .{ .punct, ";" },
        .{ .identifier, "a" }, .{ .punct, "??" }, .{ .identifier, "b" }, .{ .punct, ";" },
        .{ .identifier, "a" }, .{ .punct, "|=" }, .{ .identifier, "b" }, .{ .eof, "" },
    });
}

test "中文是标识符字符（unicode 标识符支持后的行为变化）" {
    // 此前中文按码点消费成 illegal；ID_Start/ID_Continue 支持后是 identifier
    try expectTokens("a 中 b", &.{
        .{ .identifier, "a" },
        .{ .identifier, "中" },
        .{ .identifier, "b" },
        .{ .eof, "" },
    });
}

test "模板子表达式：嵌套模板与注释里的 } 不干扰平衡" {
    // 嵌套模板文本里的 `}` 与反引号
    try expectTokens("x = `a${ `b}c` }d`;", &.{
        .{ .identifier, "x" },
        .{ .punct, "=" },
        .{ .template_head, "`a${" },
        .{ .no_substitution_template, "`b}c`" },
        .{ .template_tail, "}d`" },
        .{ .punct, ";" },
        .{ .eof, "" },
    });
    // 块注释里的 `}`（注释是 trivia，不进花括号计数）
    try expectTokens("x = `a${ /* } ` */ 1 }d`;", &.{
        .{ .identifier, "x" },
        .{ .punct, "=" },
        .{ .template_head, "`a${" },
        .{ .number, "1" },
        .{ .template_tail, "}d`" },
        .{ .punct, ";" },
        .{ .eof, "" },
    });
    // 行注释同理（吞到行尾，注释内的 `}` 与反引号都不见）
    try expectTokens("x = `a${ // }`\n1 }d`;", &.{
        .{ .identifier, "x" },
        .{ .punct, "=" },
        .{ .template_head, "`a${" },
        .{ .number, "1" },
        .{ .template_tail, "}d`" },
        .{ .punct, ";" },
        .{ .eof, "" },
    });
    // 子表达式里的字符串已有覆盖，保持
    try expectTokens("x = `a${ \"}\" }d`;", &.{
        .{ .identifier, "x" },
        .{ .punct, "=" },
        .{ .template_head, "`a${" },
        .{ .string, "\"}\"" },
        .{ .template_tail, "}d`" },
        .{ .punct, ";" },
        .{ .eof, "" },
    });
}

test "行号索引 lineAt（逻辑换行：\\n、CRLF、孤立 \\r、U+2028）" {
    const src = "a\nb\r\nc\rd\u{2028}e";
    // 布局：a@0 \n@1 b@2 \r@3 \n@4 c@5 \r@6 d@7 U+2028@8..10 e@11
    var result = try scan(testing.allocator, src);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 5), try result.lineCount());
    try testing.expectEqual(@as(usize, 5), try result.lines.lineCount());
    try testing.expectEqual(@as(usize, 1), try result.lines.lineAt(0)); // a
    try testing.expectEqual(@as(usize, 2), try result.lines.lineAt(2)); // b（\n 后）
    try testing.expectEqual(@as(usize, 3), try result.lines.lineAt(5)); // c（\r\n 后只计一次）
    try testing.expectEqual(@as(usize, 4), try result.lines.lineAt(7)); // d（孤立 \r 后）
    try testing.expectEqual(@as(usize, 5), try result.lines.lineAt(11)); // e（U+2028 后）
    // 换行字节自身仍属于上一行
    try testing.expectEqual(@as(usize, 1), try result.lines.lineAt(1));
    // 越界 offset 归到最后一行
    try testing.expectEqual(@as(usize, 5), try result.lines.lineAt(99));
    // 与 lexeme 流交叉验证
    for (result.tokens) |t| {
        try testing.expect(try result.lines.lineAt(t.start) <= try result.lineCount());
    }
}

test "行号索引：空文件与单行" {
    {
        var result = try scan(testing.allocator, "");
        defer result.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), try result.lines.lineAt(0));
    }
    {
        var result = try scan(testing.allocator, "let x = 1;");
        defer result.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), try result.lineCount());
        for (result.tokens) |t| {
            try testing.expectEqual(@as(usize, 1), try result.lines.lineAt(t.start));
        }
    }
}

test "\\uXXXX 转义标识符" {
    // 基本形式与后接 ASCII/中文
    try expectTokens("let \\u0041bc = 1;", &.{
        .{ .identifier, "let" },
        .{ .identifier, "\\u0041bc" },
        .{ .punct, "=" },
        .{ .number, "1" },
        .{ .punct, ";" },
        .{ .eof, "" },
    });
    // 转义的 $ 和 _（ASCII 合法标识符字符）
    try expectTokens("let \\u0024\\u005F = 1;", &.{
        .{ .identifier, "let" },
        .{ .identifier, "\\u0024\\u005F" },
        .{ .punct, "=" },
        .{ .number, "1" },
        .{ .punct, ";" },
        .{ .eof, "" },
    });
    // 转义出现在中间
    try expectTokens("a\\u0042c = 1", &.{
        .{ .identifier, "a\\u0042c" },
        .{ .punct, "=" },
        .{ .number, "1" },
        .{ .eof, "" },
    });
    // 私有名转义：`#` 与转义标识符两个 lexeme
    try expectTokens("this.#\\u0041;", &.{
        .{ .identifier, "this" },
        .{ .punct, "." },
        .{ .punct, "#" },
        .{ .identifier, "\\u0041" },
        .{ .punct, ";" },
        .{ .eof, "" },
    });
    // 坏转义：\ 消费 1 字节 illegal，u00ZZ 是普通标识符（对齐 tsc 边界）
    try expectTokens("let \\u00ZZ = 1;", &.{
        .{ .identifier, "let" },
        .{ .illegal, "\\" },
        .{ .identifier, "u00ZZ" },
        .{ .punct, "=" },
        .{ .number, "1" },
        .{ .punct, ";" },
        .{ .eof, "" },
    });
    // \u{...} 形式不合并（对齐 tsc 纯 scanner）：\ 为 illegal，
    // u、{...} 按普通 lexeme
    try expectTokens("let \\u{41} = 1;", &.{
        .{ .identifier, "let" },
        .{ .illegal, "\\" },
        .{ .identifier, "u" },
        .{ .punct, "{" },
        .{ .number, "41" },
        .{ .punct, "}" },
        .{ .punct, "=" },
        .{ .number, "1" },
        .{ .punct, ";" },
        .{ .eof, "" },
    });
}
