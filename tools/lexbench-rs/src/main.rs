//! swc / oxc lexer 计时 harness。
//!
//! 与 my-scanner 的 bench 同一口径：读文件（不计入）、N 轮取最优、
//! 产出的每个 token 交给 black_box 消耗、按各自 token 数计吞吐。
//! 输出 JSON 与 zig bench 的 --json 同构，由 scripts/make-report.mjs 汇总。
//!
//! 口径差异说明（与 zig 侧 yuku 对拍不同，这两个是独立进程）：
//! swc/oxc 的 lexer 由各自 parser 驱动时的正则/除号上下文无法在独立
//! 迭代里复刻，`/` 一律按除号产 token——与 tsc/yuku 纯 scanner 同款
//! 保守设计，token 数差异 <1%，不影响吞吐对比结论。

use std::time::Instant;

fn main() {
    let mut repeats: u32 = 10;
    let mut json_path: Option<String> = None;
    let mut files: Vec<String> = Vec::new();
    for arg in std::env::args().skip(1) {
        if let Some(v) = arg.strip_prefix("--repeats=") {
            repeats = v.parse().unwrap_or(10);
        } else if let Some(v) = arg.strip_prefix("--json=") {
            json_path = Some(v.to_string());
        } else if arg == "-h" || arg == "--help" {
            println!("usage: lexbench [--repeats=N] [--json=<path>] <file>...");
            return;
        } else {
            files.push(arg);
        }
    }
    if files.is_empty() {
        println!("usage: lexbench [--repeats=N] [--json=<path>] <file>...");
        std::process::exit(2);
    }

    let mut runs: Vec<Run> = Vec::new();
    for path in &files {
        let src = std::fs::read_to_string(path).expect("read file");
        println!("{}  ({} bytes, x{} rounds, best)", path, src.len(), repeats);

        let mut run = Run { file: path.clone(), bytes: src.len(), results: Vec::new() };
        bench_oxc(&src, repeats, &mut run);
        bench_swc(&src, repeats, &mut run);
        for nr in &run.results {
            if let Some(r) = &nr.result {
                let ms = r.best_ns as f64 / 1e6;
                let gbps = src.len() as f64 / r.best_ns as f64;
                let mtoks = r.tokens as f64 * 1000.0 / r.best_ns as f64;
                println!(
                    "  {:<10} best {:>8.2} ms   {:>6.2} GB/s   {:>8.1} Mtok/s   ({} tokens)",
                    nr.name, ms, gbps, mtoks, r.tokens
                );
            }
        }
        println!();
        runs.push(run);
    }

    if let Some(p) = json_path {
        let mut json = String::from("{\"runs\":[");
        for (i, run) in runs.iter().enumerate() {
            if i > 0 {
                json.push(',');
            }
            json.push_str(&format!(
                "{{\"file\":\"{}\",\"bytes\":{},\"results\":{{",
                run.file, run.bytes
            ));
            for (j, nr) in run.results.iter().enumerate() {
                if j > 0 {
                    json.push(',');
                }
                match &nr.result {
                    Some(r) => json.push_str(&format!(
                        "\"{}\":{{\"best_ns\":{},\"tokens\":{}}}",
                        nr.name, r.best_ns, r.tokens
                    )),
                    None => json.push_str(&format!("\"{}\":null", nr.name)),
                }
            }
            json.push_str("}}");
        }
        json.push_str("]}\n");
        let tmp = format!("{}.tmp", p);
        std::fs::write(&tmp, json).unwrap();
        std::fs::rename(&tmp, &p).unwrap();
    }
}

struct Timed {
    best_ns: u128,
    tokens: usize,
}
struct NamedResult {
    name: &'static str,
    result: Option<Timed>,
}
struct Run {
    file: String,
    bytes: usize,
    results: Vec<NamedResult>,
}

/// oxc：lexer 模块仅在 benchmarking feature 下公开，这也是 oxc 官方
/// lexer benchmark 的同款入口。NoTokensLexerConfig 不把 token 收进
/// ArenaVec——纯消耗型吞吐，与其它实现的"append 后丢弃"口径等价。
fn bench_oxc(src: &str, repeats: u32, run: &mut Run) {
    use oxc_allocator::Allocator;
    use oxc_parser::config::NoTokensLexerConfig;
    use oxc_parser::lexer::Lexer;
    use oxc_parser::Kind;
    use oxc_span::SourceType;

    let source_type = SourceType::default().with_module(true).with_jsx(true);
    let mut best_ns = u128::MAX;
    let mut count = 0usize;

    for _ in 0..repeats {
        // oxc 的 Arena 生命周期绑定 Lexer，每轮新建（词法垃圾统一回收）
        let allocator = Allocator::default();
        let mut lexer =
            Lexer::new_for_benchmarks(&allocator, src, source_type, NoTokensLexerConfig);
        let mut n = 0usize;
        let t0 = Instant::now();
        let mut token = lexer.first_token();
        while token.kind() != Kind::Eof {
            n += 1;
            std::hint::black_box(&token);
            token = lexer.next_token_for_benchmarks();
        }
        let dt = t0.elapsed().as_nanos();
        if dt < best_ns {
            best_ns = dt;
        }
        count = n;
    }
    run.results.push(NamedResult { name: "oxc", result: Some(Timed { best_ns, tokens: count }) });
}

fn bench_swc(src: &str, repeats: u32, run: &mut Run) {
    use swc_common::input::StringInput;
    use swc_common::sync::Lrc;
    use swc_common::{FileName, SourceMap};
    use swc_ecma_ast::EsVersion;
    use swc_ecma_parser::{EsSyntax, Lexer, Syntax};

    let cm: Lrc<SourceMap> = Default::default();

    let mut best_ns = u128::MAX;
    let mut count = 0usize;

    for _ in 0..repeats {
        // swc 的 BytePos 全局递增，每轮新 fm 复位起址
        let fm = cm.new_source_file(
            Lrc::new(FileName::Custom("bench.js".into())),
            src.to_string(),
        );
        let lexer = Lexer::new(
            Syntax::Es(EsSyntax::default()),
            EsVersion::latest(),
            StringInput::from(&*fm),
            None,
        );
        let t0 = Instant::now();
        let mut n = 0usize;
        for token_and_span in lexer {
            std::hint::black_box(&token_and_span);
            n += 1;
        }
        let dt = t0.elapsed().as_nanos();
        if dt < best_ns {
            best_ns = dt;
        }
        count = n;
    }
    run.results.push(NamedResult { name: "swc", result: Some(Timed { best_ns, tokens: count }) });
}
