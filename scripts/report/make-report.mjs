// 汇总 bench JSON(zig 必需 + rust 可选)→ report.md(人读) + data.json(趋势累积)。
//
//   node scripts/report/make-report.mjs <zig.json> [--rs <rs.json>] --out <dir>
//         [--sha <sha>] [--subject <msg>] [--repeats N]
//         [--channel ci|local] [--label <标识>](channel 默认按 GITHUB_ACTIONS 判定;
//         label 默认 local 为 "local"、ci 为 null——机器名不进入任何产物)
//
// 输出:
//   <dir>/report.md   — 人读报告(CI step summary / bench-reports 分支归档)
//   <dir>/data.json   — 单 run 结构化数据(趋势页 index 累积用)
//
// 语料的分组(real/synthetic)与谱系标签读 tools/corpus-manifest.json
// (单一来源);报告含语料谱系表、变体 × 语料矩阵、分组几何平均。

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

// 架构族谱:实现 → {族, 说明}。表中展示,提醒对比的意义(同族内比实现、跨族比架构)
const IMPL_META = {
  scalar: { family: "全标量单阶段", peer: "baseline（yuku 0.10.1 快照）" },
  jump_vec: { family: "单阶段 + SIMD 长跳跃", peer: "yuku-main / swc / oxc" },
  two_phase: { family: "两阶段 SIMD", peer: "oxc_bitmap（孵化实验 crate）" },
  yuku_old: { family: "全标量单阶段（第三方）", peer: "scalar 的参照" },
  yuku_main: { family: "单阶段 + SIMD 长跳跃（第三方）", peer: "jump_vec 的参照" },
  swc: { family: "单阶段 + 字节搜索（第三方，决策注入驱动）", peer: "—" },
  oxc: { family: "单阶段 + 字节搜索（第三方，决策注入驱动）", peer: "—" },
  oxc_bitmap: { family: "多位图流水线（第三方，孵化实验）", peer: "two_phase 的参照" },
};
const IMPL_ORDER = ["scalar", "jump_vec", "two_phase", "yuku_old", "yuku_main", "oxc", "swc", "oxc_bitmap"];
const OWN = ["scalar", "jump_vec", "two_phase"]; // 自有架构(矩阵列)
const ANCHOR = "yuku_old"; // 基线的数据键:固定快照,跨 run 可比(yuku-main 跟踪上游会漂,不做基线)
const ANCHOR_LABEL = "baseline";
const DISP = { yuku_old: "baseline", yuku_main: "yuku-main", oxc_bitmap: "oxc-bitmap" }; // 展示名(与图表页一致,数据键不变)
const disp = (n) => DISP[n] ?? n;
// 同族参照:自有实现 → 同架构族第三方对照(>1 即我方更快),衡量各族自身成熟度
const PEER = { scalar: "yuku_old", jump_vec: "yuku_main", two_phase: "oxc_bitmap" };

const argv = process.argv.slice(2);
function opt(name, fallback = undefined) {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : fallback;
}
const zigJsonPath = argv[0]?.startsWith("--") ? undefined : argv[0];
const outDir = opt("--out", "build/bench");
if (!zigJsonPath || !outDir) {
  console.error("用法: node scripts/report/make-report.mjs <zig.json> [--rs <rs.json>] --out <dir> [--sha ..] [--subject ..] [--repeats N]");
  process.exit(2);
}

const sha = opt("--sha") ?? execFileSync("git", ["rev-parse", "HEAD"], { cwd: new URL("../..", import.meta.url), encoding: "utf8" }).trim();
const subject = opt("--subject") ?? execFileSync("git", ["log", "-1", "--pretty=%s"], { cwd: new URL("../..", import.meta.url), encoding: "utf8" }).trim();
const repeats = opt("--repeats", "?");
// 通道:CI 自动判定(无需改 workflow);趋势页按 channel 分层,
// 避免本地结果与 CI 主线混淆。label 只是本机分组的占位标识——
// 机器名(含 CI runner 名)不进入任何产物
const channel = opt("--channel") ?? (process.env.GITHUB_ACTIONS === "true" ? "ci" : "local");
const runLabel = opt("--label") ?? (channel === "local" ? "local" : null);

function env(cmd, args) {
  try { return execFileSync(cmd, args, { encoding: "utf8" }).trim(); } catch { return ""; }
}
const runner = {
  os: env("uname", ["-s"]) + " " + env("uname", ["-m"]),
  cpu: env("sh", ["-c", "grep -m1 'model name' /proc/cpuinfo 2>/dev/null || sysctl -n machdep.cpu.brand_string 2>/dev/null || true"]),
  zig: env("zig", ["version"]),
};

// 语料清单:分组/谱系标签的单一来源(数组顺序即报告展示顺序)
let manifest = { files: [] };
try { manifest = JSON.parse(readFileSync(new URL("../../tools/corpus-manifest.json", import.meta.url), "utf8")); } catch { /* 缺清单也能出报告 */ }
const metaByPath = new Map(manifest.files.map((f, i) => [f.path, { ...f, order: i }]));

