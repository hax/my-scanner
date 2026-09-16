//! 决策注入驱动 PoC：my-scanner 预扫产出的正则起点决策集驱动 swc lexer，
//! 对齐 yuku bench 的 reScanAsRegex / reScanTemplateContinuation 口径。
//!
//! swc 的注入点全部是公开 API（`swc_ecma_parser::input::Tokens` trait）：
//! - `set_next_regexp(Some(pos))` → 下一 token 强制从 pos 读正则（等价 reScanAsRegex）
//! - `rescan_template_token(pos, false)` → 从 `}` 重扫模板续段（等价 reScanTemplateContinuation）
//! - 模板 `${}` 内表达式用花括号平衡栈跟踪（与 yuku bench 同款）

use std::collections::HashSet;
use std::time::Instant;

use swc_common::input::StringInput;
use swc_common::sync::Lrc;
use swc_common::{FileName, SourceMap};
use swc_ecma_ast::EsVersion;
use swc_ecma_parser::input::Tokens;
use swc_ecma_parser::unstable::Token;
use swc_ecma_parser::{EsSyntax, Lexer, Syntax};

fn main() {
    let mut repeats: u32 = 5;
    let mut regex_path: Option<String> = None;
    let mut files: Vec<String> = Vec::new();
    for arg in std::env::args().skip(1) {
        if let Some(v) = arg.strip_prefix("--repeats=") {
            repeats = v.parse().unwrap_or(5);
        } else if let Some(v) = arg.strip_prefix("--regex=") {
            regex_path = Some(v.to_string());
        } else {
            files.push(arg);
        }
    }
    let mut re_set: HashSet<u32> = HashSet::new();
    if let Some(p) = &regex_path {
        for line in std::fs::read_to_string(p).expect("read regex decisions").lines() {
            if let Ok(v) = line.trim().parse::<u32>() {
                re_set.insert(v);
            }
        }
    }
    for path in &files {
        let src = std::fs::read_to_string(path).expect("read file");
        println!(
            "{} ({} bytes, x{}, regex decisions: {})",
            path,
            src.len(),
            repeats,
            re_set.len()
        );
        drive_swc(&src, repeats, &re_set);
        drive_oxc(&src, repeats, &re_set);
    }
}

/// oxc 的注入点在上游均为 `pub(crate)`，经 vendored 副本改为 pub 后驱动
/// （`.bench-deps/oxc_parser-0.150.0`，仅 2 处可见性改动）：
/// - `next_regex(kind)` → 当前 Slash/SlashEq token 重扫为正则
/// - `next_template_substitution_tail()` → 当前 `}` 重扫为模板续段
fn drive_oxc(src: &str, repeats: u32, re_set: &HashSet<u32>) {
    use oxc_allocator::Allocator;
    use oxc_parser::Kind;
    use oxc_parser::config::NoTokensLexerConfig;
    use oxc_parser::lexer::Lexer;
    use oxc_span::SourceType;

    let source_type = SourceType::default().with_module(true).with_jsx(true);
    let mut best_ns = u128::MAX;
    let mut count = 0usize;
    let mut err_count = 0usize;
    let mut last = (0u32, 0u32);

    for _ in 0..repeats {
        let allocator = Allocator::default();
        let mut lexer =
            Lexer::new_for_benchmarks(&allocator, src, source_type, NoTokensLexerConfig);
        let mut tpl_stack = [0u32; 64];
        let mut tpl_len = 0usize;
        let mut n = 0usize;

        let t0 = Instant::now();
        let mut t = lexer.first_token();
        loop {
            // 正则决策点：当前 Slash/SlashEq 直接重扫为正则（无需 rewind）
            if matches!(t.kind(), Kind::Slash | Kind::SlashEq) && re_set.contains(&t.start()) {
                let (t2, ..) = lexer.next_regex(t.kind());
                t = t2;
            }
            match t.kind() {
                Kind::TemplateHead | Kind::TemplateMiddle => {
                    if tpl_len < tpl_stack.len() {
                        tpl_stack[tpl_len] = 0;
                        tpl_len += 1;
                    }
                }
                Kind::LCurly if tpl_len > 0 => tpl_stack[tpl_len - 1] += 1,
                Kind::RCurly if tpl_len > 0 => {
                    if tpl_stack[tpl_len - 1] == 0 {
                        t = lexer.next_template_substitution_tail();
                        if t.kind() == Kind::TemplateTail {
                            tpl_len -= 1;
                        }
                    } else {
                        tpl_stack[tpl_len - 1] -= 1;
                    }
                }
                _ => {}
            }
            n += 1;
            std::hint::black_box(&t);
            last = (t.start(), t.end());
            if t.kind() == Kind::Eof {
                break;
            }
            t = lexer.next_token_for_benchmarks();
        }
        let dt = t0.elapsed().as_nanos();
        if dt < best_ns {
            best_ns = dt;
        }
        count = n;
        err_count = lexer.errors().len();
    }

    println!(
        "  oxc-driven: {} tokens ({} err), last @{}..{}, best {:.2} ms, {:.2} GB/s, {:.1} Mtok/s",
        count,
        err_count,
        last.0,
        last.1,
        best_ns as f64 / 1e6,
        src.len() as f64 / best_ns as f64,
        count as f64 * 1000.0 / best_ns as f64
    );
}

