#!/usr/bin/env bash
# 吞吐基准：my-scanner vs yuku lexer（同进程、同文件、对称口径）。
#
#   scripts/bench.sh                          # corpus 全部大文件，默认 10 轮取最优
#   scripts/bench.sh --repeats=30 foo.js      # 自定义轮数与文件
#   scripts/bench.sh --refresh-baselines      # 强制重跑第三方基线（默认命中本地缓存）
#   scripts/bench.sh --submit                 # 完整矩阵 + swc/oxc 对照 + 发布到 bench-reports（channel=local）
#
# yuku 基线由 scripts/prepare-baselines.sh 准备（yuku_old 钉 v0.10.1，
# yuku-main 跟踪上游 HEAD）；第三方结果缓存在 .bench-deps/，基线版本、
# 语料、轮数或 zig 版本变动都会自动失效，仅本地迭代用（CI 总是实跑）。
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/prepare-baselines.sh
source scripts/corpus-files.sh

DEFAULT_FILES=(corpus/real/typescript.min.js corpus/real/typescript.js corpus/real/checker.ts corpus/real/react.js corpus/real/lib.dom.d.ts)

# 分离 flag 与文件；没有文件时用默认 corpus
SUBMIT=0
ARGS=()
FILES=()
for a in "$@"; do
  case "$a" in
    --submit) SUBMIT=1 ;;
    *)
      ARGS+=("$a")
      case "$a" in --*) ;; *) FILES+=("$a") ;; esac
      ;;
  esac
done

if [ "$SUBMIT" = 0 ]; then
  if [ ${#FILES[@]} -eq 0 ]; then
    ARGS+=("${DEFAULT_FILES[@]}")
  fi
  echo "==> zig build bench（ReleaseFast）"
  exec zig build -Doptimize=ReleaseFast bench -- "${ARGS[@]}"
fi

# ---- --submit：完整矩阵 + 汇总发布到 bench-reports（本机 run）----
if [ ${#FILES[@]} -eq 0 ]; then
  FILES=("${CORPUS_FILES[@]}")
fi
REPEATS=10
for a in "${ARGS[@]}"; do
  case "$a" in --repeats=*) REPEATS="${a#--repeats=}" ;; esac
done
OUT=build/bench
mkdir -p "$OUT"

echo "==> [1/3] 架构矩阵基准（x${REPEATS} 取最优）"
zig build -Doptimize=ReleaseFast bench -- "${ARGS[@]}" --json="$OUT/zig.json" "${FILES[@]}"

echo
echo "==> [2/3] swc/oxc 对照（lexbench-rs 决策注入驱动，走本地缓存）"
# 本地 cargo 可能不在 PATH（ ~/.cargo/bin 标准位置则补上）
if ! command -v cargo >/dev/null 2>&1 && [ -x "$HOME/.cargo/bin/cargo" ]; then
  export PATH="$HOME/.cargo/bin:$PATH"
fi
zig build # --emit-regex-starts 的 CLI
scripts/prepare-lexbench.sh
DEC=build/lexbench-corpus
mkdir -p "$DEC"
for f in "${FILES[@]}"; do
  zig-out/bin/my-scanner --emit-regex-starts "$f" > "$DEC/$(basename "$f").regex"
done
( cd tools/lexbench-rs && cargo build --release )
node scripts/run-rs-bench.mjs --repeats="$REPEATS" --regex-dir="$DEC" --json="$OUT/rs.json" "${FILES[@]}"

echo
echo "==> [3/3] 汇总并发布（channel=local，机器标识入 data.json）"
node scripts/make-report.mjs "$OUT/zig.json" --rs "$OUT/rs.json" --out "$OUT" --repeats "$REPEATS"
node scripts/publish-report.mjs --dir "$OUT"
