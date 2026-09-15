# my-scanner 语料库(corpus 分支)

本分支是 bench/差分语料的唯一权威存储:只含语料,不含源码。
主仓 `scripts/prepare-corpus.sh` 按需拉取并校验(`sha256sums.txt`);
语义标签(谱系分组)的单一来源是主仓 `tools/corpus-manifest.json`,
语料详情见主仓 docs/corpus.md。语料调整须 hax 审批。

| 文件 | 分组 | 谱系 | 大小 | 来源 | license | sha256 |
| --- | --- | --- | ---: | --- | --- | --- |
| `real/typescript.min.js` | real | minified bundle | 2959754 | https://cdn.jsdelivr.net/npm/typescript@5.1.6/lib/typescript.min.js | Apache-2.0 | `51f295f326c1ce74…` |
| `real/typescript.js` | real | 编译器 bundle（未压缩） | 8207497 | https://cdn.jsdelivr.net/npm/typescript@5.1.6/lib/typescript.js | Apache-2.0 | `804f9c1b6c64568c…` |
| `real/checker.ts` | real | 编译器源码 | 3120982 | https://raw.githubusercontent.com/microsoft/TypeScript/v5.9.2/src/compiler/checker.ts | Apache-2.0 | `aa3d9021ee9c6806…` |
| `real/lib.dom.d.ts` | real | 注释密集 d.ts | 1874901 | https://cdn.jsdelivr.net/npm/typescript@5.9.2/lib/lib.dom.d.ts | Apache-2.0 | `080941d9f9ff9307…` |
| `real/react.js` | real | 库源码（小文件） | 72141 | https://cdn.jsdelivr.net/npm/react@17.0.2/cjs/react.development.js | MIT | `ec670cc82d2aac81…` |
| `real/hanzi-chai.ts` | real | CJK 标识符密集 | 254527 | https://github.com/hanzi-chai/hanzi-chai.github.io @ 00f4f1b9d652b2db0868f30050d7d5608c35334c | GPL-3.0（仅 corpus 分支逐字分发，附 LICENSE 全文） | `11f25d132bdebf3a…` |
| `real/mon-entreprise.ts` | real | 拉丁变音标识符（偶发 unicode） | 104340 | https://github.com/betagouv/mon-entreprise @ f0c4db9b711f6cfaee79f07e07f05e77d3db25f9 | MIT | `394d5349e83a722c…` |
| `synthetic/line-comments.js` | synthetic | 行注释密集（构造） | 1676670 | 构造生成，无上游 | 本项目 | `b437aa72288aa6f7…` |
| `synthetic/strings.js` | synthetic | 字符串密集（构造） | 547460 | 构造生成，无上游 | 本项目 | `899bd0db7cd5ecc5…` |
| `synthetic/cn-dense.ts` | synthetic | CJK 标识符极端（构造） | 967530 | 构造生成，无上游 | 本项目 | `e9efdc654123d072…` |