// 合并 zig + rust 的 runs(按 file 对齐;rust 缺失的文件不补)
const files = new Map(); // file -> {bytes, results: Map}
let baselines = null; // zig.json 的基线溯源(prepare-baselines 版本标记),透传给 data.json
let rsRust = null; // rs.json 的 rustc 版本戳(run-rs-bench 写入):实际编译 swc/oxc/oxc_bitmap 的工具链
for (const path of [zigJsonPath, opt("--rs")]) {
  if (!path || !existsSync(path)) continue;
  const data = JSON.parse(readFileSync(path, "utf8"));
  baselines ??= data.baselines ?? null;
  rsRust ??= data.rust ?? null;
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
  for (const [name, peer] of Object.entries(PEER)) {
    const r = results[name], p = results[peer];
    if (r && p && r.best_ns > 0) r.vs_peer = p.best_ns / r.best_ns;
  }
  const m = metaByPath.get(file);
  return { file, bytes: f.bytes, results, group: m?.group ?? "—", tag: m?.tag ?? "—", order: m?.order ?? 999 };
});
fileRuns.sort((a, b) => a.order - b.order);

// rust 版本进 runner(与 zig 并列):优先 rs.json 戳(同 run 实测对照组的工具链),
// 回退本机探测;只留版本号,与 zig 粒度一致
const rustV = (s) => s?.match(/\d+\.\d+\.\d+/)?.[0] ?? "";
runner.rust = rustV(rsRust) || rustV(env("rustc", ["--version"])) || null;

// ---- data.json ----
const dataJson = {
  sha, date: new Date().toISOString(), subject, repeats: Number(repeats) || null, runner,
  channel, label: runLabel, baselines,
  files: fileRuns.map(({ order, ...rest }) => rest),
};
writeFileSync(join(outDir, "data.json"), JSON.stringify(dataJson, null, 1) + "\n");

// ---- report.md ----
const short = (p) => p.replace(/^corpus\//, "");
const lines = [];
lines.push(`# 架构矩阵基准 — \`${sha.slice(0, 10)}\``);
lines.push("");
lines.push(`- 提交：${subject}`);
lines.push(`- 日期：${dataJson.date}`);
lines.push(`- 轮数：每实现 ${repeats} 轮取最优；同进程、同文件、token 产出后丢弃`);
lines.push(`- 环境：${runner.os}${runner.cpu ? ` / ${runner.cpu}` : ""}${runner.zig ? ` / zig ${runner.zig}` : ""}${runner.rust ? ` / rustc ${runner.rust}` : ""}`);
lines.push(`- 通道：${channel}${channel === "local" ? `（第三方对照计时可能来自本地缓存，与 CI 主线分机型呈现）` : ""}`);
lines.push(`- 基线：baseline（yuku v0.10.1 固定快照，跨 run 可比；各实现 / 基线，>1 即更快）`);
if (baselines) {
  const fb = (b) => (b ? [b.sha?.slice(0, 10), b.date?.slice(0, 10)].filter(Boolean).join(" ") : null);
  lines.push(`- 基线版本：baseline ${fb(baselines.yuku_old) ?? "?"} / yuku-main ${fb(baselines.yuku_main) ?? "?"}`);
}
lines.push(`- 同族参照：scalar vs baseline、jump_vec vs yuku-main、two_phase vs oxc_bitmap（自有实现 / 同族第三方，>1 即我方更快）`);
if (opt("--rs")) {
  lines.push(`- swc/oxc：lexbench-rs 决策注入驱动（同一 my-scanner 正则决策集 + 模板花括号栈重扫，与 yuku 对拍同口径），独立进程`);
  lines.push(`- oxc_bitmap：oxc_lexer 多位图流水线（孵化实验 crate，rev 固定）；歧义内部自决、经全语料 spans 门禁验证；计时含 value lanes（字符串 cooked、数字解析、atoms、注释元数据，比别家多做工）；TS 泛型侧不融合 \`>\`，token 数略多；仅 x86_64+AVX2/BMI2 为 SIMD 形态，其余平台 generic fallback（仅 smoke）`);
}
lines.push("");
lines.push("| 实现 | 架构族 | 第三方参照 |");
lines.push("| --- | --- | --- |");
for (const name of IMPL_ORDER) {
  const m = IMPL_META[name];
  if (m) lines.push(`| \`${disp(name)}\` | ${m.family} | ${m.peer} |`);
}
lines.push("");

// 语料谱系(real 真实语料 / synthetic 构造极端语料,后者供 microbench 压力用)
lines.push("## 语料谱系");
lines.push("");
lines.push("| 文件 | 分组 | 谱系 | 大小 | tokens | tok/KB |");
lines.push("| --- | --- | --- | ---: | ---: | ---: |");
for (const fr of fileRuns) {
  // token 计数以 baseline(yuku_old 固定快照) 为准:外部参照,不随我方 token 化口径漂移
  const tk = fr.results[ANCHOR]?.tokens ?? fr.results.two_phase?.tokens ?? Object.values(fr.results)[0]?.tokens;
  const tokb = tk != null && fr.bytes > 0 ? (tk / (fr.bytes / 1024)).toFixed(0) : "—";
  lines.push(`| \`${short(fr.file)}\` | ${fr.group} | ${fr.tag} | ${(fr.bytes / 1e6).toFixed(2)} MB | ${tk != null ? tk.toLocaleString("en-US") : "—"} | ${tokb} |`);
}
lines.push("");

for (const fr of fileRuns) {
  lines.push(`## ${fr.file} (${(fr.bytes / 1e6).toFixed(2)} MB)`);
  lines.push("");
  lines.push(`| 实现 | best ms | GB/s | Mtok/s | tokens | vs ${ANCHOR_LABEL} | vs 同族参照 |`);
  lines.push("| --- | ---: | ---: | ---: | ---: | ---: | ---: |");
  for (const name of IMPL_ORDER) {
    const r = fr.results[name];
    if (!r) continue;
    lines.push(`| \`${disp(name)}\` | ${fmt(r.best_ns / 1e6)} | ${fmt(r.gbps)} | ${fmt(r.mtoks, 1)} | ${r.tokens} | ${r.vs_anchor != null ? fmt(r.vs_anchor) + "x" : "—"} | ${r.vs_peer != null ? fmt(r.vs_peer) + "x" : "—"} |`);
  }
  lines.push("");
}

// 变体 × 语料矩阵:一眼看清哪个架构在哪类语料上赢(混合策略的证据底座)
lines.push(`## 变体 × 语料（vs ${ANCHOR_LABEL}；每行最快加粗）`);
lines.push("");
lines.push(`| 语料 | 谱系 | ${OWN.map((x) => `\`${x}\``).join(" | ")} |`);
lines.push("| --- | --- | ---: | ---: | ---: |");
for (const fr of fileRuns) {
  let best = -1;
  for (const n of OWN) best = Math.max(best, fr.results[n]?.vs_anchor ?? -1);
  const cells = OWN.map((n) => {
    const v = fr.results[n]?.vs_anchor;
    if (v == null) return "—";
    const s = fmt(v) + "x";
    return v === best && best > 0 ? `**${s}**` : s;
  });
  lines.push(`| \`${short(fr.file)}\` | ${fr.tag} | ${cells.join(" | ")} |`);
}
lines.push("");

