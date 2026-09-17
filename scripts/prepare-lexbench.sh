#!/usr/bin/env bash
# 准备 lexbench-rs 的第三方依赖（幂等；全部落在 .bench-deps/，已 gitignore）：
#
# 版本策略 —— 自动跟踪（2026-09-17 起，见 docs/benchmarks.md「第三方版本」）：
#   swc / oxc  —— 每跑查 crates.io sparse index，有新版即改写
#                 tools/lexbench-rs/Cargo.toml 的锚钉版（=ver）并 cargo update
#                 落到 Cargo.lock（锁即实测版本，报告 deps 戳与之同源）；
#                 探测失败（离线）则警告并沿用现有钉版，不阻塞本地复现。
#   oxc_lexer  —— 孵化期 publish=false 不上 crates.io，跟踪 oxc 仓 main 分支：
#                 ls-remote 探测，分支移动才重拉源码树 + 重打 NEON patch；
#                 探测失败（离线）沿用现有副本。
#   LEXBENCH_PIN=1 显式关掉全部探测（钉版与源码树都不动）：复现既有 run、
#   或上游升版把 patch 打断又暂时没空 rebase 时的逃生门。
#
# 1) oxc_parser vendored 副本（固定路径 .bench-deps/oxc_parser，内容随跟踪移动）：
#    决策注入驱动需要把 oxc 的 next_regex / next_template_substitution_tail
#    从 pub(crate) 改为 pub（上游不暴露 re-lex 入口；swc 有公开 input::Tokens
#    trait 故无需 patch）。流程：下载 crates.io 官方 .crate → 与 index cksum
#    校验 sha256 → 解包 → sed 打 2 行可见性 patch → 校验，全部成功才换目录；
#    Cargo.toml 的 [patch.crates-io] 指向该目录。
# 2) oxc 仓源码树 .bench-deps/oxc（跟踪 main）：oxc_lexer 的 manifest 用
#    workspace 继承，故保留 crates/ 整树 + 根 Cargo.toml；提取后应用本仓库
#    维护的 aarch64 NEON 后端 patch（tools/lexbench-rs/oxc-lexer-neon-aarch64.patch），
#    校验通过才落 .bench-deps/oxc.sha 版本标记。
#
# 任一步失败（下载 / 校验 / patch / 落锁）都 exit 1，绝不静默沿用半成品状态；
# 升版改写的 Cargo.toml 在失败时回滚，工作树不停在「钉版已改、锁未跟」的中间态。
set -euo pipefail
cd "$(dirname "$0")/.."

MANIFEST=tools/lexbench-rs/Cargo.toml
LOCK=tools/lexbench-rs/Cargo.lock
MANIFEST_BAK=.bench-deps/Cargo.toml.bak
mkdir -p .bench-deps

# 本地 cargo 可能不在 PATH（~/.cargo/bin 标准位置则补上；CI 由 toolchain step 提供）
if ! command -v cargo >/dev/null 2>&1 && [ -x "$HOME/.cargo/bin/cargo" ]; then
  export PATH="$HOME/.cargo/bin:$PATH"
fi

# 跨平台 sed -i（GNU 无参数，BSD 需要 ''）
if sed --version 2>/dev/null | grep -q GNU; then
  SEDI=(sed -i)
else
  SEDI=(sed -i '')
fi

# ---------- 工具函数 ----------

# $1=crate → sparse index URL（index.crates.io 是 CDN，无 UA / 限流要求）
index_url() { printf 'https://index.crates.io/%s/%s/%s\n' "${1:0:2}" "${1:2:2}" "$1"; }

# $1=crate → 最新稳定版（非 yanked、无 prerelease 后缀）；探测失败返回非零
crate_latest() {
  local body latest
  body=$(curl -fsSL --max-time 20 "$(index_url "$1")") || return 1
  latest=$(printf '%s\n' "$body" \
    | grep -v '"yanked":true' \
    | sed -n 's/.*"vers":"\([^"]*\)".*/\1/p' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -t. -k1,1n -k2,2n -k3,3n | tail -1) || return 1
  [ -n "$latest" ] || return 1
  printf '%s\n' "$latest"
}

# $1=crate $2=版本 → index 记录的 .crate sha256；取不到返回非零
crate_cksum() {
  local ck
  ck=$(curl -fsSL --max-time 20 "$(index_url "$1")" \
    | grep -F "\"vers\":\"$2\"" \
    | sed -n 's/.*"cksum":"\([^"]*\)".*/\1/p' | tail -1) || return 1
  [ -n "$ck" ] || return 1
  printf '%s\n' "$ck"
}

