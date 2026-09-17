#!/usr/bin/env bash
# 样本准备：从 samples 分支拉取样本并 sha256 校验。幂等：齐备且校验通过即跳过。
#
#   scripts/prepare-samples.sh
#
# 样本唯一权威存储是 samples 分支(由 scripts/publish-samples.mjs 发布,
# 只含样本不含源码)。check.sh / ci-bench.sh 在差分测试/基准前调用本脚本。
# 注意:校验失败时会以分支内容整体重建 samples/ —— 本地改动请走
# publish-samples 流程,不要直接改 samples/。
set -euo pipefail
cd "$(dirname "$0")/.."

SHA256SUM="$(command -v sha256sum || true)"
if [ -z "$SHA256SUM" ]; then
  command -v shasum >/dev/null && SHA256SUM="shasum -a 256"
fi
[ -n "$SHA256SUM" ] || { echo "缺少 sha256sum/shasum,无法校验样本"; exit 1; }

verify() { (cd samples && $SHA256SUM -c --status sha256sums.txt); }

if [ -f samples/sha256sums.txt ] && verify; then
  exit 0
fi

echo "==> samples 缺失或校验失败,从 samples 分支拉取"
REF=samples
if ! git rev-parse --verify --quiet samples >/dev/null; then
  git fetch --depth 1 origin samples:refs/remotes/origin/samples || {
    echo "拉取 samples 分支失败(离线且无本地分支)。请联网后重试。"; exit 1; }
  REF=origin/samples
fi
rm -rf samples
mkdir -p samples
git archive "$REF" | tar -x -C samples
verify
echo "==> samples 就绪(real $(ls samples/real | wc -l | tr -d ' ') 个 + synthetic $(ls samples/synthetic | wc -l | tr -d ' ') 个,sha256 校验通过)"
