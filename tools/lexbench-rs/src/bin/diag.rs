//! 诊断：swc/oxc 独立 lexer 在样本上的终止位置与错误形态。
use std::time::Instant;

fn main() {
    for path in std::env::args().skip(1) {
        let src = std::fs::read_to_string(&path).expect("read file");
        println!("=== {} ({} bytes)", path, src.len());
        diag_oxc(&src);
        diag_swc(&src);
    }
}

fn diag_oxc(src: &str) {
    use oxc_allocator::Allocator;
    use oxc_parser::config::NoTokensLexerConfig;
    use oxc_parser::lexer::Lexer;
    use oxc_parser::Kind;
    use oxc_span::SourceType;

    let source_type = SourceType::default().with_module(true).with_jsx(true);
    let allocator = Allocator::default();
    let mut lexer = Lexer::new_for_benchmarks(&allocator, src, source_type, NoTokensLexerConfig);
    let mut n = 0usize;
    let mut last = (0u32, 0u32);
    let t0 = Instant::now();
    let mut token = lexer.first_token();
    while token.kind() != Kind::Eof {
        n += 1;
        last = (token.start(), token.end());
        token = lexer.next_token_for_benchmarks();
    }
    let errs = lexer.errors();
    println!(
        "oxc: {} tokens in {:?}, last token @{}..{}, errors: {}",
        n,
        t0.elapsed(),
        last.0,
        last.1,
        errs.len()
    );
    for e in errs.iter().take(5) {
        println!("  err: {:?}", e);
    }
}

fn diag_swc(src: &str) {
    use swc_common::input::StringInput;
    use swc_common::sync::Lrc;
    use swc_common::{FileName, SourceMap};
    use swc_ecma_ast::EsVersion;
    use swc_ecma_parser::unstable::Token;
    use swc_ecma_parser::{EsSyntax, Lexer, Syntax};

    let cm: Lrc<SourceMap> = Default::default();
    let fm = cm.new_source_file(Lrc::new(FileName::Custom("diag.js".into())), src.to_string());
    let lexer = Lexer::new(
        Syntax::Es(EsSyntax::default()),
        EsVersion::latest(),
        StringInput::from(&*fm),
        None,
    );
    let mut n = 0usize;
    let mut err_n = 0usize;
    let mut last = (0u32, 0u32);
    let mut first_errs: Vec<(u32, u32)> = Vec::new();
    let t0 = Instant::now();
    for ts in lexer {
        n += 1;
        if ts.token == Token::Error {
            err_n += 1;
            if first_errs.len() < 5 {
                first_errs.push((ts.span.lo.0, ts.span.hi.0));
            }
        }
        last = (ts.span.lo.0, ts.span.hi.0);
        if n > 20_000_000 {
            println!("swc: BAILOUT after 20M tokens (possible loop)");
            break;
        }
    }
    // fm 起址是全局递增的，offset 换算回 0 基
    let base = fm.start_pos.0;
    println!(
        "swc: {} tokens in {:?}, last token @{}..{}, error tokens: {} {:?}",
        n,
        t0.elapsed(),
        last.0 - base,
        last.1 - base,
        err_n,
        first_errs
            .iter()
            .map(|(lo, hi)| (lo - base, hi - base))
            .collect::<Vec<_>>()
    );
}