# $1=文件 → sha256（sha256sum 优先，macOS 退回 shasum）
file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# $1=crate → Cargo.lock 里的版本（实际参与构建的版本）
lock_version() {
  awk -v n="$1" '$0 == "name = \"" n "\"" { p = 1; next } p && $1 == "version" { gsub(/"/, "", $3); print $3; exit }' "$LOCK"
}

# $1=crate → Cargo.toml 里的钉版（去掉前导 =；BSD sed 的 BRE 不认 \?，用 -E）
manifest_pin() {
  sed -nE "s/^$1 = \"(=)?([^\"]*)\".*/\2/p; s/^$1 = \{ version = \"(=)?([^\"]*)\".*/\2/p" "$MANIFEST" | head -1
}

# $1=crate $2=版本 → 把 Cargo.toml 里该 crate 的钉版改成 =<ver>（写后校验）
set_pin() {
  "${SEDI[@]}" -E \
    "s|^($1 = \")[^\"]*(\")|\1=$2\2|; s|^($1 = \{ version = \")[^\"]*(\")|\1=$2\2|" "$MANIFEST"
  if ! grep -qF "$1 = \"=$2\"" "$MANIFEST" && ! grep -qF "$1 = { version = \"=$2\"" "$MANIFEST"; then
    echo "error: Cargo.toml 钉版改写失败（$1=$2，行形态已变？）" >&2
    exit 1
  fi
}

# 失败时回滚 Cargo.toml（成功路径上显式删备份即撤销）
rollback_manifest() {
  if [ -f "$MANIFEST_BAK" ]; then
    cp "$MANIFEST_BAK" "$MANIFEST"
    rm -f "$MANIFEST_BAK"
  fi
}

# ---------- 0) crates.io 探测（best-effort；离线沿用现有钉版）----------
# LEXBENCH_PIN=1：显式跳过全部上游探测（crates.io 与 oxc main 都不动），沿用
# 现有钉版与源码树——复现既有 run、或上游升版导致 patch 暂时不适配时的逃生门。
PIN_MODE=${LEXBENCH_PIN:-0}
probe_fail=0
if [ "$PIN_MODE" = 1 ]; then
  echo "note: LEXBENCH_PIN=1——跳过上游探测，沿用现有钉版与 oxc 源码树" >&2
  OXC_TARGET=$(manifest_pin oxc_parser)
  SWC_TARGET=$(manifest_pin swc_ecma_parser)
else
  OXC_TARGET=$(crate_latest oxc_parser) || { OXC_TARGET=""; probe_fail=1; }
  SWC_TARGET=$(crate_latest swc_ecma_parser) || { SWC_TARGET=""; probe_fail=1; }
fi
if [ "$probe_fail" = 1 ]; then
  echo "warning: crates.io 探测失败（离线？），未探到的锚沿用现有钉版" >&2
  [ -n "$OXC_TARGET" ] || OXC_TARGET=$(manifest_pin oxc_parser)
  [ -n "$SWC_TARGET" ] || SWC_TARGET=$(manifest_pin swc_ecma_parser)
fi

# ---------- 1) oxc_parser vendored 副本 ----------
VENDOR=.bench-deps/oxc_parser

vendored_version() {
  [ -f "$VENDOR/Cargo.toml" ] || return 1
  sed -n 's/^version = "\(.*\)"/\1/p' "$VENDOR/Cargo.toml" | head -1
}

