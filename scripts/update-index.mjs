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
const index = {
  updated: new Date().toISOString(),
  anchor: "yuku_main",
  impls: ["scalar", "jump_vec", "two_phase", "yuku_old", "yuku_main"],
  runs: runs.map((r) => ({ sha: r.sha, date: r.date, subject: r.subject, runner: r.runner })),
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
      series[impl].push(e ? { gbps: round(e.gbps), ratio: round(e.vs_anchor), sha: r.sha.slice(0, 10), date: r.date } : null);
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
<p class="meta">相对值锚点 <code>yuku_main</code>(&gt;1 即更快)。绝对吞吐跨 runner 代际不可比,
同 run 内相对值始终有效。每次 push 一个点;架构变体语义由差分门禁保证。</p>
<p class="mode">口径: <button id="mode-ratio" class="on">vs yuku-main</button><button id="mode-gbps">GB/s</button>
<span class="meta" id="runinfo"></span></p>
<div id="files"></div>
<script>
const COLORS = { scalar:"#e67e22", jump_vec:"#2ecc71", two_phase:"#e74c3c", yuku_old:"#95a5a6", yuku_main:"#3498db" };
const NAMES  = { scalar:"scalar(全标量)", jump_vec:"jump_vec(单阶段+SIMD跳跃)", two_phase:"two_phase(两阶段,主线)", yuku_old:"yuku-old", yuku_main:"yuku-main" };
let mode = "ratio";
fetch("reports/index.json").then(r => r.json()).then(idx => {
  document.getElementById("runinfo").textContent = " — " + idx.runs.length + " runs,最近: " + (idx.runs.at(-1)?.date ?? "");
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
      let ymax = 0;
      for (const impl of idx.impls) for (const p of series[impl]) if (p) ymax = Math.max(ymax, mode === "ratio" ? p.ratio : p.gbps);
      if (mode === "ratio") ymax = Math.max(ymax, 1.15);
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
      if (mode === "ratio") { // 1.0 参考线
        const l = document.createElementNS(svgNS, "line");
        l.setAttribute("x1", P); l.setAttribute("x2", W - P);
        l.setAttribute("y1", y(1)); l.setAttribute("y2", y(1));
        l.setAttribute("stroke", "#4b7bec"); l.setAttribute("opacity", ".5"); l.setAttribute("stroke-dasharray", "6 4");
        svg.appendChild(l);
      }
      for (const impl of idx.impls) {
        let d = "", pen = false;
        series[impl].forEach((p, i) => {
          if (!p) { pen = false; return; }
          const px = x(i), py = y(mode === "ratio" ? p.ratio : p.gbps);
          d += (pen ? "L" : "M") + px.toFixed(1) + " " + py.toFixed(1) + " ";
          pen = true;
          const c = document.createElementNS(svgNS, "circle");
          c.setAttribute("cx", px); c.setAttribute("cy", py); c.setAttribute("r", 2.6);
          c.setAttribute("fill", COLORS[impl]);
          const tip = document.createElementNS(svgNS, "title");
          tip.textContent = NAMES[impl] + " " + (mode === "ratio" ? p.ratio + "x" : p.gbps + " GB/s") + " @ " + p.sha + " " + p.date.slice(0, 10);
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
    tbl.innerHTML = "<tr><th>实现</th><th>vs yuku-main</th><th>GB/s</th></tr>" +
      idx.impls.map(impl => {
        const p = fr[impl][last];
        return p ? "<tr><td>" + NAMES[impl] + "</td><td>" + p.ratio.toFixed(2) + "x</td><td>" + p.gbps.toFixed(2) + "</td></tr>" : "";
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
  document.getElementById("mode-gbps").classList.toggle("on", m === "gbps");
  redrawFns.forEach(f => f());
};
document.getElementById("mode-ratio").onclick = () => setMode("ratio");
document.getElementById("mode-gbps").onclick = () => setMode("gbps");
</script>
</body>
</html>
`;
writeFileSync(join(pubDir, "index.html"), html);

// 分支自述
const readme = `# my-scanner 架构矩阵基准报告

每次 push 到 main 触发(\`.github/workflows/bench.yml\`):全变体差分门禁 →
架构矩阵基准 → 本分支归档。

- [index.html](index.html) — 趋势页(相对 yuku-main 的倍数,跨 runner 代际可比)
- [reports/](reports/) — 每次 run 的 \`<sha>.md\`(人读报告)与 \`<sha>.json\`(原始数据)

对比口径与架构族谱见仓库 docs/architecture.md。
`;
writeFileSync(join(pubDir, "README.md"), readme);
console.log("index.html / README.md 已生成");

function round(x) { return Math.round(x * 1000) / 1000; }
