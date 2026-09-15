#!/usr/bin/env bash
# CI 全链路:单元测试 → 全变体差分(正确性门禁) → 架构矩阵基准 → 汇总报告。
#
#   scripts/ci-bench.sh            # 本地同样可跑
#
# 产物(build/bench/):
#   zig.json   — bench 原始数据
#   data.json  — 单 run 结构化数据(趋势页累积用)
#   report.md  — 人读报告
#
# 环境变量:
#   BENCH_REPEATS   每实现计时轮数(默认 25,CI 噪声压制取最优)
#   SKIP_DIFF=1     跳过差分门禁(仅调试用)
set -euo pipefail
cd "$(dirname "$0")/.."

REPEATS="${BENCH_REPEATS:-25}"
OUT=build/bench
mkdir -p "$OUT"

echo "==== [1/4] zig build test ===="
zig build test

echo
echo "==== [2/4] zig build(CLI)==="
zig build

echo
echo "==== [3/4] 差分门禁:全部架构变体 vs tsc ===="
if [ "${SKIP_DIFF:-0}" != "1" ]; then
  for v in two_phase scalar jump_vec; do
    echo "---- variant: $v ----"
    node tools/compare-tsc.mjs --variant="$v" corpus/*.js corpus/*.ts
  done
else
  echo "(SKIP_DIFF=1,跳过——数字仅作参考)"
fi

echo
echo "==== [4/4] 架构矩阵基准(x${REPEATS} 取最优)==="
# yuku 源码由 bench.sh 的同款逻辑准备(.bench-deps/,已 gitignore)
if [ ! -f .bench-deps/yuku/src/parser/lexer.zig ] || [ ! -f .bench-deps/yuku-main/src/parser/lexer.zig ]; then
  mkdir -p .bench-deps
  [ -f .bench-deps/yuku/src/parser/lexer.zig ] || {
    git clone --depth 1 https://github.com/yuku-toolchain/yuku .bench-deps/yuku
    rm -rf .bench-deps/yuku/.git
  }
  [ -f .bench-deps/yuku-main/src/parser/lexer.zig ] || {
    git clone --depth 5 https://github.com/yuku-toolchain/yuku .bench-deps/yuku-main
    rm -rf .bench-deps/yuku-main/.git
  }
fi
zig build -Doptimize=ReleaseFast bench -- --repeats="$REPEATS" --json="$OUT/zig.json" \
  corpus/typescript.js corpus/checker.ts corpus/react.js corpus/lib.dom.d.ts \
  corpus/line-comments.js corpus/strings.js corpus/cn-dense.ts

echo
echo "==== 汇总报告 ===="
# swc/oxc 的 lexbench 数据暂不接入:独立 lexer 无法注入正则/除号决策,
# minified 语料上会误判吞并(见 docs/architecture.md TODO)。接入条件:
# 给 swc/oxc 写决策注入驱动(等价 yuku 的 reScanAsRegex 对拍)。
node scripts/make-report.mjs "$OUT/zig.json" --out "$OUT" --repeats "$REPEATS"

echo
echo "报告: $OUT/report.md"
