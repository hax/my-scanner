#!/usr/bin/env bash
# 准备 lexbench-rs 的两类 oxc 依赖（均幂等、置于 .bench-deps/，gitignore）：
#
# 1) oxc_parser vendored 副本：决策注入驱动需要把 oxc 的
#    next_regex / next_template_substitution_tail 从 pub(crate) 改为 pub
#    （上游不暴露 re-lex 入口，swc 有公开 input::Tokens trait 故无需 patch）。
#    流程：下载 crates.io 官方 .crate → sha256 校验 → 解到
#    .bench-deps/oxc_parser-<VER>/ → sed 打 2 行可见性 patch。
#    Cargo.toml 的 [patch.crates-io] 指向该目录。
# 2) oxc 仓源码树（钉 rev）：oxc_lexer 多位图流水线实验 crate（孵化期
#    publish=false 不上 crates.io），见文件后段。
set -euo pipefail
cd "$(dirname "$0")/.."

VER=0.150.0
DIR=".bench-deps/oxc_parser-$VER"
URL="https://static.crates.io/crates/oxc_parser/oxc_parser-$VER.crate"
# crates.io index 的 cksum（与 Cargo.lock 历史值一致）
SHA256=44083f63120e1abe371cddd4eb209a580ab8490c2e5b42cacc11e7fe6fd1e7c2

if [ ! -f "$DIR/src/lexer/regex.rs" ] || ! grep -q "pub fn next_regex" "$DIR/src/lexer/regex.rs"; then
  echo "==> vendor oxc_parser ${VER}（决策注入 patch）"
rm -rf "$DIR"
mkdir -p .bench-deps
tmp=".bench-deps/oxc_parser-$VER.crate"
curl -fsSL "$URL" -o "$tmp"
if command -v sha256sum >/dev/null 2>&1; then
  echo "$SHA256  $tmp" | sha256sum -c - >/dev/null
else
  echo "$SHA256  $tmp" | shasum -a 256 -c - >/dev/null
fi
tar xzf "$tmp" -C .bench-deps
rm -f "$tmp"

# 跨平台 sed -i（GNU 无参数，BSD 需要 ''）
if sed --version 2>/dev/null | grep -q GNU; then
  SEDI=(sed -i)
else
  SEDI=(sed -i '')
fi
"${SEDI[@]}" 's/    pub(crate) fn next_regex(&mut self, kind: Kind)/    pub fn next_regex(\&mut self, kind: Kind)/' "$DIR/src/lexer/regex.rs"
"${SEDI[@]}" 's/    pub(crate) fn next_template_substitution_tail(&mut self) -> Token {/    pub fn next_template_substitution_tail(\&mut self) -> Token {/' "$DIR/src/lexer/template.rs"

grep -q "pub fn next_regex" "$DIR/src/lexer/regex.rs" || {
  echo "error: patch 未生效（上游源码已变？需人工核对 regex.rs/template.rs）" >&2
  exit 1
}
grep -q "pub fn next_template_substitution_tail" "$DIR/src/lexer/template.rs" || {
  echo "error: patch 未生效（上游源码已变？需人工核对 regex.rs/template.rs）" >&2
  exit 1
}
echo "==> $DIR 就绪"
fi

# ---- oxc 源码树（钉 rev）：oxc_lexer 多位图流水线实验 crate ----
# oxc_lexer 孵化期 publish=false 不上 crates.io，只能取仓内源码；其 manifest
# 用 workspace 继承，故保留 crates/ 整树 + 根 Cargo.toml（path 依赖解析
# workspace 字段与 sibling path 依赖所需）。版本标记 .bench-deps/oxc.sha，
# 换 rev 或目录缺失才重拉（tarball 不校验 sha256，codeload 压缩位不恒定，
# 与 yuku 同以 commit sha 为版本语义）。
OXC_REV=68ce6107d748d086ca09b36ece8b808ccaccc56e
OXC_DIR=.bench-deps/oxc
recorded=""
[ -f .bench-deps/oxc.sha ] && recorded=$(cat .bench-deps/oxc.sha)
if [ "$recorded" != "$OXC_REV" ] || [ ! -d "$OXC_DIR/crates/oxc_lexer" ]; then
  echo "==> fetch oxc 源码树 @ ${OXC_REV:0:10}（oxc_lexer 实验 crate，钉 rev）"
  rm -rf "$OXC_DIR" "$OXC_DIR.tmp"
  mkdir -p "$OXC_DIR.tmp"
  tmp=.bench-deps/oxc.tar.gz
  curl -fsSL "https://codeload.github.com/oxc-project/oxc/tar.gz/$OXC_REV" -o "$tmp"
  tar xzf "$tmp" -C "$OXC_DIR.tmp" --strip-components=1 \
    "oxc-$OXC_REV/crates" "oxc-$OXC_REV/Cargo.toml"
  rm -f "$tmp"
  mv "$OXC_DIR.tmp" "$OXC_DIR"
  echo "$OXC_REV" > .bench-deps/oxc.sha
  echo "==> $OXC_DIR 就绪"
fi
