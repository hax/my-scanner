// 把一次 run 的报告归档到 bench-reports 分支并重建趋势索引。
//
//   node scripts/publish-report.mjs --dir build/bench
//
// 环境变量(CI):GITHUB_TOKEN、REPO(owner/name)
// 本地调试:--local <dir> 直接发布到已有目录(不碰 git)
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, readFileSync, rmSync, mkdirSync, cpSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";

const argv = process.argv.slice(2);
function opt(name) {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
}
const srcDir = opt("--dir") ?? "build/bench";
const sha = JSON.parse(readFileSync(join(srcDir, "data.json"), "utf8")).sha;

function git(args, opts = {}) {
  const r = spawnSync("git", args, { encoding: "utf8", ...opts });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")} 失败: ${r.stderr || r.stdout}`);
  return r.stdout.trim();
}

const localDir = opt("--local");
if (localDir) {
  const dest = resolve(localDir);
  mkdirSync(join(dest, "reports"), { recursive: true });
  cpSync(join(srcDir, "data.json"), join(dest, "reports", `${sha}.json`));
  cpSync(join(srcDir, "report.md"), join(dest, "reports", `${sha}.md`));
  execFileSync("node", ["scripts/update-index.mjs", dest], { stdio: "inherit" });
  console.log(`本地发布完成 → ${dest}`);
  process.exit(0);
}

const { GITHUB_TOKEN, REPO } = process.env;
if (!GITHUB_TOKEN || !REPO) {
  console.error("缺少 GITHUB_TOKEN / REPO 环境变量(或用 --local <dir> 本地发布)");
  process.exit(2);
}
const url = `https://x-access-token:${GITHUB_TOKEN}@github.com/${REPO}.git`;
const pub = join(tmpdir(), `bench-reports-${sha.slice(0, 10)}`);
rmSync(pub, { recursive: true, force: true });
mkdirSync(pub, { recursive: true });

// 已有分支则浅 clone;没有则孤儿分支起步
const cloned = spawnSync("git", ["clone", "--depth", "1", "-b", "bench-reports", url, pub]).status === 0;
if (!cloned) {
  console.log("bench-reports 分支不存在,创建孤儿分支");
  git(["init", "-b", "bench-reports", pub]);
}
mkdirSync(join(pub, "reports"), { recursive: true });
cpSync(join(srcDir, "data.json"), join(pub, "reports", `${sha}.json`));
cpSync(join(srcDir, "report.md"), join(pub, "reports", `${sha}.md`));
execFileSync("node", ["scripts/update-index.mjs", pub], { stdio: "inherit" });

git(["-C", pub, "add", "-A"]);
const status = git(["-C", pub, "status", "--porcelain"]);
if (status === "") {
  console.log("无变化,跳过发布");
  process.exit(0);
}
git(["-C", pub, "-c", "user.name=bench-bot", "-c", "user.email=bench-bot@users.noreply.github.com",
  "commit", "-m", `bench: ${sha.slice(0, 10)}`]);
if (cloned) {
  git(["-C", pub, "push", "origin", "bench-reports"]);
} else {
  git(["-C", pub, "remote", "add", "origin", url]);
  git(["-C", pub, "push", "-u", "origin", "bench-reports"]);
}
console.log(`已发布 → ${REPO} 的 bench-reports 分支 (reports/${sha.slice(0, 10)}.*)`);
