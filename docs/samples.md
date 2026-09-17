# 样本集：谱系、来源与机制

bench/差分测试样本分两类，分列存放：

- **`samples/real/`**：真实世界代码——对外有效性的基础，性能结论以它为准；
- **`samples/synthetic/`**：构造的极端样本——microbench/压力测试专用，
  不代表真实负载；报告中与真实样本分开汇总，防止构造数据稀释真实结论。

## 存储与取用机制

样本的唯一权威存储是 **`samples` 分支**（orphan 分支，只含样本不含源码，
机制类似 bench-reports）：

- 主仓 gitignore `samples/`；`scripts/prepare-samples.sh` 在
  check.sh / ci-bench.sh 前自动调用：齐备且 sha256 校验通过即跳过，
  否则从 `samples` 分支拉取并整体重建（幂等）。
- 更新样本走 `scripts/publish-samples.mjs`：双向校验
  `tools/samples-manifest.json` 与本地文件集一致后，重新生成派生文件
  （见下节）、渲染 `sha256sums.txt` / `MANIFEST.md` / `LICENSES/`
  并提交分支（`--push` 推送）。
- **语义标签（分组/谱系）的单一来源是主仓 `tools/samples-manifest.json`**；
  完整 sha256 清单在 samples 分支的 `sha256sums.txt` / `MANIFEST.md`。
- **样本的新增/调整须 hax 审批**（AGENTS.md 流程规则）。

## 派生文件（decisions / offsets）

样本侧还冻结两份派生文件，发布时由 `scripts/publish-samples.mjs`（内部调
`scripts/gen-derived.mjs`）用 tsc **重新生成**，随样本一同发布并纳入
`sha256sums.txt`；格式与路径映射见 [tools/sample-derived.mjs](../tools/sample-derived.mjs)，
消费方是 [tools/compare-tsc.mjs](../tools/compare-tsc.mjs)（机制见
[docs/correctness.md](correctness.md)）：

- `decisions/<分组>/<样本>.tsv`：**歧义决策真相**——每个正则字面量与模板
  续片（TemplateMiddle/Tail）的 byte/CU span，由 tsc parser 生成
  （要求样本无语法错误，否则生成即失败）。**失效条件：样本文件字节变 /
  tsc 升版**——头里记样本 sha256 与 tsc 版本，差分时对不上即硬报错。
- `offsets/<分组>/<样本>.tsv.gz`：非 ASCII 样本的**坐标修正表**
  （字节 ↔ UTF-16 code unit，每个非 ASCII 字符一条的增量表，gzip）。
  **失效条件：样本文件字节变**；纯 ASCII 样本不生成（消费侧按恒等处理）。

两者都勿手改（发布流程会覆盖）；全样本当前 261 正则 + 5084 模板续片。

## 谱系与实测特征

实测口径：`my-scanner --dump`（2026-09，two_phase）；tok/KB = tokens/千字节；
「ident 非 ASCII」= 标识符字符中非 ASCII 占比（括注含非 ASCII 的标识符占比）。

| 文件 | 分组 | 谱系 | 大小 | tok/KB | 非 ASCII 字节 | ident 非 ASCII |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| typescript.js | real | 编译器 bundle（未压缩） | 8.02 MB | 140 | 0% | 0% |
| typescript.min.js | real | minified bundle | 2.89 MB | 363 | 0% | 0% |
| checker.ts | real | 编译器源码 | 3.05 MB | 113 | 0% | 0% |
| lib.dom.d.ts | real | 注释密集 d.ts | 1.83 MB | 64 | 0% | 0% |
| react.js | real | 库源码（小文件） | 0.07 MB | 119 | 0% | 0% |
| react.min.js | real | minified 库（小文件） | 0.01 MB | 404 | 0% | 0% |
| hanzi-chai.ts | real | CJK 标识符密集 | 0.25 MB | 188 | 43.0% | 48.9%（54.7% 的 ident 含中文） |
| mon-entreprise.ts | real | 拉丁变音标识符 | 0.10 MB | 154 | 3.8% | 2.7%（20.5% 的 ident 含变音） |
| line-comments.js | synthetic | 行注释密集（构造） | 1.64 MB | 55 | 0% | 0% |
| strings.js | synthetic | 字符串密集（构造） | 0.53 MB | 157 | 0% | 0% |
| cn-dense.ts | synthetic | CJK 标识符极端（构造） | 0.94 MB | 93 | 62.4% | 65.8% |

