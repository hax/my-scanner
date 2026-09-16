// 重建 bench-reports 发布目录的索引:合并 reports/<sha>.json → index.json + index.html。
//
//   node scripts/update-index.mjs <publish-dir>
//
// <publish-dir>/reports/ 下每个 *.json 是一次 run 的 data.json(make-report 产物)。
// index.html 依赖同目录 vendor/echarts.min.js(从 tools/node_modules 拷贝,
// 需先 cd tools && npm i);GitHub Pages / 本地静态服务均可打开(纯 file:// 不行,
// fetch index.json 需要 http)。

import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

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

// ---- vendor echarts(tools/node_modules → 发布目录) ----
const echartsSrc = fileURLToPath(new URL("../tools/node_modules/echarts/dist/echarts.min.js", import.meta.url));
if (!existsSync(echartsSrc)) {
  console.error("缺少 echarts:请先 cd tools && npm i");
  process.exit(1);
}
mkdirSync(join(pubDir, "vendor"), { recursive: true });
copyFileSync(echartsSrc, join(pubDir, "vendor", "echarts.min.js"));

// ---- index.html:ECharts 趋势页 ----
// 内联脚本不写模板字面量(外层就是模板字面量,避免转义套娃)
const html = `<!doctype html>
<html lang="zh">
<head>
<meta charset="utf-8">
<title>my-scanner 架构矩阵基准</title>
<script src="vendor/echarts.min.js"></script>
<style>
  :root { color-scheme: light dark; }
  body { font-family: ui-sans-serif, system-ui, sans-serif; margin: 0 auto; max-width: 1080px; padding: 1rem 1.5rem 4rem; line-height: 1.5; }
  h1 { font-size: 1.4rem; } h2 { font-size: 1.1rem; margin-top: 2.2rem; }
  h3 { font-size: .95rem; margin: 1.2rem 0 .2rem; font-weight: 600; }
  .meta { color: gray; font-size: .85rem; }
  .mode button { cursor: pointer; padding: .2rem .7rem; margin-right: .3rem; border-radius: 6px; border: 1px solid currentColor; background: transparent; color: inherit; }
  .mode button.on { background: #4b7bec; border-color: #4b7bec; color: #fff; }
  .chart { width: 100%; height: 300px; }
  .bar { width: 100%; height: 240px; }
  code { background: color-mix(in srgb, currentColor 8%, transparent); padding: 0 .3rem; border-radius: 4px; }
  a { color: #4b7bec; }
</style>
</head>
<body>
<h1>my-scanner 架构矩阵基准</h1>
<p class="meta">相对值锚点 <code>yuku_main</code>(&gt;1 即更快);同族参照 = 自有实现 /
同族第三方对照(scalar→yuku-old、jump_vec→yuku-main,&gt;1 即我方更快),衡量各族自身成熟度,
该口径只画有对照的 scalar / jump_vec。绝对吞吐跨 runner 代际不可比,
同 run 内相对值始终有效。每次 push 一个点;架构变体语义由差分门禁保证。</p>
<p class="mode">趋势口径: <button id="mode-ratio" class="on">vs yuku-main</button><button id="mode-peer">vs 同族参照</button><button id="mode-gbps">GB/s</button>
<label class="meta" style="cursor:pointer;margin-left:.6rem"><input type="checkbox" id="show-local"> 叠加本地 run(空心点,不连线,带机器标识)</label>
<span class="meta" id="runinfo"></span></p>
<h2>当前对比 · 吞吐 (GB/s)</h2>
<p class="meta" id="bars-meta"></p>
<div id="bars"></div>
<h2>趋势</h2>
<div id="files"></div>
<script>
const COLORS = { scalar:"#e67e22", jump_vec:"#2ecc71", two_phase:"#e74c3c", yuku_old:"#95a5a6", yuku_main:"#3498db", swc:"#9b59b6", oxc:"#1abc9c" };
const NAMES  = { scalar:"scalar(全标量)", jump_vec:"jump_vec(单阶段+SIMD跳跃)", two_phase:"two_phase(两阶段)", yuku_old:"yuku-old", yuku_main:"yuku-main", swc:"swc(决策注入)", oxc:"oxc(决策注入)" };
const SHORT  = { scalar:"scalar", jump_vec:"jump_vec", two_phase:"two_phase", yuku_old:"yuku-old", yuku_main:"yuku-main", swc:"swc", oxc:"oxc" };
// 柱状图 x 轴排序:自有实现与其同族参照相邻,一眼看出各族成熟度
const BAR_ORDER = ["scalar", "yuku_old", "jump_vec", "yuku_main", "two_phase", "swc", "oxc"];
const theme = matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : null;
let mode = "ratio";
let showLocal = false;
const trendCharts = [];
const allCharts = [];

fetch("reports/index.json").then(r => r.json()).then(idx => {
  const nCi = idx.runs.filter(r => r.channel !== "local").length;
  document.getElementById("runinfo").textContent = " — " + nCi + " CI runs + " + (idx.runs.length - nCi) + " local runs, 最近: " + (idx.runs.at(-1)?.date ?? "");
  const ciIdx = [];
  idx.runs.forEach((r, i) => { if (r.channel !== "local") ciIdx.push(i); });
  // 柱状图固定取最近一次 CI run(同机同轮可比;本地 run 机器各异,见趋势图叠加)
  const lastCi = ciIdx.length ? ciIdx[ciIdx.length - 1] : idx.runs.length - 1;
  const lastRun = idx.runs[lastCi];
  document.getElementById("bars-meta").textContent = "最近一次 CI run: " + lastRun.sha.slice(0, 10) + " · " + lastRun.date.slice(0, 16).replace("T", " ") + "Z · " + (lastRun.runner?.os ?? "") + " / " + (lastRun.runner?.cpu ?? "").split("\\n").pop().split(":").pop().trim();

  const pvalOf = p => mode === "gbps" ? p.gbps : mode === "peer" ? p.pratio : p.ratio;
  const shownImpl = impl => mode !== "peer" || idx.peers[impl]; // 同族口径只画有第三方参照的实现

  // ---- 柱状图:每语料一组,最近一次 CI run 的各实现吞吐 ----
  const barRoot = document.getElementById("bars");
  for (const [file, series] of Object.entries(idx.series)) {
    const h = document.createElement("h3"); h.textContent = file; barRoot.appendChild(h);
    const div = document.createElement("div"); div.className = "bar"; barRoot.appendChild(div);
    const chart = echarts.init(div, theme);
    allCharts.push(chart);
    const anchorGbps = series[idx.anchor]?.[lastCi]?.gbps ?? null;
    chart.setOption({
      backgroundColor: "transparent",
      grid: { left: 55, right: 20, top: 25, bottom: 25 },
      xAxis: { type: "category", data: BAR_ORDER.map(i => SHORT[i]) },
      yAxis: { type: "value", name: "GB/s" },
      tooltip: {
        formatter: pr => {
          const impl = BAR_ORDER[pr.dataIndex];
          const p = (series[impl] || [])[lastCi];
          if (!p) return NAMES[impl] + ": 无数据";
          let s = NAMES[impl] + "<br/>" + p.gbps.toFixed(2) + " GB/s<br/>vs yuku-main: " + p.ratio.toFixed(2) + "x";
          if (p.pratio != null) s += "<br/>vs 同族参照: " + p.pratio.toFixed(2) + "x";
          return s;
        }
      },
      series: [{
        type: "bar",
        barMaxWidth: 42,
        data: BAR_ORDER.map(impl => {
          const p = (series[impl] || [])[lastCi];
          return p ? { value: p.gbps, itemStyle: { color: COLORS[impl] } } : null;
        }),
        markLine: anchorGbps == null ? undefined : {
          silent: true, symbol: "none",
          data: [{ yAxis: anchorGbps }],
          lineStyle: { color: COLORS[idx.anchor], type: "dashed", opacity: .6 },
          label: { show: true, formatter: "yuku-main", position: "insideEndTop", fontSize: 10 }
        }
      }]
    });
  }

  // ---- 趋势图:每语料一张折线,口径切换 + 本地 run 空心点叠加 ----
  const trendOption = series => {
    const sers = [];
    for (const impl of idx.impls) {
      if (!shownImpl(impl)) continue;
      const opt = {
        name: NAMES[impl], type: "line",
        symbolSize: 6,
        itemStyle: { color: COLORS[impl] },
        data: series[impl].map((p, i) => (idx.runs[i].channel === "local" || !p || pvalOf(p) == null) ? null : pvalOf(p)),
        connectNulls: false
      };
      if (sers.length === 0 && mode !== "gbps") {
        opt.markLine = { silent: true, symbol: "none", data: [{ yAxis: 1 }], lineStyle: { color: "#4b7bec", type: "dashed", opacity: .6 }, label: { show: false } };
      }
      sers.push(opt);
      if (showLocal) {
        const pts = [];
        series[impl].forEach((p, i) => {
          if (idx.runs[i].channel === "local" && p && pvalOf(p) != null) pts.push([i, pvalOf(p)]);
        });
        sers.push({
          name: NAMES[impl] + "(本地)", type: "scatter",
          symbolSize: 9,
          itemStyle: { color: "transparent", borderColor: COLORS[impl], borderWidth: 2 },
          data: pts,
          tooltip: {
            formatter: pr => {
              const r = idx.runs[pr.data[0]];
              const p = series[impl][pr.data[0]];
              let s = "[本地 " + (r.label ?? "?") + "] " + NAMES[impl] + "<br/>" + pvalOf(p).toFixed(2) + (mode === "gbps" ? " GB/s" : "x");
              s += "<br/>" + p.sha + " · " + p.date.slice(0, 10);
              return s;
            }
          }
        });
      }
    }
    return {
      backgroundColor: "transparent",
      grid: { left: 55, right: 20, top: 40, bottom: 45 },
      legend: { type: "scroll", data: idx.impls.filter(shownImpl).map(i => NAMES[i]) },
      xAxis: {
        type: "category",
        data: idx.runs.map(r => r.date.slice(5, 10) + " " + r.sha.slice(0, 7)),
        axisLabel: { formatter: v => v.slice(0, 5), rotate: 30 }
      },
      yAxis: {
        type: "value",
        name: mode === "gbps" ? "GB/s" : mode === "peer" ? "vs 同族参照" : "vs yuku-main",
        max: mode === "gbps" ? null : v => Math.max(v.max * 1.05, 1.15)
      },
      dataZoom: [{ type: "inside" }],
      tooltip: {
        trigger: "axis",
        valueFormatter: v => v == null ? "-" : mode === "gbps" ? v.toFixed(2) + " GB/s" : v.toFixed(2) + "x"
      },
      series: sers
    };
  };
  const fileRoot = document.getElementById("files");
  for (const [file, series] of Object.entries(idx.series)) {
    const h = document.createElement("h3"); h.textContent = file; fileRoot.appendChild(h);
    const div = document.createElement("div"); div.className = "chart"; fileRoot.appendChild(div);
    const chart = echarts.init(div, theme);
    chart.setOption(trendOption(series));
    trendCharts.push({ chart, series });
    allCharts.push(chart);
  }
  // 口径切换/本地叠加的真正重绘:趋势 option 依赖闭包内的 idx 与 mode
  redraw = () => trendCharts.forEach(tc => tc.chart.setOption(trendOption(tc.series), true));
}).catch(e => { document.getElementById("files").textContent = "index.json 加载失败: " + e; });

let redraw = () => {}; // fetch 完成前为空操作
const setMode = m => {
  mode = m;
  document.getElementById("mode-ratio").classList.toggle("on", m === "ratio");
  document.getElementById("mode-peer").classList.toggle("on", m === "peer");
  document.getElementById("mode-gbps").classList.toggle("on", m === "gbps");
  redraw();
};
document.getElementById("mode-ratio").onclick = () => setMode("ratio");
document.getElementById("mode-peer").onclick = () => setMode("peer");
document.getElementById("mode-gbps").onclick = () => setMode("gbps");
document.getElementById("show-local").onchange = e => { showLocal = e.target.checked; redraw(); };
addEventListener("resize", () => allCharts.forEach(c => c.resize()));
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

- [index.html](index.html) — ECharts 图表页:顶部为最近一次 CI run 的各实现吞吐柱状对比(每语料一组,实现与其同族参照相邻),下方为趋势折线(vs yuku-main / vs 同族参照 / GB/s 三种口径,相对值跨 runner 代际可比;本地 run 默认不画,可勾选叠加空心点)。图表依赖 [vendor/echarts.min.js](vendor/echarts.min.js)(tools/package.json 钉版)
- [reports/](reports/) — 每次 run 的 \`<sha>.md\`(人读报告)与 \`<sha>.json\`(原始数据);本地提交(bench.sh --submit)为 \`<sha>.local-<机器名>.*\`,带机器标识与 CI 主线分层

对比口径与架构族谱见仓库 docs/architecture.md。
`;
writeFileSync(join(pubDir, "README.md"), readme);
console.log("index.html / vendor/echarts.min.js / .nojekyll / README.md 已生成");

function round(x) { return Math.round(x * 1000) / 1000; }
