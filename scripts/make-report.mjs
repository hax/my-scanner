// 汇总 bench JSON(zig 必需 + rust 可选)→ report.md(人读) + data.json(趋势累积)。
//
//   node scripts/make-report.mjs <zig.json> [--rs <rs.json>] --out <dir>
//         [--sha <sha>] [--subject <msg>] [--repeats N] [--diff-ok]
//
// 输出:
//   <dir>/report.md   — 人读报告(CI step summary / bench-reports 分支归档)
//   <dir>/data.json   — 单 run 结构化数据(趋势页 index 累积用)

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

// 架构族谱:实现 → {族, 说明}。表中展示,提醒对比的意义(同族内比实现、跨族比架构)
const IMPL_META = {
  scalar: { family: "全标量单阶段", peer: "yuku-old(0.10.1 快照)" },
  jump_vec: { family: "单阶段 + SIMD 长跳跃", peer: "yuku-main / swc / oxc" },
  two_phase: { family: "两阶段 SIMD(主线)", peer: "—" },
  yuku_old: { family: "全标量单阶段(第三方)", peer: "scalar 的参照" },
  yuku_main: { family: "单阶段 + SIMD 长跳跃(第三方)", peer: "jump_vec 的参照" },
  swc: { family: "第三方(口径待校准)", peer: "—" },
  oxc: { family: "第三方(口径待校准)", peer: "—" },
};
const IMPL_ORDER = ["scalar", "jump_vec", "two_phase", "yuku_old", "yuku_main", "swc", "oxc"];
const ANCHOR = "yuku_main"; // 相对值锚点

const argv = process.argv.slice(2);
function opt(name, fallback = undefined) {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : fallback;
}
const zigJsonPath = argv[0]?.startsWith("--") ? undefined : argv[0];
const outDir = opt("--out", "build/bench");
if (!zigJsonPath || !outDir) {
  console.error("用法: node scripts/make-report.mjs <zig.json> [--rs <rs.json>] --out <dir> [--sha ..] [--subject ..] [--repeats N]");
  process.exit(2);
}

const sha = opt("--sha") ?? execFileSync("git", ["rev-parse", "HEAD"], { cwd: new URL("..", import.meta.url), encoding: "utf8" }).trim();
const subject = opt("--subject") ?? execFileSync("git", ["log", "-1", "--pretty=%s"], { cwd: new URL("..", import.meta.url), encoding: "utf8" }).trim();
const repeats = opt("--repeats", "?");

function env(cmd, args) {
  try { return execFileSync(cmd, args, { encoding: "utf8" }).trim(); } catch { return ""; }
}
const runner = {
  os: env("uname", ["-s"]) + " " + env("uname", ["-m"]),
  cpu: env("sh", ["-c", "grep -m1 'model name' /proc/cpuinfo 2>/dev/null || sysctl -n machdep.cpu.brand_string 2>/dev/null || true"]),
  zig: env("zig", ["version"]),
};

// 合并 zig + rust 的 runs(按 file 对齐;rust 缺失的文件不补)
const files = new Map(); // file -> {bytes, results: Map}
for (const path of [zigJsonPath, opt("--rs")]) {
  if (!path || !existsSync(path)) continue;
  const data = JSON.parse(readFileSync(path, "utf8"));
  for (const run of data.runs) {
    let f = files.get(run.file);
    if (!f) { f = { bytes: run.bytes, results: new Map() }; files.set(run.file, f); }
    for (const [name, r] of Object.entries(run.results)) f.results.set(name, r);
  }
}

const fmt = (x, d = 2) => Number(x).toFixed(d);
const fileRuns = [...files.entries()].map(([file, f]) => {
  const results = {};
  for (const name of IMPL_ORDER) {
    const r = f.results.get(name);
    if (!r) continue;
    results[name] = {
      best_ns: r.best_ns,
      tokens: r.tokens,
      gbps: r.best_ns > 0 ? f.bytes / r.best_ns : 0,
      mtoks: r.best_ns > 0 ? r.tokens * 1000 / r.best_ns : 0,
    };
  }
  const anchor = results[ANCHOR];
  if (anchor) for (const r of Object.values(results)) r.vs_anchor = anchor.best_ns / r.best_ns;
  return { file, bytes: f.bytes, results };
});

// ---- data.json ----
const dataJson = {
  sha, date: new Date().toISOString(), subject, repeats: Number(repeats) || null, runner,
  files: fileRuns,
};
writeFileSync(join(outDir, "data.json"), JSON.stringify(dataJson, null, 1) + "\n");

// ---- report.md ----
const lines = [];
lines.push(`# 架构矩阵基准 — \`${sha.slice(0, 10)}\``);
lines.push("");
lines.push(`- 提交: ${subject}`);
lines.push(`- 日期: ${dataJson.date}`);
lines.push(`- 轮数: 每实现 ${repeats} 轮取最优;同进程、同文件、token 产出后丢弃`);
lines.push(`- 环境: ${runner.os}${runner.cpu ? ` / ${runner.cpu}` : ""}${runner.zig ? ` / zig ${runner.zig}` : ""}`);
lines.push(`- 相对值锚点: ${ANCHOR}(各实现/锚点,>1 即更快)`);
lines.push("");
lines.push("| 实现 | 架构族 | 第三方参照 |");
lines.push("| --- | --- | --- |");
for (const name of IMPL_ORDER) {
  const m = IMPL_META[name];
  if (m) lines.push(`| \`${name}\` | ${m.family} | ${m.peer} |`);
}
lines.push("");

for (const fr of fileRuns) {
  lines.push(`## ${fr.file} (${(fr.bytes / 1e6).toFixed(2)} MB)`);
  lines.push("");
  lines.push("| 实现 | best ms | GB/s | Mtok/s | tokens | vs yuku-main |");
  lines.push("| --- | ---: | ---: | ---: | ---: | ---: |");
  for (const name of IMPL_ORDER) {
    const r = fr.results[name];
    if (!r) continue;
    lines.push(`| \`${name}\` | ${fmt(r.best_ns / 1e6)} | ${fmt(r.gbps)} | ${fmt(r.mtoks, 1)} | ${r.tokens} | ${r.vs_anchor != null ? fmt(r.vs_anchor) + "x" : "—"} |`);
  }
  lines.push("");
}

// 几何平均(vs 锚点,跨文件)——架构演化趋势的单值指标
const geo = {};
for (const fr of fileRuns) {
  for (const [name, r] of Object.entries(fr.results)) {
    if (r.vs_anchor == null) continue;
    geo[name] = (geo[name] ?? 1) * r.vs_anchor;
  }
}
const n = fileRuns.length;
lines.push(`## 几何平均(vs yuku-main,${n} 个语料)`);
lines.push("");
lines.push("| 实现 | 几何平均 |");
lines.push("| --- | ---: |");
const names = IMPL_ORDER.filter((x) => geo[x]);
names.sort((a, b) => geo[b] - geo[a]);
for (const name of names) lines.push(`| \`${name}\` | ${fmt(Math.pow(geo[name], 1 / n))}x |`);
lines.push("");

writeFileSync(join(outDir, "report.md"), lines.join("\n") + "\n");
console.log(lines.join("\n"));
