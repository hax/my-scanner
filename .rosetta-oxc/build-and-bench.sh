#!/usr/bin/env bash
# 在 Apple Silicon (arm64) 本机交叉编译 oxc_lexer 的 x86_64 AVX2+BMI2 形态，
# 用 Rosetta 跑 lexbench-rs drive，产出 11 个语料的 oxc_bitmap 同机基线。
#
# 口径对齐 CI（scripts/ci-bench.sh + bench.sh + run-rs-bench.mjs）：
# - RUSTFLAGS="-C target-feature=+avx2,+bmi2"（ci-bench.sh:84 / bench.sh:71）
# - cargo build --release（opt-level=3 + thin LTO + codegen-units=1，Cargo.toml）
# - repeats=25 取最优（ci-bench.sh 默认 BENCH_REPEATS=25）
# - options 按 drive.rs drive_oxc_bitmap：module=true、ts 对 .ts 开、jsx 对
#   .tsx/.jsx 开、validate_utf8=false、arena 轮外创建跨轮复用（drive.rs 内置）
#
# oxc_bitmap 不接受决策注入（正则/除号由内部 disambiguate pass 自决，
# 见 drive.rs 头注），故不传 --regex-dir，swc/oxc 两列数字与本实验无关。
#
# 用法: bash .rosetta-oxc/build-and-bench.sh [--skip-build]
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET=x86_64-apple-darwin
REPEATS=25
OUT=.rosetta-oxc
BIN="tools/lexbench-rs/target/$TARGET/release/drive"

# CI 同款 flags：oxc_lexer 的 IS_SIMD = cfg!(x86_64 + avx2 + bmi2)，编译期生效
export RUSTFLAGS="-C target-feature=+avx2,+bmi2${RUSTFLAGS:+ $RUSTFLAGS}"

if [ "${1:-}" != "--skip-build" ]; then
  echo "==> 交叉编译 lexbench-rs (x86_64-apple-darwin, RUSTFLAGS=$RUSTFLAGS)"
  ( cd tools/lexbench-rs && cargo build --release --target "$TARGET" )
fi

file "$BIN"
echo "==> Rosetta 运行 drive (repeats=$REPEATS)"
# stderr 单独留档：若出现「generic fallback 仅供 smoke」说明 SIMD 未生效
arch -x86_64 "$BIN" --repeats="$REPEATS" \
  --json="$OUT/rs-rosetta-x86_64.raw.json" \
  corpus/real/checker.ts \
  corpus/real/hanzi-chai.ts \
  corpus/real/lib.dom.d.ts \
  corpus/real/mon-entreprise.ts \
  corpus/real/react.js \
  corpus/real/react.min.js \
  corpus/real/typescript.js \
  corpus/real/typescript.min.js \
  corpus/synthetic/cn-dense.ts \
  corpus/synthetic/line-comments.js \
  corpus/synthetic/strings.js \
  2> "$OUT/drive.stderr.log"

if grep -q "generic fallback" "$OUT/drive.stderr.log"; then
  echo "FATAL: SIMD 未生效（IS_SIMD=false，走了 generic fallback）" >&2
  exit 1
fi
echo "==> stderr 无 fallback 警告，SIMD 生效"
echo "==> 换算 .rosetta-oxc/results.json"
node "$OUT/make-results.mjs"
