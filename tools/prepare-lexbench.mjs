// 生成 lexbench 对比样本：把原样本中的正则字面量替换为等长字符串。
//
//   node tools/prepare-lexbench.mjs <out-dir> <file>...
//
// 动机：swc/oxc 的 lexer 内置"表达式位置 / 判正则"启发式（它们默认由
// parser 驱动，parser 在除号位置会阻止重扫）。脱离 parser 独立迭代时，
// minified 样本的除号被误判成正则 → 吞并大段代码甚至中途出错。
// 正则字面量占比 ~0.01%，等长替换成字符串后：字节总数不变、后续偏移
// 不变、所有实现对同一份输入计时，对比口径公平。
//
// 替换格式：/ab[c]/g → "rrrrrr"（同长度，内容不含引号/反斜杠）。

import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

const BIN = new URL("../zig-out/bin/my-scanner", import.meta.url).pathname;

const [outDir, ...files] = process.argv.slice(2);
if (!outDir || files.length === 0) {
  console.error("用法: node tools/prepare-lexbench.mjs <out-dir> <file>...");
  process.exit(2);
}

for (const file of files) {
  const buf = readFileSync(file);
  const dump = execFileSync(BIN, ["--dump", file], { maxBuffer: 1 << 28 })
    .toString("utf8")
    .split("\n")
    .filter((l) => l !== "");

  const regexes = [];
  for (const line of dump) {
    const [start, end, kind] = line.split("\t");
    if (kind === "regex") regexes.push([Number(start), Number(end)]);
  }

  // 从后往前替换，偏移不漂移；长度严格相等，逐位置对齐
  let out = buf;
  for (const [start, end] of regexes.reverse()) {
    const len = end - start;
    const repl = '"' + "r".repeat(len - 2) + '"';
    if (repl.length !== len) throw new Error(`长度不守恒: [${start},${end})`);
    out = out.subarray(0, start).toString("latin1") + repl + out.subarray(end).toString("latin1");
    // subarray 拼接走 latin1 保字节；统一回 Buffer
    out = Buffer.from(out, "latin1");
  }

  const dest = join(outDir, file.replaceAll("/", "_"));
  mkdirSync(dirname(dest), { recursive: true });
  writeFileSync(dest, out);
  console.log(`${file}: ${regexes.length} 个正则已中性化 → ${dest} (${out.length} bytes)`);
}