# $1=目标版本：下载 + cksum 校验 + 2 行可见性 patch + 校验，全过才换目录
vendor_oxc_parser() {
  local ver="$1" cksum got crate regex template
  crate=".bench-deps/oxc_parser-$ver.crate"
  cksum=$(crate_cksum oxc_parser "$ver") || {
    echo "error: 取不到 oxc_parser $ver 的 index cksum，拒绝未校验的 vendored 副本" >&2
    return 1
  }
  echo "==> vendor oxc_parser ${ver}（决策注入 2 行可见性 patch）"
  rm -rf "$VENDOR.tmp"
  mkdir -p "$VENDOR.tmp"
  curl -fsSL "https://static.crates.io/crates/oxc_parser/oxc_parser-$ver.crate" -o "$crate"
  got=$(file_sha256 "$crate")
  if [ "$got" != "$cksum" ]; then
    echo "error: oxc_parser ${ver} .crate sha256 不符（index ${cksum}，实际 ${got}）" >&2
    rm -rf "$VENDOR.tmp" "$crate"
    return 1
  fi
  tar xzf "$crate" -C "$VENDOR.tmp" --strip-components=1
  rm -f "$crate"

  regex="$VENDOR.tmp/src/lexer/regex.rs"
  template="$VENDOR.tmp/src/lexer/template.rs"
  if [ ! -f "$regex" ] || [ ! -f "$template" ]; then
    echo "error: oxc_parser $ver 源码布局已变（缺 src/lexer/regex.rs 或 template.rs），需人工核对 patch" >&2
    rm -rf "$VENDOR.tmp"
    return 1
  fi
  "${SEDI[@]}" 's/    pub(crate) fn next_regex(&mut self, kind: Kind)/    pub fn next_regex(\&mut self, kind: Kind)/' "$regex"
  "${SEDI[@]}" 's/    pub(crate) fn next_template_substitution_tail(&mut self) -> Token {/    pub fn next_template_substitution_tail(\&mut self) -> Token {/' "$template"
  if ! grep -q "pub fn next_regex" "$regex" || ! grep -q "pub fn next_template_substitution_tail" "$template"; then
    echo "error: oxc_parser $ver 可见性 patch 未生效（上游源码已变？需人工核对 regex.rs / template.rs）" >&2
    rm -rf "$VENDOR.tmp"
    return 1
  fi
  rm -rf "$VENDOR"
  mv "$VENDOR.tmp" "$VENDOR"
}

cur_vendored=$(vendored_version) || cur_vendored=""
if [ "$cur_vendored" != "$OXC_TARGET" ]; then
  vendor_oxc_parser "$OXC_TARGET" || exit 1
fi
# 旧版路径（.bench-deps/oxc_parser-<ver>）已废弃，留着白占空间/误导排查
for d in .bench-deps/oxc_parser-*; do
  [ -d "$d" ] || continue
  echo "提示: 旧 vendored 目录 $d 已废弃（现用 .bench-deps/oxc_parser），可删除" >&2
done

# ---------- 2) oxc 源码树（跟踪 main；oxc_lexer 多位图流水线实验 crate）----------
OXC_REPO=https://github.com/oxc-project/oxc
OXC_BRANCH=main
OXC_DIR=.bench-deps/oxc
SHA_MARK=.bench-deps/oxc.sha
LEX_DIR="$OXC_DIR/crates/oxc_lexer"
NEON_PATCH=tools/lexbench-rs/oxc-lexer-neon-aarch64.patch

# $1=oxc_lexer crate 目录 → NEON patch 是否完整生效（四个后端文件 + 四趟接线
# + chunk primitives + lib.rs IS_SIMD；半打状态一律不合格）
lexer_patched() {
  local d="$1"
  [ -f "$d/src/pipeline/classify/aarch64.rs" ] || return 1
  [ -f "$d/src/pipeline/find/aarch64.rs" ] || return 1
  [ -f "$d/src/pipeline/scan/aarch64.rs" ] || return 1
  [ -f "$d/src/pipeline/compress/aarch64.rs" ] || return 1
  grep -q aarch64 "$d/src/lib.rs" || return 1
  grep -q primitives_neon "$d/src/pipeline/chunk.rs" || return 1
  grep -q aarch64 "$d/src/pipeline/classify/mod.rs" || return 1
  grep -q aarch64 "$d/src/pipeline/find/mod.rs" || return 1
  grep -q aarch64 "$d/src/pipeline/scan/mod.rs" || return 1
  grep -q aarch64 "$d/src/pipeline/compress/mod.rs" || return 1
}

recorded=""
[ -f "$SHA_MARK" ] && recorded=$(cat "$SHA_MARK")
upstream=""
[ "$PIN_MODE" = 1 ] || upstream=$(git -c http.timeout=8 ls-remote "$OXC_REPO" "refs/heads/$OXC_BRANCH" 2>/dev/null | cut -f1 || true)
if [ -n "$upstream" ]; then
  want="$upstream"
elif [ -n "$recorded" ] && lexer_patched "$LEX_DIR"; then
  [ "$PIN_MODE" = 1 ] || echo "warning: oxc ls-remote 失败（离线？），沿用现有源码树 ${recorded:0:10}" >&2
  want="$recorded"
