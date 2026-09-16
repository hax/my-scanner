#!/usr/bin/env bash
# 准备第三方 yuku 基线源码(.bench-deps/,已 gitignore):
#   .bench-deps/yuku       — yuku_old,固定钉在 v0.10.1(引入向量化前的快照,
#                            永不自动更新;CI 曾每次 fresh clone HEAD 漂成
#                            yuku-main 副本,钉版恢复名义语义,趋势断档见
#                            docs/benchmarks.md)
#   .bench-deps/yuku-main  — yuku_main,跟踪上游 HEAD,上游移动才重 clone
#
# 版本标记:clone 时把 commit sha 写入 <dir>.sha,供 bench.zig 缓存键与
# 更新探测用;标记缺失的存量目录视为未知版本,重 clone 一次补齐。
# yuku-main 每次跑用 ls-remote 探测上游(best-effort,离线警告后沿用现有)。
set -euo pipefail
cd "$(dirname "$0")/.."

YUKU_REPO=https://github.com/yuku-toolchain/yuku
YUKU_OLD_REF=v0.10.1
mkdir -p .bench-deps

# $1=dest $2=ref(HEAD 表示上游主干) $3=sha 标记文件
clone_yuku() {
  local dest="$1" ref="$2" shafile="$3"
  rm -rf "$dest"
  if [ "$ref" = HEAD ]; then
    git clone --quiet --depth 1 "$YUKU_REPO" "$dest"
  else
    git clone --quiet --depth 1 --branch "$ref" -c advice.detachedHead=false "$YUKU_REPO" "$dest"
  fi
  git -C "$dest" rev-parse HEAD > "$shafile"
  rm -rf "$dest/.git"
}

# ---- yuku_old:固定版本,标记在即不动 ----
if [ ! -f .bench-deps/yuku.sha ]; then
  echo "==> clone yuku_old(${YUKU_OLD_REF} 固定快照)"
  clone_yuku .bench-deps/yuku "$YUKU_OLD_REF" .bench-deps/yuku.sha
fi

# ---- yuku_main:跟踪上游,上游移动才重 clone ----
main_sha_file=.bench-deps/yuku-main.sha
recorded=""
[ -f "$main_sha_file" ] && recorded=$(cat "$main_sha_file")
upstream=$(git -c http.timeout=8 ls-remote "$YUKU_REPO" HEAD 2>/dev/null | cut -f1 || true)
if [ -z "$recorded" ]; then
  echo "==> clone yuku-main(无版本标记,补齐)"
  clone_yuku .bench-deps/yuku-main HEAD "$main_sha_file"
elif [ -n "$upstream" ] && [ "$upstream" != "$recorded" ]; then
  echo "==> yuku 上游移动 ${recorded:0:10} → ${upstream:0:10},重 clone yuku-main"
  clone_yuku .bench-deps/yuku-main HEAD "$main_sha_file"
elif [ -z "$upstream" ]; then
  echo "warning: ls-remote 失败(离线?),沿用现有 yuku-main(${recorded:0:10})" >&2
fi
