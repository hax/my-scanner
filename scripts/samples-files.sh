# 样本清单的单一来源:正确性校验外的基准矩阵与 swc/oxc 对照共用
# (顺序即报告展示顺序)。用法: source scripts/samples-files.sh
SAMPLES_FILES=(
  samples/real/typescript.js samples/real/typescript.min.js samples/real/checker.ts
  samples/real/lib.dom.d.ts samples/real/react.js samples/real/react.min.js
  samples/real/hanzi-chai.ts samples/real/mon-entreprise.ts
  samples/synthetic/line-comments.js samples/synthetic/strings.js samples/synthetic/cn-dense.ts
)
