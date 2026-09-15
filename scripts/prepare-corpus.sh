#!/usr/bin/env bash
# 语料准备：从 corpus 分支拉取语料并 sha256 校验。幂等：齐备且校验通过即跳过。
#
#   scripts/prepare-corpus.sh
#
# 语料唯一权威存储是 corpus 分支(由 scripts/publish-corpus.mjs 发布,
# 只含语料不含源码)。check.sh / ci-bench.sh 在差分/基准前调用本脚本。
# 注意:校验失败时会以分支内容整体重建 corpus/ —— 本地改动请走
# publish-corpus 流程,不要直接改 corpus/。
set -euo pipefail
cd "$(dirname "$0")/.."

SHA256SUM="$(command -v sha256sum || true)"
if [ -z "$SHA256SUM" ]; then
  command -v shasum >/dev/null && SHA256SUM="shasum -a 256"
fi
[ -n "$SHA256SUM" ] || { echo "缺少 sha256sum/shasum,无法校验语料"; exit 1; }

verify() { (cd corpus && $SHA256SUM -c --status sha256sums.txt); }

if [ -f corpus/sha256sums.txt ] && verify; then
  exit 0
fi

echo "==> corpus 缺失或校验失败,从 corpus 分支拉取"
REF=corpus
if ! git rev-parse --verify --quiet corpus >/dev/null; then
  git fetch --depth 1 origin corpus:refs/remotes/origin/corpus || {
    echo "拉取 corpus 分支失败(离线且无本地分支)。请联网后重试。"; exit 1; }
  REF=origin/corpus
fi
rm -rf corpus
mkdir -p corpus
git archive "$REF" | tar -x -C corpus
verify
echo "==> corpus 就绪(real $(ls corpus/real | wc -l | tr -d ' ') 个 + synthetic $(ls corpus/synthetic | wc -l | tr -d ' ') 个,sha256 校验通过)"
