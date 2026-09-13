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
if [ ! -f "$YUKU_DIR/src/parser/lexer.zig" ]; then
  echo "==> clone yuku（供 bench 引用其 lexer 源码）"
  mkdir -p .bench-deps
  git clone --depth 1 https://github.com/yuku-toolchain/yuku "$YUKU_DIR"
  rm -rf "$YUKU_DIR/.git"
fi

DEFAULT_FILES=(corpus/typescript.js corpus/checker.ts corpus/react.js corpus/lib.dom.d.ts)

echo "==> zig build bench（ReleaseFast）"
# shellcheck disable=SC2086
exec zig build -Doptimize=ReleaseFast bench -- \
  $(if [ $# -eq 0 ]; then echo "${DEFAULT_FILES[*]}"; else echo "$*"; fi)
