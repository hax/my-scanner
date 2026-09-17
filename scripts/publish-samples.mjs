// 把本地 samples/ 发布到 samples 分支(样本的唯一权威存储,仿 publish-report.mjs)。
//
//   node scripts/publish-samples.mjs          # 渲染生成文件 + 提交到本地 samples 分支(不推送)
//   node scripts/publish-samples.mjs --push   # 提交并推送 origin(样本变更须 hax 审批,见 AGENTS.md)
//   node scripts/publish-samples.mjs --render-only  # 只做 1-3(校验 + 生成派生 + 渲染),不碰 git
//
// 流程:
// 1. 双向校验 tools/samples-manifest.json 与本地 samples/ 文件集一致
// 2. 生成派生文件 samples/decisions/** + samples/offsets/**（scripts/gen-derived.mjs,
//    歧义决策真相 + 坐标修正表,格式见 tools/sample-derived.mjs）
// 3. 渲染 sha256sums.txt / README.md / LICENSES/ 到本地 samples/(保持本地 == 分支;
//    sha256sums 同时覆盖样本文件与派生文件,prepare-samples.sh 现有校验自动生效)
// 4. 临时目录 clone samples 分支(不存在则孤儿分支起步),同步内容,提交
// 5. --push 时推送 origin
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, writeFileSync, rmSync, mkdirSync, cpSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { tmpdir } from "node:os";

const ROOT = new URL("..", import.meta.url).pathname;
const BRANCH = "samples";
const push = process.argv.includes("--push");

function git(args, opts = {}) {
  const r = spawnSync("git", args, { encoding: "utf8", cwd: ROOT, ...opts });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")} 失败: ${r.stderr || r.stdout}`);
  return r.stdout.trim();
}

// ---- 1. 校验 manifest 与本地文件集一致 ----
const manifest = JSON.parse(readFileSync(join(ROOT, "tools/samples-manifest.json"), "utf8"));
const listed = new Set(manifest.files.map((f) => f.path));
const onDisk = [];
for (const group of ["real", "synthetic"]) {
  const dir = join(ROOT, "samples", group);
  if (!existsSync(dir)) continue;
  for (const name of readdirSync(dir).sort()) onDisk.push(`samples/${group}/${name}`);
}
const missing = manifest.files.filter((f) => !existsSync(join(ROOT, f.path))).map((f) => f.path);
const unlisted = onDisk.filter((p) => !listed.has(p));
if (missing.length || unlisted.length) {
  for (const p of missing) console.error(`manifest 列出但磁盘缺失: ${p}`);
  for (const p of unlisted) console.error(`磁盘存在但 manifest 未列: ${p}`);
  console.error("请先同步 tools/samples-manifest.json 与 samples/(样本调整须 hax 审批)");
  process.exit(1);
}

// ---- 2. 生成派生文件(decisions 决策真相 + offsets 坐标修正表)----
const gen = spawnSync(process.execPath, [join(ROOT, "scripts/gen-derived.mjs")], { stdio: "inherit", cwd: ROOT });
if (gen.status !== 0) {
  console.error("派生文件生成失败,中止发布");
  process.exit(1);
}

// ---- 3. 渲染生成文件到本地 samples/ ----
const rows = [];
const sums = [];
for (const f of manifest.files) {
  const buf = readFileSync(join(ROOT, f.path));
  const sha = createHash("sha256").update(buf).digest("hex");
  const rel = relative(join(ROOT, "samples"), join(ROOT, f.path));
  sums.push(`${sha}  ${rel}`);
  rows.push({ ...f, sha, bytes: buf.length, rel });
}

// 派生文件一并纳入 sha256sums(相对 samples/ 的路径)
function walkFiles(dir, rel = "") {
  const out = [];
  for (const name of readdirSync(join(dir, rel)).sort()) {
    const relPath = rel ? `${rel}/${name}` : name;
    if (statSync(join(dir, relPath)).isDirectory()) out.push(...walkFiles(dir, relPath));
    else out.push(relPath);
  }
  return out;
}
let derivedCount = 0;
for (const sub of ["offsets", "decisions"]) {
  const base = join(ROOT, "samples", sub);
  if (!existsSync(base)) continue;
  for (const relPath of walkFiles(base)) {
    const sha = createHash("sha256").update(readFileSync(join(base, relPath))).digest("hex");
    sums.push(`${sha}  ${sub}/${relPath}`);
    derivedCount++;
  }
}
writeFileSync(join(ROOT, "samples/sha256sums.txt"), sums.join("\n") + "\n");

