# my-scanner 架构矩阵基准报告

每次 push 到 main 触发（`.github/workflows/bench.yml`）：全变体差分门禁 →
架构矩阵基准 → 本分支归档。

在线图表页（GitHub Pages，源 = 本分支）：<https://johnhax.net/my-scanner/>

- [index.html](index.html) — ECharts 图表页：顶部为比对者说明（链接到各 git 仓，yuku 基线版本溯源）、机器配置（CI runner 与本机，基线同为 yuku v0.10.1 固定快照）与语料说明（大小与 tokens（baseline 计数）、出处、来源版本与链接/构造场景，图上只留文件名）；柱状图为最近一次 CI 与本机 run 的「vs baseline」倍数对比（每语料一张 370px 定宽卡片、随页宽并排；label 45° 斜排；左 CI 右本机、同色本机半透明，架构族间留空槽分组，baseline 两柱恒 1.0、与 y=1 虚线互证基线对齐），下方为趋势折线（vs baseline / vs 同族参照两种口径；实线 CI、虚线本机按机器分组、同机相连；基线固定，相对值跨 run、跨机可比）。图表依赖 [vendor/echarts.min.js](vendor/echarts.min.js)（tools/package.json 固定版本）
- [reports/](reports/) — 每次 run 的 `<sha>.md`（人读报告）与 `<sha>.json`（原始数据）；本地提交（bench.sh --submit）为 `<sha>.local.*`（机器名不入产物），与 CI 同图并绘

对比口径与架构族谱见仓库 docs/architecture.md。
