#!/usr/bin/env bash
# 正确性判定：单元测试 + 与 tsc scanner 的 token 级差分对比。
#
#   scripts/check.sh                 # corpus 全部文件
#   scripts/check.sh foo.js bar.ts   # 指定文件
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==== zig build test ===="
zig build test

echo
echo "==== zig build（对拍用新编译的 CLI）===="
zig build

echo
echo "==== 差分对比 vs tsc scanner ===="
if [ $# -gt 0 ]; then
  exec node tools/compare-tsc.mjs "$@"
else
  exec node tools/compare-tsc.mjs corpus/*.js corpus/*.ts
fi
