#!/usr/bin/env bash
# CI 全链路:单元测试 → 全变体差分(正确性门禁) → 架构矩阵基准 →
# swc/oxc 对照(决策注入驱动) → 汇总报告。
#
#   scripts/ci-bench.sh            # 本地同样可跑
#
# 产物(build/bench/):
#   zig.json   — bench 原始数据(my-scanner 变体 + yuku)
#   rs.json    — swc/oxc 原始数据(lexbench-rs 决策注入驱动)
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

# 语料清单:门禁外的基准与 swc/oxc 对照共用(单一来源 scripts/corpus-files.sh)
source scripts/corpus-files.sh

# CI 机器性能漂移,第三方基线(yuku/swc/oxc)必须同 run 实测;
# 缓存只为本地迭代设计,CI 上显式禁用(缓存位于 .bench-deps,CI 本也不会命中)
REFRESH_ZIG=""
REFRESH_RS=""
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  REFRESH_ZIG="--refresh-baselines"
  REFRESH_RS="--refresh"
fi

# 本地 cargo 可能不在 PATH( ~/.cargo/bin 标准位置则补上;CI 由 toolchain step 提供)
if ! command -v cargo >/dev/null 2>&1 && [ -x "$HOME/.cargo/bin/cargo" ]; then
  export PATH="$HOME/.cargo/bin:$PATH"
fi

# 语料来自 corpus 分支,缺失时自动拉取(幂等)
scripts/prepare-corpus.sh

echo "==== [1/5] zig build test ===="
zig build test

echo
echo "==== [2/5] zig build(CLI)==="
zig build

echo
echo "==== [3/5] 差分门禁:全部架构变体 vs tsc ===="
if [ "${SKIP_DIFF:-0}" != "1" ]; then
  for v in two_phase scalar jump_vec; do
    echo "---- variant: $v ----"
    node tools/compare-tsc.mjs --variant="$v" corpus/real/*.js corpus/real/*.ts corpus/synthetic/*.js corpus/synthetic/*.ts
  done
else
  echo "(SKIP_DIFF=1,跳过——数字仅作参考)"
fi

echo
echo "==== [4/5] 架构矩阵基准(x${REPEATS} 取最优)==="
# yuku 基线:yuku_old 钉 v0.10.1,yuku-main 跟踪上游(scripts/prepare-baselines.sh)
scripts/prepare-baselines.sh
zig build -Doptimize=ReleaseFast bench -- --repeats="$REPEATS" $REFRESH_ZIG --json="$OUT/zig.json" "${CORPUS_FILES[@]}"

echo
echo "==== [5/5] 第三方对照(swc/oxc 决策注入 + oxc_bitmap,x${REPEATS} 取最优)==="
# 机制见 docs/architecture.md 的「第三方对照」:my-scanner 预扫产出正则
# 决策集(主流+模板内),驱动 swc(零 patch)/oxc(vendored 2 行 patch)在决策点
# 重扫;模板 ${} 用花括号平衡栈,与 yuku bench 同款口径。oxc_bitmap(oxc_lexer
# 多位图流水线实验 crate)歧义内部自决、不接受注入,进矩阵前须过 spans 门禁。
scripts/prepare-lexbench.sh
DEC=build/lexbench-corpus
mkdir -p "$DEC"
for f in "${CORPUS_FILES[@]}"; do
  zig-out/bin/my-scanner --emit-regex-starts "$f" > "$DEC/$(basename "$f").regex"
done
# oxc_lexer 的 SIMD 核心仅 x86_64 静态 AVX2+BMI2 编译(其余平台 generic
# fallback,数字不代表其实验形态,仅供 smoke)。RUSTFLAGS 对整个 lexbench-rs
# 生效:swc/oxc 此前按 baseline SSE2 编(与 zig native 不对称),同开 avx2/bmi2
# 是向公平修正,趋势断档记 docs/benchmarks.md。
if [ "$(uname -m)" = "x86_64" ]; then
  export RUSTFLAGS="-C target-feature=+avx2,+bmi2${RUSTFLAGS:+ $RUSTFLAGS}"
fi
( cd tools/lexbench-rs && cargo build --release )
if [ "${SKIP_DIFF:-0}" != "1" ]; then
  echo "---- oxc_bitmap spans 门禁(歧义自决策的等价验证) ----"
  node tools/compare-oxc-bitmap.mjs "${CORPUS_FILES[@]}"
fi
node scripts/run-rs-bench.mjs --repeats="$REPEATS" --regex-dir="$DEC" --json="$OUT/rs.json" $REFRESH_RS "${CORPUS_FILES[@]}"

echo
echo "==== 汇总报告 ===="
node scripts/make-report.mjs "$OUT/zig.json" --rs "$OUT/rs.json" --out "$OUT" --repeats "$REPEATS"

echo
echo "报告: $OUT/report.md"