## 逐文件来源（provenance）

### real

| 文件 | 来源 | license |
| --- | --- | --- |
| typescript.js | npm `typescript@5.1.6/lib/typescript.js`（sha256 逐字节对照确认） | Apache-2.0 |
| typescript.min.js | jsdelivr minified `typescript@5.1.6/lib/typescript.js`（与 typescript.js 同版配对：min 2.9MB vs unmin 8.2MB） | Apache-2.0 |
| checker.ts | `microsoft/TypeScript@v5.9.2 src/compiler/checker.ts` | Apache-2.0 |
| lib.dom.d.ts | npm `typescript@5.9.2/lib/lib.dom.d.ts`（对照确认） | Apache-2.0 |
| react.js | npm `react@17.0.2/cjs/react.development.js`（对照确认） | MIT |
| react.min.js | npm `react@17.0.2/cjs/react.production.min.js`（对照确认） | MIT |
| hanzi-chai.ts | [hanzi-chai/hanzi-chai.github.io](https://github.com/hanzi-chai/hanzi-chai.github.io) @ `00f4f1b9`，`packages/hanzi-chai/src/` 19 个 .ts 按路径序拼接（`\n` 分隔） | **GPL-3.0**（仅 samples 分支逐字分发，附 LICENSE 全文） |
| mon-entreprise.ts | [betagouv/mon-entreprise](https://github.com/betagouv/mon-entreprise) @ `f0c4db9b`，`site/source/**/domaine/**/*.ts` 75 个（除 `*.test.ts`/`*.spec.ts`）按路径序拼接 | MIT |

### synthetic

构造生成，无上游；内容稳定（逐字节进入 samples 分支，bench 趋势可比对）。
生成脚本未留档是历史遗留——若需调整，按现状重写确定性生成器并重新发布。

## checker.ts 重钉记录（2026-09）

原文件无法对照任何稳定 tag（v5.8.3 差 -18KB，v5.9-beta / v5.9.2 差 +23KB，
疑为某次 main 快照）。为来源可考，重钉到 **v5.9.2**（与 lib.dom.d.ts 同版
配对），大小 +23KB（~0.7%），token 数微变——该文件的 bench 趋势在此断档一次。

## 非 ASCII 标识符样本调研记录（2026-09）

目标：找「大量 unicode 标识符」的**真实、最好知名**的 JS/TS 项目。

- **中文**：hanzi-chai 入选（汉字自动拆分系统，42★，实测 54.7% 标识符含
  中文）。真实存在但冷门；更知名的中文社区项目（ECharts / Taro / uni-app
  等）标识符均为英文，非 ASCII 集中在注释。
- **日文**：gh code search（`function 取得/変換`、`const 一覧/データ` 等）
  只有个位数 star 的个人项目，无知名项目。未入选。
- **印度文（天城文）**：`const नाम/परिणाम` 等搜索零结果；印地语玩具语言
  （bhai-lang 类）自身源码是英文标识符。未找到真实样本。
- **拉丁变音（法/德）**：mon-entreprise 入选（法国政府项目，330★）；
  德文项目（含政府开源）标识符基本英文化，未找到合适样本。

结论：CJK 标识符的真实样本存在但稀少且冷门；拉丁变音是「偶发 unicode」
的真实代表；标识符极端密度仍只有构造的 cn-dense.ts 一个来源。

## 附：趋势页断档说明

2026-09 样本目录由 `samples/*` 调整为 `samples/real|synthetic/*`，趋势页
series 以路径为 key：旧 key 自此次起冻结，新 key 从零累积（一次性）。
