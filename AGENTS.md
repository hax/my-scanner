# AGENTS.md

用 Zig + SIMD 做 JS/TS 词法分析器（scanner）。

开始干活前按需查看 README 和 docs/ 目录下的文件。
干活勿忘初心，如有迷茫，请回顾 docs/goals.md。

## 命令

```sh
scripts/check.sh     # 正确性校验：单测 + 全部架构变体 × 样本与 tsc 差分测试
scripts/bench.sh     # 本地吞吐对比（口径已内置，直接用，勿自建口径）
scripts/bench.sh --submit  # 完整矩阵 + 汇总发布本地 run 到 bench-reports（机器名不入产物）
scripts/ci-bench.sh  # CI 同款全链路（正确性校验 + 矩阵基准 + 报告），本地可跑
zig build test       # 仅单元测试，不等于正确性校验
```

`check.sh` 首次运行需要 `cd tools && npm i`（tsc 对照依赖）；`bench.sh`
首次运行由 `scripts/prepare-baselines.sh` 备第三方基线到 `.bench-deps/`
（已 gitignore）：yuku-old 钉 v0.10.1、yuku-main 跟踪上游（移动才重
clone）；swc/oxc 由 `scripts/prepare-lexbench.sh` 自动跟踪 crates.io 最新
稳定版（有新版即改写 Cargo.toml 锚钉版 + `cargo update` 落锁），oxc_lexer
跟踪 oxc 仓 main（分支移动才重拉 + 重打 NEON patch）；vendored oxc_parser
或 NEON patch 失效即报错退出（该修就修，勿静默沿用旧版数字）。第三方计时
结果缓存在 `.bench-deps/`（版本/样本/轮数/编译器变动自动失效），强制重跑
用 `--refresh-baselines`；**CI 总是实跑**（GITHUB_ACTIONS 下显式 refresh，
勿把本地缓存数字当跨机结论）。

报告页脚本（make-report / publish-report / update-index）在
`scripts/report/`：只影响报告展示与发布、不影响测量与校验，已在
bench.yml `paths-ignore` 豁免，改动不触发 CI bench。

样本来自 **samples 分支**（只含样本的孤儿分支）：`check.sh`/`ci-bench.sh`
会先调 `scripts/prepare-samples.sh` 幂等拉取 + sha256 校验，无需手动准备。
更新样本用 `node scripts/publish-samples.mjs [--push]`（同步 manifest 校验 +
发布分支）；**改样本或升 tsc 后由它重生成派生文件 `samples/decisions/`、
`samples/offsets/`**（差分测试的决策真相与坐标修正表，勿手改）；谱系/来源见
docs/samples.md 与 tools/samples-manifest.json。tsc 升版后 decisions 头里
版本不匹配会让差分测试直接硬报错，重生成派生文件即可。

## 流程规则

1. **语义层任何改动**（`src/scanner.zig` 及各变体共享的语义函数）以
   `scripts/check.sh` 全绿为准 —— 每个架构变体都必须通过校验，语义漂移
   在此拦截。只跑 `zig build test` 不够。**批量文本替换后必跑 `check.sh`**。
2. **修 bug 先加防回归用例**再修（历史上随机交叉验证抓回的分支各有专属用例）。
3. **性能结论以 bench 实测裁决**：指令数、采样 profile 只是线索不是证据。
4. **性能表现必须结合样本谱系理解**：如 token 密度、unicode 密度、字符串/注释密度 —— 样本合理性判断及调整须向 hax 请示。样本分 `samples/real/`（真实代码）与 `samples/synthetic/`（构造极端样本，microbench/test 专用，与真实分列）；详见 docs/samples.md。
5. **实验无论成败都留档**：专题记录进 docs/、条目进 docs/roadmap.md；被否决的实验写明否决原因，架构相关进 docs/architecture.md。
6. **与第三方 lexer 对比**必须考虑一致性和公平，歧义点决策需可控（`/` 按正则还是除号，`<` 是 jsx/小于/泛型）——两条合规路径：决策注入（yuku/swc/oxc），或歧义自决 + `tools/compare-oxc-bitmap.mjs` 全样本 spans 校验一致（oxc_bitmap）。
