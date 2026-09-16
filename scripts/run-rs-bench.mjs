// swc/oxc 对照计时(drive)的缓存调度:第三方版本由 Cargo.lock + vendored
// oxc 钉死,语料/轮数/工具链任一变动自动失效,只对缺失或陈旧的语料重跑
// drive,其余读缓存合并出 rs.json。仅加速本地迭代;CI(GITHUB_ACTIONS)
// 由 ci-bench.sh 显式传 --refresh 全量实跑(runner 代际性能漂移,第三方
// 必须与自家实现同 run 实测)。
//
//   node scripts/run-rs-bench.mjs --repeats=N --regex-dir=<dir> --json=<out> [--refresh] <file>...

import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join, relative } from "node:path";

const ROOT = new URL("..", import.meta.url).pathname;
const DRIVE = join(ROOT, "tools/lexbench-rs/target/release/drive");
const CACHE_PATH = join(ROOT, ".bench-deps/rs-bench-cache.json");
const LOCK_PATH = join(ROOT, "tools/lexbench-rs/Cargo.lock");
const OXC_DIR = join(ROOT, ".bench-deps/oxc_parser-0.150.0");
// oxc_bitmap 的源:prepare-lexbench.sh 钉 rev 的 oxc 仓源码树(rev 不进
// Cargo.lock,换 rev 必须失缓存,否则 oxc_bitmap 列沿用旧数字)
const OXC_LEXER_DIR = join(ROOT, ".bench-deps/oxc/crates/oxc_lexer");

let repeats = "10", regexDir, jsonOut, refresh = false;
const files = [];
for (const a of process.argv.slice(2)) {
  if (a.startsWith("--repeats=")) repeats = a.slice("--repeats=".length);
  else if (a.startsWith("--regex-dir=")) regexDir = a.slice("--regex-dir=".length);
  else if (a.startsWith("--json=")) jsonOut = a.slice("--json=".length);
  else if (a === "--refresh") refresh = true;
  else files.push(a);
}
if (!regexDir || !jsonOut || files.length === 0) {
  console.error("用法: node scripts/run-rs-bench.mjs --repeats=N --regex-dir=<dir> --json=<out> [--refresh] <file>...");
  process.exit(2);
}
if (!existsSync(DRIVE)) {
  console.error(`drive 不存在: ${DRIVE}(先 cd tools/lexbench-rs && cargo build --release)`);
  process.exit(2);
}

function sha256(buf) {
  return createHash("sha256").update(buf).digest("hex");
}

// 目录递归指纹(相对路径 + 内容;缺失目录记 "missing")
function dirFingerprint(dir) {
  const h = createHash("sha256");
  if (!existsSync(dir)) return "missing";
  const walk = (d) => {
    for (const name of readdirSync(d).sort()) {
      const p = join(d, name);
      if (statSync(p).isDirectory()) walk(p);
      else {
        h.update(relative(dir, p));
        h.update(readFileSync(p));
      }
    }
  };
  walk(dir);
  return h.digest("hex");
}

// 工具指纹:依赖钉版(Cargo.lock)+ 编译器 + vendored oxc 内容 + RUSTFLAGS
// (x86_64 的 avx2/bmi2 开关改变产物,见 ci-bench.sh)
function toolFingerprint() {
  let rustc = "unknown";
  try { rustc = execFileSync("rustc", ["--version"], { encoding: "utf8" }).trim(); } catch { /* PATH 外 */ }
  const h = createHash("sha256");
  h.update(readFileSync(LOCK_PATH));
  h.update(rustc);
  h.update(process.env.RUSTFLAGS ?? "");
  h.update(dirFingerprint(OXC_DIR));
  h.update(dirFingerprint(OXC_LEXER_DIR));
  return h.digest("hex");
}

const fp = toolFingerprint();
let cache = { fingerprint: fp, entries: {} };
if (!refresh && existsSync(CACHE_PATH)) {
  try {
    const c = JSON.parse(readFileSync(CACHE_PATH, "utf8"));
    if (c.fingerprint === fp && c.entries) cache = c;
    else console.log("工具链指纹变动,rs 缓存全量失效");
  } catch { /* 缓存损坏则重来 */ }
}

const keyOf = (file) => `${sha256(readFileSync(file))}|${repeats}`;
const miss = files.filter((f) => refresh || !cache.entries[keyOf(f)]);
if (miss.length > 0) {
  const tmpJson = `${jsonOut}.fresh.json`;
  execFileSync(DRIVE, [`--repeats=${repeats}`, `--regex-dir=${regexDir}`, `--json=${tmpJson}`, ...miss], { stdio: "inherit" });
  const fresh = JSON.parse(readFileSync(tmpJson, "utf8"));
  for (const run of fresh.runs) cache.entries[keyOf(run.file)] = run.results;
  writeFileSync(`${CACHE_PATH}.tmp`, JSON.stringify(cache));
  renameSync(`${CACHE_PATH}.tmp`, CACHE_PATH);
  rmSync(tmpJson, { force: true });
}

// 汇总:按输入顺序出 rs.json(与 drive --json 同构,make-report 按 file 合并)
const runs = files.map((f) => ({
  file: f,
  bytes: statSync(f).size,
  results: cache.entries[keyOf(f)],
}));
writeFileSync(`${jsonOut}.tmp`, JSON.stringify({ runs }) + "\n");
renameSync(`${jsonOut}.tmp`, jsonOut);
console.log(`rs.json: ${files.length} 个语料(${files.length - miss.length} 个来自缓存,${miss.length} 个实测)`);
