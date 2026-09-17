# my-scanner 样本集(samples 分支)

本分支是 bench/差分测试样本的唯一权威存储:只含样本,不含源码。
主仓 `scripts/prepare-samples.sh` 按需拉取并校验(`sha256sums.txt`);
语义标签(谱系分组)的单一来源是主仓 `tools/samples-manifest.json`,
样本详情见主仓 docs/samples.md。样本调整须 hax 审批。

| 文件 | 分组 | 谱系 | 大小 | 来源 | license | sha256 |
| --- | --- | --- | ---: | --- | --- | --- |
| `real/typescript.js` | real | 编译器 bundle（未压缩） | 8207497 | https://cdn.jsdelivr.net/npm/typescript@5.1.6/lib/typescript.js | Apache-2.0 | `804f9c1b6c64568c…` |
| `real/typescript.min.js` | real | minified bundle | 2959754 | https://cdn.jsdelivr.net/npm/typescript@5.1.6/lib/typescript.min.js | Apache-2.0 | `51f295f326c1ce74…` |
| `real/checker.ts` | real | 编译器源码 | 3120982 | https://raw.githubusercontent.com/microsoft/TypeScript/v5.9.2/src/compiler/checker.ts | Apache-2.0 | `aa3d9021ee9c6806…` |
| `real/lib.dom.d.ts` | real | 注释密集 d.ts | 1874901 | https://cdn.jsdelivr.net/npm/typescript@5.9.2/lib/lib.dom.d.ts | Apache-2.0 | `080941d9f9ff9307…` |
| `real/react.js` | real | 库源码（小文件） | 72141 | https://cdn.jsdelivr.net/npm/react@17.0.2/cjs/react.development.js | MIT | `ec670cc82d2aac81…` |
| `real/react.min.js` | real | minified 库（小文件） | 6450 | https://cdn.jsdelivr.net/npm/react@17.0.2/cjs/react.production.min.js | MIT | `d3ea88ce03534dc2…` |
| `real/hanzi-chai.ts` | real | CJK 标识符密集 | 254527 | https://github.com/hanzi-chai/hanzi-chai.github.io @ 00f4f1b9d652b2db0868f30050d7d5608c35334c | GPL-3.0（仅 samples 分支逐字分发，附 LICENSE 全文） | `11f25d132bdebf3a…` |
| `real/mon-entreprise.ts` | real | 拉丁变音标识符（偶发 unicode） | 104340 | https://github.com/betagouv/mon-entreprise @ f0c4db9b711f6cfaee79f07e07f05e77d3db25f9 | MIT | `394d5349e83a722c…` |
| `synthetic/line-comments.js` | synthetic | 行注释密集（构造） | 1676670 | 构造生成，无上游 | 本项目 | `b437aa72288aa6f7…` |
| `synthetic/strings.js` | synthetic | 字符串密集（构造） | 547460 | 构造生成，无上游 | 本项目 | `899bd0db7cd5ecc5…` |
| `synthetic/cn-dense.ts` | synthetic | CJK 标识符极端（构造） | 967530 | 构造生成，无上游 | 本项目 | `e9efdc654123d072…` |

## 派生文件(勿手改)

`decisions/` 与 `offsets/` 由主仓 `scripts/publish-samples.mjs`(内部调
`scripts/gen-derived.mjs`)在发布时重新生成,随本分支一同发布,已纳入 `sha256sums.txt`:

- `decisions/<分组>/<样本>.tsv`:歧义决策真相(正则字面量 / 模板续片的位置与 span,
  发布期由 tsc parser 生成一次)。运行期差分只跑 tsc scanner、按它驱动重扫,
  并断言 my-scanner 在这些点上的 lexeme 全中。**只随 tsc 版本失效**——升级 tsc 后
  重新发布(头里版本对不上时差分硬报错)。
- `offsets/<分组>/<样本>.tsv.gz`:非 ASCII 样本的「字节 ↔ UTF-16 code unit」修正表
  (每个非 ASCII 字符一条的增量表)。只随样本文件字节变;纯 ASCII 样本不生成。

