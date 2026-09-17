#!/usr/bin/env bash
# 正确性判定：单元测试 + 每个架构变体与 tsc scanner 的 token 级差分测试。
#
#   scripts/check.sh                 # 单测 + 全部变体 × 全部样本文件
#   scripts/check.sh foo.js bar.ts   # 指定文件
set -euo pipefail
cd "$(dirname "$0")/.."

# 样本来自 samples 分支,缺失时自动拉取(幂等)
scripts/prepare-samples.sh

echo "==== zig build test ===="
zig build test

echo
echo "==== zig build（对照用新编译的 CLI）===="
zig build

echo
echo "==== 差分测试 vs tsc scanner（全部架构变体）===="
# scalar / jump_vec / two_phase / bitmap 四个架构变体并行演化；
# 每条线都必须校验通过，语义漂移在此拦截。
VARIANTS=(two_phase scalar jump_vec bitmap)
if [ $# -gt 0 ]; then
  for v in "${VARIANTS[@]}"; do
    echo "---- variant: $v ----"
    node tools/compare-tsc.mjs --variant="$v" "$@"
  done
else
  # real(真实样本)与 synthetic(构造极端样本)全部参与差分测试
  for v in "${VARIANTS[@]}"; do
    echo "---- variant: $v ----"
    node tools/compare-tsc.mjs --variant="$v" samples/real/*.js samples/real/*.ts samples/synthetic/*.js samples/synthetic/*.ts
  done
fi
