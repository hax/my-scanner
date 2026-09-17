// 把本地 corpus/ 发布到 corpus 分支(语料的唯一权威存储,仿 publish-report.mjs)。
//
//   node scripts/publish-corpus.mjs          # 渲染生成文件 + 提交到本地 corpus 分支(不推送)
//   node scripts/publish-corpus.mjs --push   # 提交并推送 origin(语料变更须 hax 审批,见 AGENTS.md)
//   node scripts/publish-corpus.mjs --render-only  # 只做 1-2(校验 + 渲染),不碰 git
//
// 流程:
// 1. 双向校验 tools/corpus-manifest.json 与本地 corpus/ 文件集一致
// 2. 渲染 sha256sums.txt / MANIFEST.md / LICENSES/ 到本地 corpus/(保持本地 == 分支)
// 3. 临时目录 clone corpus 分支(不存在则孤儿分支起步),同步内容,提交
// 4. --push 时推送 origin
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, writeFileSync, rmSync, mkdirSync, cpSync } from "node:fs";
import { join, relative } from "node:path";
import { tmpdir } from "node:os";

const ROOT = new URL("..", import.meta.url).pathname;
const BRANCH = "corpus";
const push = process.argv.includes("--push");

function git(args, opts = {}) {
  const r = spawnSync("git", args, { encoding: "utf8", cwd: ROOT, ...opts });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")} 失败: ${r.stderr || r.stdout}`);
  return r.stdout.trim();
}

// ---- 1. 校验 manifest 与本地文件集一致 ----
const manifest = JSON.parse(readFileSync(join(ROOT, "tools/corpus-manifest.json"), "utf8"));
const listed = new Set(manifest.files.map((f) => f.path));
const onDisk = [];
for (const group of ["real", "synthetic"]) {
  const dir = join(ROOT, "corpus", group);
  if (!existsSync(dir)) continue;
  for (const name of readdirSync(dir).sort()) onDisk.push(`corpus/${group}/${name}`);
}
const missing = manifest.files.filter((f) => !existsSync(join(ROOT, f.path))).map((f) => f.path);
const unlisted = onDisk.filter((p) => !listed.has(p));
if (missing.length || unlisted.length) {
  for (const p of missing) console.error(`manifest 列出但磁盘缺失: ${p}`);
  for (const p of unlisted) console.error(`磁盘存在但 manifest 未列: ${p}`);
  console.error("请先同步 tools/corpus-manifest.json 与 corpus/(语料调整须 hax 审批)");
  process.exit(1);
}

// ---- 2. 渲染生成文件到本地 corpus/ ----
const rows = [];
const sums = [];
for (const f of manifest.files) {
  const buf = readFileSync(join(ROOT, f.path));
  const sha = createHash("sha256").update(buf).digest("hex");
  const rel = relative(join(ROOT, "corpus"), join(ROOT, f.path));
  sums.push(`${sha}  ${rel}`);
  rows.push({ ...f, sha, bytes: buf.length, rel });
}
writeFileSync(join(ROOT, "corpus/sha256sums.txt"), sums.join("\n") + "\n");

const mLines = [
  "# my-scanner 语料库(corpus 分支)",
  "",
  "本分支是 bench/差分语料的唯一权威存储:只含语料,不含源码。",
  "主仓 `scripts/prepare-corpus.sh` 按需拉取并校验(`sha256sums.txt`);",
  "语义标签(谱系分组)的单一来源是主仓 `tools/corpus-manifest.json`,",
  "语料详情见主仓 docs/corpus.md。语料调整须 hax 审批。",
  "",
  "| 文件 | 分组 | 谱系 | 大小 | 来源 | license | sha256 |",
  "| --- | --- | --- | ---: | --- | --- | --- |",
];
for (const r of rows) {
  mLines.push(`| \`${r.rel}\` | ${r.group} | ${r.tag} | ${r.bytes} | ${r.source} | ${r.license} | \`${r.sha.slice(0, 16)}…\` |`);
}
mLines.push("");
writeFileSync(join(ROOT, "corpus/MANIFEST.md"), mLines.join("\n") + "\n");

mkdirSync(join(ROOT, "corpus/LICENSES"), { recursive: true });
for (const name of readdirSync(join(ROOT, "tools/corpus-licenses"))) {
  cpSync(join(ROOT, "tools/corpus-licenses", name), join(ROOT, "corpus/LICENSES", name));
}
console.log(`已渲染: corpus/sha256sums.txt, corpus/MANIFEST.md, corpus/LICENSES/ (${rows.length} 个语料文件)`);

if (process.argv.includes("--render-only")) {
  console.log("(--render-only,不碰 git)");
  process.exit(0);
}

// ---- 3. 同步到 corpus 分支 ----
let url = "";
try { url = git(["config", "--get", "remote.origin.url"]); } catch { /* 无 origin 也能本地建分支 */ }
const pub = join(tmpdir(), `corpus-branch-${Date.now()}`);
rmSync(pub, { recursive: true, force: true });
mkdirSync(pub, { recursive: true });

const cloned = url && spawnSync("git", ["clone", "--depth", "1", "-b", BRANCH, url, pub]).status === 0;
if (!cloned) {
  console.log(`${BRANCH} 分支不存在于 origin,创建孤儿分支`);
  git(["init", "-b", BRANCH, pub]);
}
for (const p of ["real", "synthetic", "LICENSES"]) rmSync(join(pub, p), { recursive: true, force: true });
for (const p of ["real", "synthetic", "LICENSES", "MANIFEST.md", "sha256sums.txt"]) {
  cpSync(join(ROOT, "corpus", p), join(pub, p), { recursive: true });
}

git(["-C", pub, "add", "-A"]);
if (git(["-C", pub, "status", "--porcelain"]) === "") {
  console.log("无变化,跳过提交");
  rmSync(pub, { recursive: true, force: true });
  process.exit(0);
}
git(["-C", pub, "-c", "user.name=corpus-bot", "-c", "user.email=corpus-bot@users.noreply.github.com",
  "commit", "-m", `corpus: ${rows.length} 个语料文件 (real ${rows.filter((r) => r.group === "real").length}, synthetic ${rows.filter((r) => r.group === "synthetic").length})`]);

// 把临时目录的提交取回主仓本地分支(prepare 离线可用;对象随 fetch 进主仓,不悬空)
git(["fetch", pub, `${BRANCH}:${BRANCH}`]);

if (push) {
  if (!cloned) git(["-C", pub, "remote", "add", "origin", url]);
  git(["-C", pub, "push", "-u", "origin", BRANCH]);
  console.log(`已推送 → origin ${BRANCH} 分支`);
} else {
  console.log(`已在临时目录提交。推送: node scripts/publish-corpus.mjs --push`);
}
rmSync(pub, { recursive: true, force: true });
