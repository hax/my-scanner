# AGENTS.md

用 Zig + SIMD 做 JS/TS 词法分析器（scanner）。

开始干活前按需查看 README 和 docs/ 目录下的文件。
干活勿忘初心，如有迷茫，请回顾 docs/goals.md。

## 命令

```sh
scripts/check.sh     # 正确性门禁：单测 + 全部架构变体 × corpus 与 tsc 差分
scripts/bench.sh     # 本地吞吐对比（口径已内置，直接用，勿自建口径）
scripts/ci-bench.sh  # CI 同款全链路（门禁 + 矩阵基准 + 报告），本地可跑
zig build test       # 仅单元测试，不等价于门禁
```

`check.sh` 首次运行需要 `cd tools && npm i`（tsc 差分依赖）；`bench.sh`
首次运行会 clone 对比基线到 `.bench-deps/`（已 gitignore）。

语料来自 **corpus 分支**（只含语料的孤儿分支）：`check.sh`/`ci-bench.sh`
会先调 `scripts/prepare-corpus.sh` 幂等拉取 + sha256 校验，无需手动准备。
更新语料用 `node scripts/publish-corpus.mjs [--push]`（同步 manifest 校验 +
发布分支）；谱系/来源见 docs/corpus.md 与 tools/corpus-manifest.json。

## 流程规则

1. **语义层任何改动**（`src/scanner.zig` 及各变体共享的语义函数）以
   `scripts/check.sh` 全绿为准 —— 每个架构变体都必须差分通过，语义漂移
   在此拦截。只跑 `zig build test` 不够。**批量文本替换后必跑 `check.sh`**。
2. **修 bug 先加防回归用例**再修（历史上随机交叉验证抓回的分支各有专属用例）。
3. **性能结论以 bench 实测裁决**：指令数、采样 profile 只是线索不是证据。
4. **性能表现必须结合语料谱系理解**：如 token 密度、unicode 密度、字符串/注释密度 —— 语料合理性判断及调整须向 hax 请示。语料分 `corpus/real/`（真实代码）与 `corpus/synthetic/`（构造极端样本，microbench/test 专用，与真实分列）；详见 docs/corpus.md。
5. **实验无论成败都留档**：专题记录进 docs/、条目进 docs/roadmap.md；被否决的实验写明否决原因，架构相关进 docs/architecture.md。
6. **与第三方 lexer 对比**必须考虑一致性和公平，歧义点决策需可控（`/` 按正则还是除号，`<` 是 jsx/小于/泛型）。
