#!/usr/bin/env bash
# 准备 lexbench-rs 的 oxc vendored 副本：决策注入驱动需要把 oxc 的
# next_regex / next_template_substitution_tail 从 pub(crate) 改为 pub
# （上游不暴露 re-lex 入口，swc 有公开 input::Tokens trait 故无需 patch）。
# 流程：下载 crates.io 官方 .crate → sha256 校验 → 解到
# .bench-deps/oxc_parser-<VER>/（gitignore）→ sed 打 2 行可见性 patch。
# 幂等：已打好 patch 则跳过。Cargo.toml 的 [patch.crates-io] 指向该目录。
set -euo pipefail
cd "$(dirname "$0")/.."

VER=0.150.0
DIR=".bench-deps/oxc_parser-$VER"
URL="https://static.crates.io/crates/oxc_parser/oxc_parser-$VER.crate"
# crates.io index 的 cksum（与 Cargo.lock 历史值一致）
SHA256=44083f63120e1abe371cddd4eb209a580ab8490c2e5b42cacc11e7fe6fd1e7c2

if [ -f "$DIR/src/lexer/regex.rs" ] && grep -q "pub fn next_regex" "$DIR/src/lexer/regex.rs"; then
  exit 0
fi

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