const mLines = [
  "# my-scanner 样本集(samples 分支)",
  "",
  "本分支是 bench/差分测试样本的唯一权威存储:只含样本,不含源码。",
  "主仓 `scripts/prepare-samples.sh` 按需拉取并校验(`sha256sums.txt`);",
  "语义标签(谱系分组)的单一来源是主仓 `tools/samples-manifest.json`,",
  "样本详情见主仓 docs/samples.md。样本调整须 hax 审批。",
  "",
  "| 文件 | 分组 | 谱系 | 大小 | 来源 | license | sha256 |",
  "| --- | --- | --- | ---: | --- | --- | --- |",
];
for (const r of rows) {
  mLines.push(`| \`${r.rel}\` | ${r.group} | ${r.tag} | ${r.bytes} | ${r.source} | ${r.license} | \`${r.sha.slice(0, 16)}…\` |`);
}
mLines.push(
  "",
  "## 派生文件(勿手改)",
  "",
  "`decisions/` 与 `offsets/` 由主仓 `scripts/publish-samples.mjs`(内部调",
  "`scripts/gen-derived.mjs`)在发布时重新生成,随本分支一同发布,已纳入 `sha256sums.txt`:",
  "",
  "- `decisions/<分组>/<样本>.tsv`:歧义决策真相(正则字面量 / 模板续片的位置与 span,",
  "  发布期由 tsc parser 生成一次)。运行期差分只跑 tsc scanner、按它驱动重扫,",
  "  并断言 my-scanner 在这些点上的 lexeme 全中。**只随 tsc 版本失效**——升级 tsc 后",
  "  重新发布(头里版本对不上时差分硬报错)。",
  "- `offsets/<分组>/<样本>.tsv.gz`:非 ASCII 样本的「字节 ↔ UTF-16 code unit」修正表",
  "  (每个非 ASCII 字符一条的增量表)。只随样本文件字节变;纯 ASCII 样本不生成。",
  "",
);
writeFileSync(join(ROOT, "samples/README.md"), mLines.join("\n") + "\n");

mkdirSync(join(ROOT, "samples/LICENSES"), { recursive: true });
for (const name of readdirSync(join(ROOT, "tools/samples-licenses"))) {
  cpSync(join(ROOT, "tools/samples-licenses", name), join(ROOT, "samples/LICENSES", name));
}
console.log(`已渲染: samples/sha256sums.txt, samples/README.md, samples/LICENSES/ (${rows.length} 个样本文件 + ${derivedCount} 个派生文件)`);

if (process.argv.includes("--render-only")) {
  console.log("(--render-only,不碰 git)");
  process.exit(0);
}

// ---- 4. 同步到 samples 分支 ----
let url = "";
try { url = git(["config", "--get", "remote.origin.url"]); } catch { /* 无 origin 也能本地建分支 */ }
const pub = join(tmpdir(), `samples-branch-${Date.now()}`);
rmSync(pub, { recursive: true, force: true });
mkdirSync(pub, { recursive: true });

const cloned = url && spawnSync("git", ["clone", "--depth", "1", "-b", BRANCH, url, pub]).status === 0;
if (!cloned) {
  console.log(`${BRANCH} 分支不存在于 origin,创建孤儿分支`);
  git(["init", "-b", BRANCH, pub]);
}
for (const p of ["real", "synthetic", "LICENSES", "offsets", "decisions", "MANIFEST.md"]) rmSync(join(pub, p), { recursive: true, force: true });
for (const p of ["real", "synthetic", "LICENSES", "offsets", "decisions", "README.md", "sha256sums.txt"]) {
  const src = join(ROOT, "samples", p);
  if (existsSync(src)) cpSync(src, join(pub, p), { recursive: true });
}

git(["-C", pub, "add", "-A"]);
if (git(["-C", pub, "status", "--porcelain"]) === "") {
  console.log("无变化,跳过提交");
  rmSync(pub, { recursive: true, force: true });
  process.exit(0);
}
git(["-C", pub, "-c", "user.name=samples-bot", "-c", "user.email=samples-bot@users.noreply.github.com",
  "commit", "-m", `samples: ${rows.length} 个样本文件 (real ${rows.filter((r) => r.group === "real").length}, synthetic ${rows.filter((r) => r.group === "synthetic").length})`]);

// 把临时目录的提交取回主仓本地分支(prepare 离线可用;对象随 fetch 进主仓,不悬空)
git(["fetch", pub, `${BRANCH}:${BRANCH}`]);

if (push) {
  if (!cloned) git(["-C", pub, "remote", "add", "origin", url]);
  git(["-C", pub, "push", "-u", "origin", BRANCH]);
  console.log(`已推送 → origin ${BRANCH} 分支`);
} else {
  console.log(`已在临时目录提交。推送: node scripts/publish-samples.mjs --push`);
}
rmSync(pub, { recursive: true, force: true });
