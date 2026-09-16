// 把一次 run 的报告归档到 bench-reports 分支并重建趋势索引。
//
//   node scripts/publish-report.mjs --dir build/bench
//
// 环境变量(CI):GITHUB_TOKEN、REPO(owner/name);缺省时依次回退
// `gh auth token` 与 origin remote,本地一键提交(bench.sh --submit)零配置。
// 本地 run(channel=local)文件名为 <sha>.local-<机器名>.*,不与 CI 同 sha 互撞。
// push 被拒(与 CI 并发)时全新 clone 重建重试一次。
// 本地调试:--local <dir> 直接发布到已有目录(不碰 git)
import { execFileSync, spawnSync } from "node:child_process";
import { readFileSync, rmSync, mkdirSync, cpSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";

const argv = process.argv.slice(2);
function opt(name) {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
}
const srcDir = opt("--dir") ?? "build/bench";
const data = JSON.parse(readFileSync(join(srcDir, "data.json"), "utf8"));
const sha = data.sha;
// 本地 run 带机器标识,文件名与 CI 的 <sha>.* 区分,避免同提交互相覆盖
const safeLabel = String(data.label ?? "unknown").replace(/[^A-Za-z0-9._-]/g, "_");
const base = data.channel === "local" ? `${sha}.local-${safeLabel}` : sha;

function git(args, opts = {}) {
  const r = spawnSync("git", args, { encoding: "utf8", ...opts });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")} 失败: ${r.stderr || r.stdout}`);
  return r.stdout.trim();
}
function tryExec(cmd, args) {
  try { return execFileSync(cmd, args, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim(); }
  catch { return ""; }
}

const localDir = opt("--local");
if (localDir) {
  const dest = resolve(localDir);
  mkdirSync(join(dest, "reports"), { recursive: true });
  cpSync(join(srcDir, "data.json"), join(dest, "reports", `${base}.json`));
  cpSync(join(srcDir, "report.md"), join(dest, "reports", `${base}.md`));
  execFileSync("node", ["scripts/update-index.mjs", dest], { stdio: "inherit" });
  console.log(`本地发布完成 → ${dest}`);
  process.exit(0);
}

const token = process.env.GITHUB_TOKEN || tryExec("gh", ["auth", "token"]);
const repo = process.env.REPO ||
  (tryExec("git", ["remote", "get-url", "origin"]).match(/github\.com[:/]([^/]+\/[^/]+?)(?:\.git)?$/)?.[1] ?? "");
if (!token || !repo) {
  console.error("缺少 GITHUB_TOKEN / REPO(已尝试 `gh auth token` 与 origin remote;或用 --local <dir> 本地发布)");
  process.exit(2);
}
const url = `https://x-access-token:${token}@github.com/${repo}.git`;

for (let attempt = 1; attempt <= 2; attempt++) {
  const pub = join(tmpdir(), `bench-reports-${Date.now()}`);
  rmSync(pub, { recursive: true, force: true });
  mkdirSync(pub, { recursive: true });

  // 已有分支则浅 clone;没有则孤儿分支起步
  const cloned = spawnSync("git", ["clone", "--depth", "1", "-b", "bench-reports", url, pub]).status === 0;
  if (!cloned) {
    console.log("bench-reports 分支不存在,创建孤儿分支");
    git(["init", "-b", "bench-reports", pub]);
  }
  mkdirSync(join(pub, "reports"), { recursive: true });
  cpSync(join(srcDir, "data.json"), join(pub, "reports", `${base}.json`));
  cpSync(join(srcDir, "report.md"), join(pub, "reports", `${base}.md`));
  execFileSync("node", ["scripts/update-index.mjs", pub], { stdio: "inherit" });

  git(["-C", pub, "add", "-A"]);
  const status = git(["-C", pub, "status", "--porcelain"]);
  if (status === "") {
    console.log("无变化,跳过发布");
    process.exit(0);
  }
  git(["-C", pub, "-c", "user.name=bench-bot", "-c", "user.email=bench-bot@users.noreply.github.com",
    "commit", "-m", `bench: ${sha.slice(0, 10)}${data.channel === "local" ? `(本地 ${safeLabel})` : ""}`]);
  if (!cloned) git(["-C", pub, "remote", "add", "origin", url]);
  const push = spawnSync("git", ["-C", pub, "push", ...(cloned ? [] : ["-u"]), "origin", "bench-reports"], { encoding: "utf8" });
  if (push.status === 0) {
    console.log(`已发布 → ${repo} 的 bench-reports 分支 (reports/${base}.*)`);
    process.exit(0);
  }
  console.error(`push 被拒(尝试 ${attempt}/2):${(push.stderr || push.stdout).trim()}`);
  if (attempt === 1) console.log("可能与 CI 发布并发,全新 clone 重建后重试一次…");
}
process.exit(1);
