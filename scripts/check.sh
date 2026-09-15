#!/usr/bin/env bash
# 正确性判定：单元测试 + 每个架构变体与 tsc scanner 的 token 级差分对比。
#
#   scripts/check.sh                 # 单测 + 全部变体 × corpus 全部文件
#   scripts/check.sh foo.js bar.ts   # 指定文件
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==== zig build test ===="
zig build test

echo
echo "==== zig build（对拍用新编译的 CLI）===="
zig build

echo
echo "==== 差分对比 vs tsc scanner（全部架构变体）===="
# two_phase 是主线，scalar / jump_vec 是并行演化中的架构变体；
# 每条线都必须差分全绿，语义漂移在此拦截。
VARIANTS=(two_phase scalar jump_vec)
if [ $# -gt 0 ]; then
  for v in "${VARIANTS[@]}"; do
    echo "---- variant: $v ----"
    node tools/compare-tsc.mjs --variant="$v" "$@"
  done
else
  for v in "${VARIANTS[@]}"; do
    echo "---- variant: $v ----"
    node tools/compare-tsc.mjs --variant="$v" corpus/*.js corpus/*.ts
  done
fi
