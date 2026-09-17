// oxc_bitmap（oxc_lexer 多位图流水线实验 crate）与 my-scanner 的 lexeme spans 对照。
// 它不接受外部决策注入（正则/除号由内部 disambiguate pass 自决），本脚本即
// 「歧义点决策一致」的等价验证：全 bench 样本切分一致才允许进入基准矩阵。
//
//   node tools/compare-oxc-bitmap.mjs <file>...
//
// 对齐规则（与 compare-tsc.mjs 同款思路，但双方都是字节偏移、无需坐标换算）：
// - 双方均为 trivia-free 显著流（my-scanner 的 trivia 不进流；oxc 侧
//   emit_comments=false；hashbang 样本没有）；
// - 模板双方都拆 Head/Middle/Tail 片，1:1 对齐；
// - TS 泛型嵌套的 `>` 家族：oxc 的 type-context oracle 把闭合类型实参的 `>` run
//   拆成单 `>`（tsc 同款哲学，JS 表达式里的 `>>` 仍融合），my-scanner 恒融合——
//   吞噬同步：mine 的一个 lexeme 必须恰好是 oxc 一串 token 的拼接（边界咬合）；
// - 私有名：oxc 是单个 private_name，my-scanner 拆 `#` + identifier 两个
//   lexeme——反向吞噬同步（oxc 更宽只许这一种）；
// - 其余 token 严格要求 (start, end) 相等；
// - kind 粗类对比（关键字两边都归 identifier），不一致记 hard 并失败。
// 退出码：任一文件 spans 错位或 hard diff > 0 则 1。

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const ROOT = new URL("..", import.meta.url).pathname;
const MY_SCANNER = `${ROOT}/zig-out/bin/my-scanner`;
const BITMAP_DUMP = `${ROOT}/tools/lexbench-rs/target/release/bitmap_dump`;

function myTokens(file) {
  const dump = execFileSync(MY_SCANNER, ["--dump", file], { maxBuffer: 1 << 28 });
  return dump
    .toString("utf8")
    .split("\n")
    .filter((l) => /^\d+\t/.test(l)) // 滤掉末尾统计行
    .map((line) => {
      const [start, end, kind] = line.split("\t");
      return { start: Number(start), end: Number(end), kind };
    });
}

function oxcTokens(file) {
  const dump = execFileSync(BITMAP_DUMP, [file], { maxBuffer: 1 << 28 });
  return dump
    .toString("utf8")
    .split("\n")
    .filter((l) => /^\d+\t/.test(l)) // 滤掉 `== path` 头行
    .map((line) => {
      const [start, end, kind] = line.split("\t");
      return { start: Number(start), end: Number(end), kind };
    });
}

function context(buf, bytePos, span = 60) {
  // 展示用：直接按字节切片解码（非 ASCII 样本下不错位；切断的多字节序列
  // 会显示为替换符，仅影响展示不影响判定）
  const a = Math.max(0, bytePos - span);
  const b = Math.min(buf.length, bytePos + span);
  return buf.subarray(a, bytePos).toString("utf8") + "▶" + buf.subarray(bytePos, b).toString("utf8");
}

const files = process.argv.slice(2);
if (files.length === 0) {
  console.error("用法: node tools/compare-oxc-bitmap.mjs <file>...");
  process.exit(2);
}

let failed = false;
for (const file of files) {
  const buf = readFileSync(file);
  const mine = myTokens(file);
  const oxc = oxcTokens(file);

  let merged = 0; // 吞噬同步的 oxc 侧 token 数（TS 泛型 `>` 拆分）
  let mergedRev = 0; // 反向吞噬同步（oxc private_name vs mine 的 `#`+identifier）
  const hardKinds = new Map();
  let mismatch = null;

  let i = 0; // mine 游标
  let j = 0; // oxc 游标
  while (true) {
    const m = mine[i];
    const o = oxc[j];
    if (m === undefined || o === undefined) {
      mismatch = { m, o };
      break;
    }
    if (m.start !== o.start) {
      mismatch = { m, o };
      break;
    }

    if (m.end !== o.end) {
      if (m.end > o.end) {
        // TS 泛型的 `>` 拆分：mine 的一个 lexeme 必须恰好是 oxc 一串 token 的
        // 拼接（边界咬合，不得越过）
        let ok = false;
        let t = o;
        while (t.end < m.end) {
          t = oxc[++j];
          if (t === undefined) break;
        }
        if (t !== undefined && t.end === m.end) {
          ok = true;
          merged++;
        }
        if (!ok) {
          mismatch = { m, o };
          break;
        }
        i++;
        j++;
        continue;
      }
      // 反向：oxc 更宽只许 private_name 一种（mine 拆 `#` + identifier）
      if (o.kind === "private_name" && m.kind === "punct" && m.end === m.start + 1) {
        const n = mine[i + 1];
        if (n !== undefined && n.kind === "identifier" && n.end === o.end) {
          mergedRev++;
          i += 2;
          j++;
          continue;
        }
      }
      mismatch = { m, o };
      break;
    }

    // 完美对齐：对比 kind 粗类
    if (m.kind !== o.kind) {
      const key = `oxc=${o.kind} != mine=${m.kind}`;
      hardKinds.set(key, (hardKinds.get(key) ?? 0) + 1);
    }
    if (m.kind === "eof") break; // 双方 eof 收尾
    i++;
    j++;
  }

  if (mismatch) {
    failed = true;
    const { m, o } = mismatch;
    console.log(`✗ ${file}: spans 错位（mine 第 ${i} 个 / oxc 第 ${j} 个 token）`);
    if (m) console.log(`  mine: [${m.start},${m.end}) ${m.kind}`);
    if (o) console.log(`  oxc : [${o.start},${o.end}) ${o.kind}`);
    const pos = (m ?? o).start;
    console.log(`  上下文: ${JSON.stringify(context(buf, pos))}`);
  } else if (hardKinds.size > 0) {
    failed = true;
    console.log(`✗ ${file}: spans 一致但 kind 粗类有硬差异`);
    for (const [k, v] of hardKinds) console.log(`  !! ${k}: ${v}`);
  } else {
    console.log(`✓ ${file}: spans 完全一致（${mine.length} lexemes）`);
  }
  if (merged > 0) console.log(`  \`>\` 家族吞噬同步（TS 泛型侧 oxc 拆单 \`>\`）: ${merged}`);
  if (mergedRev > 0) console.log(`  private_name 反向吞噬同步（mine 拆 # + identifier）: ${mergedRev}`);
}
process.exit(failed ? 1 : 0);