else
  echo "error: 探测 oxc $OXC_BRANCH 失败且本地无可用源码树（离线？）" >&2
  exit 1
fi

if [ "$want" = "$recorded" ] && lexer_patched "$LEX_DIR"; then
  echo "==> oxc 源码树就绪 @ ${want:0:10}（$OXC_BRANCH + NEON patch）"
else
  echo "==> 拉取 oxc $OXC_BRANCH @ ${want:0:10}（oxc_lexer 实验 crate）"
  rm -rf "$OXC_DIR.tmp" "$OXC_DIR.tgz"
  mkdir -p "$OXC_DIR.tmp"
  curl -fsSL "https://codeload.github.com/oxc-project/oxc/tar.gz/$want" -o "$OXC_DIR.tgz"
  tar xzf "$OXC_DIR.tgz" -C "$OXC_DIR.tmp" --strip-components=1 "oxc-$want/crates" "oxc-$want/Cargo.toml"
  rm -f "$OXC_DIR.tgz"

  echo "==> 应用 oxc_lexer aarch64 NEON 后端 patch"
  patch_log=.bench-deps/oxc-patch.log
  if ! patch -p1 -d "$OXC_DIR.tmp/crates/oxc_lexer" <"$(pwd)/$NEON_PATCH" >"$patch_log" 2>&1; then
    rm -rf "$OXC_DIR.tmp"
    echo "error: NEON patch 应用失败（$NEON_PATCH 针对的布局已变，需按上游改动 rebase）:" >&2
    tail -5 "$patch_log" >&2
    exit 1
  fi
  # 要求干净应用：fuzz（模糊匹配会静默丢上下文）或 .orig/.rej 残留一律当失败，
  # 报错请人按当前 oxc main rebase patch，而不是带着可疑结果往下跑
  if grep -qi fuzz "$patch_log" || [ -n "$(find "$OXC_DIR.tmp/crates/oxc_lexer" -name '*.orig' -o -name '*.rej' 2>/dev/null)" ]; then
    rm -rf "$OXC_DIR.tmp"
    echo "error: NEON patch 非干净应用（fuzz 或 .orig/.rej 残留），需按当前 oxc main rebase $NEON_PATCH" >&2
    exit 1
  fi
  if ! lexer_patched "$OXC_DIR.tmp/crates/oxc_lexer"; then
    rm -rf "$OXC_DIR.tmp"
    echo "error: NEON patch 未完整生效（四趟接线或后端文件缺失，需人工核对）" >&2
    exit 1
  fi
  rm -rf "$OXC_DIR"
  mv "$OXC_DIR.tmp" "$OXC_DIR"
  printf '%s\n' "$want" >"$SHA_MARK" # 完整就绪才落版本标记
  echo "==> $OXC_DIR 就绪 @ ${want:0:10}（$OXC_BRANCH + NEON patch）"
fi

# ---------- 3) 锚钉版改写 + cargo 落锁 ----------
NEED_UPDATE=0
[ "$OXC_TARGET" = "$(manifest_pin oxc_parser)" ] || NEED_UPDATE=1
[ "$SWC_TARGET" = "$(manifest_pin swc_ecma_parser)" ] || NEED_UPDATE=1

if [ "$NEED_UPDATE" = 1 ]; then
  command -v cargo >/dev/null 2>&1 || {
    echo "error: 升版需要 cargo 落锁，但 PATH 里没有 cargo" >&2
    exit 1
  }
  cp "$MANIFEST" "$MANIFEST_BAK"
  trap rollback_manifest EXIT
  set_pin oxc_parser "$OXC_TARGET"
  set_pin swc_ecma_parser "$SWC_TARGET"
  echo "==> 第三方升版: oxc_parser → ${OXC_TARGET}、swc_ecma_parser → ${SWC_TARGET}（cargo update 落锁）"
  if ! (cd tools/lexbench-rs && cargo update -p oxc_parser -p swc_ecma_parser -p swc_ecma_ast -p swc_common); then
    echo "error: cargo update 失败（网络 / 解析？），Cargo.toml 已回滚" >&2
    exit 1
  fi
  rm -f "$MANIFEST_BAK" # 撤销回滚点
fi

echo "==> 第三方版本: oxc_parser $(lock_version oxc_parser) + swc_ecma_parser $(lock_version swc_ecma_parser)（vendored / Cargo.lock）/ oxc_lexer @ ${want:0:10}"
