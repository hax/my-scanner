//! oxc_lexer（多位图流水线实验 crate）token dump：每文件先打印 `== <path>`
//! 头行，随后每个显著 token 一行 `start\tend\tcoarse-kind`，末尾补一行
//! 合成 eof（对齐 my-scanner --dump 的流尾）。
//! coarse-kind 映射到 my-scanner 的粗类名，供 tools/compare-oxc-bitmap.mjs
//! 做 spans 级对拍（模板片 TemplateHead/Middle/Tail 由对拍脚本吞噬同步）。
//!
//! 用法: bitmap_dump <file>...

use oxc_lexer::{LexOptions, TokenKind, lex_utf8, PAD};

/// 与 drive.rs 的 oxc_bitmap 同款 options（两边必须一致）：
/// 全部按 module 计；.ts/.mts/.cts 开 ts 关键字集；.tsx/.jsx 开 jsx。
fn options_for(path: &str) -> LexOptions {
    let mut o = LexOptions { source_type_module: true, ..Default::default() };
    o.ts = path.ends_with(".ts") || path.ends_with(".mts") || path.ends_with(".cts");
    o.jsx = path.ends_with(".tsx") || path.ends_with(".jsx");
    if path.ends_with(".tsx") {
        o.ts = true;
    }
    o
}

/// 映射到 my-scanner 的粗类名（identifier/number/string/模板四片/
/// regex/punct/eof）；punct 之外未覆盖的类别打印原始名（JSX 类等）。
/// 与 my-scanner lexeme.zig 的 LexemeKind 对齐：关键字不细分（一律
/// identifier），模板拆 no_substitution/head/middle/tail 四片。
/// private_name 保留原名（my-scanner 拆成 `#` + identifier 两个 lexeme，
/// 由对拍脚本的吞噬同步对齐）。
fn coarse(k: TokenKind) -> &'static str {
    if k == TokenKind::Eof {
        return "eof";
    }
    if k == TokenKind::RegExp {
        return "regex";
    }
    if k.is_ident() {
        return "identifier";
    }
    if k.is_private_ident() {
        return "private_name";
    }
    if k.is_keyword() {
        return "identifier";
    }
    if k.is_numeric() {
        return "number";
    }
    if k.is_string() {
        return "string";
    }
    if k.is_template_no_sub() {
        return "no_substitution_template";
    }
    if k.is_template_head() {
        return "template_head";
    }
    if k.is_template_middle() {
        return "template_middle";
    }
    if k.is_template_tail() {
        return "template_tail";
    }
    if k.is_trivia() {
        // emit_comments=false 的显著流里不应出现；出现即对拍会抓到
        return "trivia";
    }
    "punct"
}

fn main() {
    let files: Vec<String> = std::env::args().skip(1).collect();
    if files.is_empty() {
        eprintln!("usage: bitmap_dump <file>...");
        std::process::exit(2);
    }
    if !oxc_lexer::IS_SIMD {
        eprintln!("warning: 非 x86_64+AVX2/BMI2 静态构建，oxc_bitmap 为 generic fallback 语义路径");
    }
    for path in &files {
        let mut bytes = std::fs::read(path).expect("read file");
        let n = bytes.len();
        assert!(n < 1 << 31, "源长度超出 oxc_lexer 31-bit 偏移上限");
        bytes.extend_from_slice(&[0u8; PAD]);
        let (result, arena) = lex_utf8(&bytes, n as u32, options_for(path));
        let kinds = result.tok_kinds(&arena);
        let spans = result.tok_spans(&arena);
        println!("== {path}");
        for i in 0..result.token_count as usize {
            println!(
                "{}\t{}\t{}",
                oxc_lexer::token::offset(spans[i].start),
                spans[i].end,
                coarse(kinds[i])
            );
        }
        println!("{n}\t{n}\teof");
        if result.diagnostic_count > 0 {
            eprintln!("warning: {path}: {} 条 diagnostics", result.diagnostic_count);
        }
        if result.hit_resource_limit {
            eprintln!("warning: {path}: hit_resource_limit（token 流可能被截断）");
        }
    }
}
