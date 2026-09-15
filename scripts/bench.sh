#!/usr/bin/env bash
# 吞吐基准：my-scanner vs yuku lexer（同进程、同文件、对称口径）。
#
#   scripts/bench.sh                          # corpus 全部大文件，默认 10 轮取最优
#   scripts/bench.sh --repeats=30 foo.js      # 自定义轮数与文件
#
# 首次运行会 clone yuku 源码到 .bench-deps/yuku（已 gitignore）。
set -euo pipefail
cd "$(dirname "$0")/.."

YUKU_DIR=.bench-deps/yuku
YUKU_MAIN_DIR=.bench-deps/yuku-main
if [ ! -f "$YUKU_DIR/src/parser/lexer.zig" ]; then
  echo "==> clone yuku 基线快照（供 bench 引用其 lexer 源码）"
  mkdir -p .bench-deps
  git clone --depth 1 https://github.com/yuku-toolchain/yuku "$YUKU_DIR"
  rm -rf "$YUKU_DIR/.git"
fi
if [ ! -f "$YUKU_MAIN_DIR/src/parser/lexer.zig" ]; then
  echo "==> clone yuku 主干（含 perf(lexer) 向量化提交）"
  git clone --depth 5 https://github.com/yuku-toolchain/yuku "$YUKU_MAIN_DIR"
  rm -rf "$YUKU_MAIN_DIR/.git"
fi

DEFAULT_FILES=(corpus/real/typescript.min.js corpus/real/typescript.js corpus/real/checker.ts corpus/real/react.js corpus/real/lib.dom.d.ts)

# 分离 flag 与文件；没有文件时用默认 corpus
ARGS=()
FILES=()
for a in "$@"; do
  ARGS+=("$a")
  case "$a" in --*) ;; *) FILES+=("$a") ;; esac
done
if [ ${#FILES[@]} -eq 0 ]; then
  ARGS+=("${DEFAULT_FILES[@]}")
fi

echo "==> zig build bench（ReleaseFast）"
exec zig build -Doptimize=ReleaseFast bench -- "${ARGS[@]}"
