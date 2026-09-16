// 重建 bench-reports 发布目录的索引:合并 reports/<sha>.json → index.json + index.html。
//
//   node scripts/update-index.mjs <publish-dir>
//
// <publish-dir>/reports/ 下每个 *.json 是一次 run 的 data.json(make-report 产物)。
// index.html 自包含(无外部依赖,GitHub Pages / 本地 file:// 均可打开)。

import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const pubDir = process.argv[2];
if (!pubDir) {
  console.error("用法: node scripts/update-index.mjs <publish-dir>");
  process.exit(2);
}
const reportsDir = join(pubDir, "reports");

const runs = [];
for (const f of readdirSync(reportsDir)) {
  if (!f.endsWith(".json") || f === "index.json") continue;
  try {
    runs.push(JSON.parse(readFileSync(join(reportsDir, f), "utf8")));
  } catch (e) {
    console.error(`跳过损坏的 ${f}: ${e.message}`);
  }
}
runs.sort((a, b) => a.date.localeCompare(b.date));

// index.json:运行列表 + 每文件每实现的 vs yuku_main 与 GB/s 序列
// 同族参照(与 make-report.mjs 的 PEER 同步):自有实现 → 同族第三方对照,
// pratio 由 best_ns 补算,历史 run 无 vs_peer 字段也兼容
const PEERS = { scalar: "yuku_old", jump_vec: "yuku_main" };
const index = {
  updated: new Date().toISOString(),
  anchor: "yuku_main",
  peers: PEERS,
  impls: ["scalar", "jump_vec", "two_phase", "yuku_old", "yuku_main", "swc", "oxc"],
  runs: runs.map((r) => ({ sha: r.sha, date: r.date, subject: r.subject, runner: r.runner, channel: r.channel ?? "ci", label: r.label ?? null })),
  series: {},
};
const fileNames = new Set();
for (const r of runs) for (const f of r.files ?? []) fileNames.add(f.file);
for (const file of fileNames) {
  const series = {};
  for (const impl of index.impls) series[impl] = [];
  for (const r of runs) {
    const fr = (r.files ?? []).find((f) => f.file === file);
    for (const impl of index.impls) {
      const e = fr?.results?.[impl];
      let pratio = null;
      if (e) {
        const peer = PEERS[impl];
        const pv = e.vs_peer ?? (peer && fr?.results?.[peer]?.best_ns > 0 && e.best_ns > 0
          ? fr.results[peer].best_ns / e.best_ns : null);
        if (pv != null) pratio = round(pv);
      }
      series[impl].push(e ? { gbps: round(e.gbps), ratio: round(e.vs_anchor), pratio, sha: r.sha.slice(0, 10), date: r.date } : null);
    }
  }
  index.series[file] = series;
}
writeFileSync(join(reportsDir, "index.json"), JSON.stringify(index));
console.log(`index.json: ${runs.length} runs, ${fileNames.size} files`);