fn drive_swc(src: &str, repeats: u32, re_set: &HashSet<u32>) {
    let cm: Lrc<SourceMap> = Default::default();
    let mut best_ns = u128::MAX;
    let mut count = 0usize;
    let mut err_count = 0usize;
    let mut last = (0u32, 0u32);

    for _ in 0..repeats {
        // swc 的 BytePos 全局递增，每轮新 fm 复位起址
        let fm = cm.new_source_file(
            Lrc::new(FileName::Custom("drive.js".into())),
            src.to_string(),
        );
        let base = fm.start_pos.0;
        let mut lexer = Lexer::new(
            Syntax::Es(EsSyntax::default()),
            EsVersion::latest(),
            StringInput::from(&*fm),
            None,
        );
        // 模板上下文栈（模拟 parser 驱动）：head/middle 压一层，层内花括号
        // 平衡，归零后的 `}` 是模板自己的 → rescan_template_token
        let mut tpl_stack = [0u32; 64];
        let mut tpl_len = 0usize;
        let mut n = 0usize;
        let mut errs = 0usize;

        let t0 = Instant::now();
        let mut t = lexer.first_token();
        loop {
            // 正则决策点：swc 恒扫成除号，回退为强制正则重扫
            if matches!(t.token, Token::Slash | Token::DivEq)
                && re_set.contains(&(t.span.lo.0 - base))
            {
                lexer.set_next_regexp(Some(t.span.lo));
                t = lexer.next_token();
                lexer.set_next_regexp(None);
            }
            match t.token {
                Token::TemplateHead | Token::TemplateMiddle => {
                    if tpl_len < tpl_stack.len() {
                        tpl_stack[tpl_len] = 0;
                        tpl_len += 1;
                    }
                }
                Token::LBrace if tpl_len > 0 => tpl_stack[tpl_len - 1] += 1,
                Token::RBrace if tpl_len > 0 => {
                    if tpl_stack[tpl_len - 1] == 0 {
                        t = lexer.rescan_template_token(t.span.lo, false);
                        if t.token == Token::TemplateTail {
                            tpl_len -= 1;
                        }
                    } else {
                        tpl_stack[tpl_len - 1] -= 1;
                    }
                }
                _ => {}
            }
            if t.token == Token::Error {
                errs += 1;
            }
            n += 1;
            std::hint::black_box(&t);
            last = (t.span.lo.0 - base, t.span.hi.0 - base);
            if t.token == Token::Eof {
                break;
            }
            t = lexer.next_token();
        }
        let dt = t0.elapsed().as_nanos();
        if dt < best_ns {
            best_ns = dt;
        }
        count = n;
        err_count = errs;
    }

    println!(
        "  swc-driven: {} tokens ({} err), last @{}..{}, best {:.2} ms, {:.2} GB/s, {:.1} Mtok/s",
        count,
        err_count,
        last.0,
        last.1,
        best_ns as f64 / 1e6,
        src.len() as f64 / best_ns as f64,
        count as f64 * 1000.0 / best_ns as f64
    );
}