// 分组几何平均(vs 基线)——真实/构造分开,防止构造语料稀释真实结论;
// 全体一行保持与旧报告口径连续
lines.push(`## 几何平均（vs ${ANCHOR_LABEL}）`);
lines.push("");
const geoImpls = IMPL_ORDER.filter((name) => fileRuns.some((fr) => fr.results[name]?.vs_anchor != null));
lines.push(`| 范围 | ${geoImpls.map((x) => `\`${disp(x)}\``).join(" | ")} |`);
lines.push(`| --- |${" ---: |".repeat(geoImpls.length)}`);
for (const [g, label] of [[null, "全体"], ["real", "真实语料"], ["synthetic", "构造语料"]]) {
  const subset = g ? fileRuns.filter((fr) => fr.group === g) : fileRuns;
  if (subset.length === 0) continue;
  const cells = geoImpls.map((name) => {
    let prod = 1, n = 0;
    for (const fr of subset) {
      const v = fr.results[name]?.vs_anchor;
      if (v != null) { prod *= v; n++; }
    }
    return n ? fmt(Math.pow(prod, 1 / n)) + "x" : "—";
  });
  lines.push(`| ${label}（${subset.length} 个） | ${cells.join(" | ")} |`);
}
lines.push("");

// 同族成熟度的分组几何平均:自有实现 / 同族第三方参照,各族自身口径
lines.push("## 几何平均（vs 同族参照）");
lines.push("");
const peerImpls = Object.keys(PEER).filter((name) => fileRuns.some((fr) => fr.results[name]?.vs_peer != null));
lines.push(`| 范围 | ${peerImpls.map((x) => `\`${x}\` vs \`${disp(PEER[x])}\``).join(" | ")} |`);
lines.push(`| --- |${" ---: |".repeat(peerImpls.length)}`);
for (const [g, label] of [[null, "全体"], ["real", "真实语料"], ["synthetic", "构造语料"]]) {
  const subset = g ? fileRuns.filter((fr) => fr.group === g) : fileRuns;
  if (subset.length === 0) continue;
  const cells = peerImpls.map((name) => {
    let prod = 1, n = 0;
    for (const fr of subset) {
      const v = fr.results[name]?.vs_peer;
      if (v != null) { prod *= v; n++; }
    }
    return n ? fmt(Math.pow(prod, 1 / n)) + "x" : "—";
  });
  lines.push(`| ${label}（${subset.length} 个） | ${cells.join(" | ")} |`);
}
lines.push("");

writeFileSync(join(outDir, "report.md"), lines.join("\n") + "\n");
console.log(lines.join("\n"));