// ---- index.html:自包含趋势页 ----
const html = `<!doctype html>
<html lang="zh">
<head>
<meta charset="utf-8">
<title>my-scanner 架构矩阵基准 — 趋势</title>
<style>
  :root { color-scheme: light dark; }
  body { font-family: ui-sans-serif, system-ui, sans-serif; margin: 0 auto; max-width: 1080px; padding: 1rem 1.5rem 4rem; line-height: 1.5; }
  h1 { font-size: 1.4rem; } h2 { font-size: 1.05rem; margin-top: 2.2rem; }
  .meta { color: gray; font-size: .85rem; }
  .mode button { cursor: pointer; padding: .2rem .7rem; margin-right: .3rem; border-radius: 6px; border: 1px solid currentColor; background: transparent; color: inherit; }
  .mode button.on { background: #4b7bec; border-color: #4b7bec; color: #fff; }
  table { border-collapse: collapse; font-size: .85rem; margin: .6rem 0; }
  th, td { border: 1px solid color-mix(in srgb, currentColor 25%, transparent); padding: .18rem .6rem; text-align: right; }
  th:first-child, td:first-child { text-align: left; }
  .chart { width: 100%; height: 260px; }
  .legend { font-size: .8rem; margin: .2rem 0 .8rem; }
  .legend span { margin-right: 1rem; white-space: nowrap; }
  code { background: color-mix(in srgb, currentColor 8%, transparent); padding: 0 .3rem; border-radius: 4px; }
  a { color: #4b7bec; }
</style>
</head>
<body>
<h1>my-scanner 架构矩阵基准 — 趋势</h1>
<p class="meta">相对值锚点 <code>yuku_main</code>(&gt;1 即更快);同族参照 = 自有实现 /
同族第三方对照(scalar→yuku-old、jump_vec→yuku-main,&gt;1 即我方更快),衡量各族自身成熟度,
该口径只画有对照的 scalar / jump_vec。绝对吞吐跨 runner 代际不可比,
同 run 内相对值始终有效。每次 push 一个点;架构变体语义由差分门禁保证。</p>
<p class="mode">口径: <button id="mode-ratio" class="on">vs yuku-main</button><button id="mode-peer">vs 同族参照</button><button id="mode-gbps">GB/s</button>
<label class="meta" style="cursor:pointer;margin-left:.6rem"><input type="checkbox" id="show-local"> 叠加本地 run(空心点,不连线,带机器标识)</label>
<span class="meta" id="runinfo"></span></p>
<div id="files"></div>
<script>
const COLORS = { scalar:"#e67e22", jump_vec:"#2ecc71", two_phase:"#e74c3c", yuku_old:"#95a5a6", yuku_main:"#3498db", swc:"#9b59b6", oxc:"#1abc9c" };
const NAMES  = { scalar:"scalar(全标量)", jump_vec:"jump_vec(单阶段+SIMD跳跃)", two_phase:"two_phase(两阶段)", yuku_old:"yuku-old", yuku_main:"yuku-main", swc:"swc(决策注入)", oxc:"oxc(决策注入)" };
let mode = "ratio";
let showLocal = false;
fetch("reports/index.json").then(r => r.json()).then(idx => {
  const nCi = idx.runs.filter(r => r.channel !== "local").length;
  document.getElementById("runinfo").textContent = " — " + nCi + " CI runs + " + (idx.runs.length - nCi) + " local runs,最近: " + (idx.runs.at(-1)?.date ?? "");
  const root = document.getElementById("files");
  for (const [file, series] of Object.entries(idx.series)) {
    const sec = document.createElement("section");
    const h = document.createElement("h2"); h.textContent = file; sec.appendChild(h);
    const legend = document.createElement("div"); legend.className = "legend";
    for (const impl of idx.impls) {
      const s = document.createElement("span");
      s.innerHTML = '<svg width="10" height="10"><line x1="0" y1="5" x2="10" y2="5" stroke="' + COLORS[impl] + '" stroke-width="2.5"/></svg> ' + NAMES[impl];
      legend.appendChild(s);
    }
    sec.appendChild(legend);
    const svgNS = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(svgNS, "svg"); svg.setAttribute("class", "chart");
    svg.setAttribute("viewBox", "0 0 1000 260"); svg.setAttribute("preserveAspectRatio", "none");
    const draw = () => {
      svg.innerHTML = "";
      const W = 1000, H = 260, P = 34;
      const n = idx.runs.length;
      const pval = p => mode === "gbps" ? p.gbps : mode === "peer" ? p.pratio : p.ratio;
      const shown = impl => mode !== "peer" || idx.peers[impl]; // 同族口径只画有第三方参照的实现
      let ymax = 0;
      for (const impl of idx.impls) { if (!shown(impl)) continue; for (const p of series[impl]) if (p && pval(p) != null) ymax = Math.max(ymax, pval(p)); }
      if (mode !== "gbps") ymax = Math.max(ymax, 1.15);
      ymax *= 1.08;
      const x = i => n <= 1 ? W / 2 : P + (W - 2 * P) * i / (n - 1);
      const y = v => H - P - (H - 2 * P) * Math.min(v, ymax) / ymax;
      // 网格线 + y 轴刻度
      for (let g = 0; g <= 4; g++) {
        const gy = P + (H - 2 * P) * g / 4;
        const line = document.createElementNS(svgNS, "line");
        line.setAttribute("x1", P); line.setAttribute("x2", W - P);
        line.setAttribute("y1", gy); line.setAttribute("y2", gy);
        line.setAttribute("stroke", "currentColor"); line.setAttribute("opacity", ".15");
        svg.appendChild(line);
        const val = (ymax * (1 - g / 4)).toFixed(2);
        const t = document.createElementNS(svgNS, "text");
        t.setAttribute("x", 4); t.setAttribute("y", gy + 4); t.setAttribute("font-size", 11); t.setAttribute("fill", "currentColor"); t.setAttribute("opacity", .6);
        t.textContent = val; svg.appendChild(t);
      }
      if (mode !== "gbps") { // 1.0 参考线
        const l = document.createElementNS(svgNS, "line");
        l.setAttribute("x1", P); l.setAttribute("x2", W - P);
        l.setAttribute("y1", y(1)); l.setAttribute("y2", y(1));
        l.setAttribute("stroke", "#4b7bec"); l.setAttribute("opacity", ".5"); l.setAttribute("stroke-dasharray", "6 4");
        svg.appendChild(l);
      }
      for (const impl of idx.impls) {
        if (!shown(impl)) continue;
        let d = "", pen = false;
        series[impl].forEach((p, i) => {
          // 本地 run:不连线(避免与 CI 主线混淆),勾选后以空心点叠加
          if (idx.runs[i].channel === "local") {
            if (showLocal && p && pval(p) != null) {
              const px = x(i), py = y(pval(p));
              const c = document.createElementNS(svgNS, "circle");
              c.setAttribute("cx", px); c.setAttribute("cy", py); c.setAttribute("r", 3);
              c.setAttribute("fill", "none"); c.setAttribute("stroke", COLORS[impl]); c.setAttribute("stroke-width", 2);
              const tip = document.createElementNS(svgNS, "title");
              tip.textContent = "[本地 " + (idx.runs[i].label ?? "?") + "] " + NAMES[impl] + " " + pval(p) + (mode === "gbps" ? " GB/s" : "x") + " @ " + p.sha + " " + p.date.slice(0, 10);
              c.appendChild(tip); svg.appendChild(c);
            }
            return;
          }
          if (!p || pval(p) == null) { pen = false; return; }
          const px = x(i), py = y(pval(p));
          d += (pen ? "L" : "M") + px.toFixed(1) + " " + py.toFixed(1) + " ";
          pen = true;
          const c = document.createElementNS(svgNS, "circle");
          c.setAttribute("cx", px); c.setAttribute("cy", py); c.setAttribute("r", 2.6);
          c.setAttribute("fill", COLORS[impl]);
          const tip = document.createElementNS(svgNS, "title");
          tip.textContent = NAMES[impl] + " " + pval(p) + (mode === "gbps" ? " GB/s" : "x") + " @ " + p.sha + " " + p.date.slice(0, 10);
          c.appendChild(tip); svg.appendChild(c);
        });
        if (d) {
          const path = document.createElementNS(svgNS, "path");
          path.setAttribute("d", d); path.setAttribute("fill", "none");
          path.setAttribute("stroke", COLORS[impl]); path.setAttribute("stroke-width", 2);
          svg.appendChild(path);
        }
      }
    };
    draw();
    sec.appendChild(svg);
    // 最近一次 run 的表
    const last = idx.runs.length - 1;
    const fr = series;
    const tbl = document.createElement("table");
    tbl.innerHTML = "<tr><th>实现</th><th>vs yuku-main</th><th>vs 同族参照</th><th>GB/s</th></tr>" +
      idx.impls.map(impl => {
        const p = fr[impl][last];
        return p ? "<tr><td>" + NAMES[impl] + "</td><td>" + p.ratio.toFixed(2) + "x</td><td>" + (p.pratio != null ? p.pratio.toFixed(2) + "x" : "—") + "</td><td>" + p.gbps.toFixed(2) + "</td></tr>" : "";
      }).join("");
    sec.appendChild(tbl);
    root.appendChild(sec);
    redrawFns.push(draw);
  }
}).catch(e => { document.getElementById("files").textContent = "index.json 加载失败: " + e; });

const redrawFns = [];
const setMode = m => {
  mode = m;
  document.getElementById("mode-ratio").classList.toggle("on", m === "ratio");
  document.getElementById("mode-peer").classList.toggle("on", m === "peer");
  document.getElementById("mode-gbps").classList.toggle("on", m === "gbps");
  redrawFns.forEach(f => f());
};
document.getElementById("mode-ratio").onclick = () => setMode("ratio");
document.getElementById("mode-peer").onclick = () => setMode("peer");
document.getElementById("mode-gbps").onclick = () => setMode("gbps");
document.getElementById("show-local").onchange = e => { showLocal = e.target.checked; redrawFns.forEach(f => f()); };
</script>
</body>
</html>
`;
writeFileSync(join(pubDir, "index.html"), html);

// GitHub Pages(deploy from branch,源 = 本分支根目录):跳过 Jekyll,
// index.html 原样服务、reports/*.md 以纯文本可读
writeFileSync(join(pubDir, ".nojekyll"), "");

// 分支自述
const readme = `# my-scanner 架构矩阵基准报告

每次 push 到 main 触发(\`.github/workflows/bench.yml\`):全变体差分门禁 →
架构矩阵基准 → 本分支归档。

在线趋势页(GitHub Pages,源 = 本分支): <https://johnhax.net/my-scanner/>

- [index.html](index.html) — 趋势页(vs yuku-main / vs 同族参照 / GB/s 三种口径,相对值跨 runner 代际可比;本地 run 默认不画,可勾选叠加)
- [reports/](reports/) — 每次 run 的 \`<sha>.md\`(人读报告)与 \`<sha>.json\`(原始数据);本地提交(bench.sh --submit)为 \`<sha>.local-<机器名>.*\`,带机器标识与 CI 主线分层

对比口径与架构族谱见仓库 docs/architecture.md。
`;
writeFileSync(join(pubDir, "README.md"), readme);
console.log("index.html / .nojekyll / README.md 已生成");

function round(x) { return Math.round(x * 1000) / 1000; }
