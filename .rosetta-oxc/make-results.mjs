// 把 drive 的 raw JSON 换算成可读结果：每语料 file/bytes/tokens/best_ns + GB/s、Mtok/s。
// 口径与 drive.rs 打印一致：GB/s = bytes / best_ns（10^9 字节每秒），Mtok/s = tokens * 1000 / best_ns。
// 只取 oxc_bitmap 列（swc/oxc 列因无决策注入文件，数字无意义）。
// 由 build-and-bench.sh 在 worktree 根目录调用。
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";

const RAW = ".rosetta-oxc/rs-rosetta-x86_64.raw.json";
const OUT = ".rosetta-oxc/results.json";

// CI EPYC（oxc_bitmap，25 轮取最优）参照，仅这三个语料有
const EPYC = {
  "corpus/real/typescript.js": 0.681,
  "corpus/real/react.min.js": 0.761,
  "corpus/synthetic/line-comments.js": 0.951,
};

const rustc = (() => {
  try { return execFileSync("rustc", ["--version"], { encoding: "utf8" }).trim(); } catch { return "unknown"; }
})();
const rustcHost = (() => {
  try {
    const v = execFileSync("rustc", ["-vV"], { encoding: "utf8" });
    return (v.match(/host: (\S+)/) || [])[1] ?? "unknown";
  } catch { return "unknown"; }
})();

const raw = JSON.parse(readFileSync(RAW, "utf8"));
const runs = raw.runs.map((r) => {
  const bm = r.results.oxc_bitmap;
  if (!bm) throw new Error(`oxc_bitmap 结果缺失: ${r.file}`);
  const gb_s = r.bytes / bm.best_ns;
  const mtok_s = (bm.tokens * 1000) / bm.best_ns;
  const ref = EPYC[r.file];
  return {
    file: r.file,
    bytes: r.bytes,
    tokens: bm.tokens,
    best_ns: bm.best_ns,
    gb_per_s: +gb_s.toFixed(3),
    mtok_per_s: +mtok_s.toFixed(1),
    ...(ref ? { ci_epyc_gb_per_s: ref, rosetta_vs_epyc: `${((gb_s / ref - 1) * 100).toFixed(0)}%` } : {}),
  };
});

const out = {
  meta: {
    what: "oxc_lexer x86_64 AVX2+BMI2 (oxc_bitmap) 交叉编译 + Rosetta 2 运行",
    host: "Apple M3 Pro (arm64, macOS), 用户态经 Rosetta 2 翻译执行 AVX2/BMI2",
    target: "x86_64-apple-darwin",
    rustc,
    rustc_host: rustcHost,
    rustflags: "-C target-feature=+avx2,+bmi2",
    profile: "release (opt-level=3, lto=thin, codegen-units=1)",
    repeats: 25,
    metric: "N 轮取最优 best_ns；GB/s = bytes/best_ns；Mtok/s = tokens*1000/best_ns",
    oxc_rev: readFileSync(".bench-deps/oxc.sha", "utf8").trim(),
    simd_check: "drive stderr 无 generic fallback 警告（IS_SIMD=true）",
    options: "module=true; ts 按 .ts/.mts/.cts 开; jsx 按 .tsx/.jsx 开; validate_utf8=false; arena 轮外创建跨轮复用",
    date: new Date().toISOString(),
  },
  runs,
};

writeFileSync(OUT, JSON.stringify(out, null, 2) + "\n");
console.log(JSON.stringify(out, null, 2));
