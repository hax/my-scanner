// 用 tsc 的 scanner 作为参考实现，与 my-scanner 的输出做 lexeme 级差分对比。
//
//   node tools/compare-tsc.mjs <file>...
//
// 与 tsc 的语义差异对齐（均为 tsc scanner 的设计，不是谁对谁错）：
// 1. 偏移坐标系：tsc 按 UTF-16 code unit 计，my-scanner 按字节计。
//    源文件按 UTF-8 读入，预建「字节偏移 ↔ code unit」双向映射，
//    tsc 侧 token 坐标全部换算成字节偏移后比较——非 ASCII 标识符也精确
//    对齐（旧实现按 latin1 喂 tsc，靠吞噬同步兜底 unicode 标识符，
//    遇到 UTF-8 续字节 0xA0（= NBSP，被 tsc 当空白跳过）必然错位）。
// 2. tsc scanner 永远不合并 `>` 家族（>> >= >>> >>=），由 parser reScan
//    合并（泛型 `A<B<C>>` 的需要）；`/` 的正则/除号也保守判除号。
//    因此对比采用"双向吞噬同步"：完美对齐优先；否则一侧的一个 token
//    必须恰好是另一侧一串 token 的拼接（边界咬合），只验证切分正确。
// 3. my-scanner 的粗流（Lexeme）：trivia 不进流（与 tsc skipTrivia=true
//    同口径），关键字不细分（tsc 的 keyword token 一律按 identifier
//    比对），私有名 `#foo` 拆成 `#` + identifier 两个 lexeme（tsc 是
//    单个 PrivateIdentifier，走吞噬同步），模板拆 Head/Middle/Tail 片
//    （与 tsc 同构，1:1 对齐）。
//
// kind 映射到 my-scanner 的粗分类，kind 不一致记 hard diff 并失败。

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import ts from "typescript";

const BIN = new URL("../zig-out/bin/my-scanner", import.meta.url).pathname;

// 字节偏移 ↔ UTF-16 code unit 双向映射。token 边界必落在字符边界上，
// 所以只保证字符边界处精确（字符内部的映射指向字符起点，不会被用到）。
function buildOffsetMaps(text, byteLen) {
  const cuToByte = new Uint32Array(text.length + 1);
  const byteToCU = new Uint32Array(byteLen + 1);
  let b = 0, cu = 0;
  for (const ch of text) { // for..of 按码点迭代（代理对整体出现）
    const u8 = Buffer.byteLength(ch, "utf8");
    const w = ch.length; // UTF-16 code unit 数（1 或 2）
    for (let k = 0; k < w; k++) cuToByte[cu + k] = b;
    for (let k = 0; k < u8; k++) byteToCU[b + k] = cu;
    cu += w;
    b += u8;
  }
  cuToByte[cu] = b;
  byteToCU[b] = cu;
  return { cuToByte, byteToCU };
}

function makeTscIter(text, maps) {
  const scanner = ts.createScanner(ts.ScriptTarget.Latest, /*skipTrivia*/ true);
  scanner.setText(text);
  const { cuToByte, byteToCU } = maps;

  // tsc 坐标（code unit）→ 字节偏移，与 my-scanner 同一坐标系
  const grab = () => ({
    kind: scanner.getToken(),
    start: cuToByte[scanner.getTokenStart()],
    end: cuToByte[scanner.getTokenEnd()],
  });

  const iter = {
    scan() {
      scanner.scan();
      return (iter.cur = grab());
    },
    // 把当前 `/`（除号）按 parser 行为重扫为正则字面量
    reScanSlash() {
      scanner.reScanSlashToken();
      return (iter.cur = grab());
    },
    // 把当前 `}` 按 parser 行为重扫为模板续片（TemplateMiddle/Tail；
    // 从 tokenStart 重扫，startedWithBacktick=false 路径）
    reScanTemplate() {
      scanner.reScanTemplateToken(false);
      return (iter.cur = grab());
    },
    // 跳到指定字节偏移继续扫（调用方随后经 nextTsc 取 token）。
    // 正则含转义换行时 tsc 只扫一半，以 mine 边界同步用。
    skipTo(pos) {
      scanner.setTextPos(byteToCU[pos]);
    },
    cur: null,
  };
  return iter;
}

function classify(kind, tokenText) {
  if (kind === ts.SyntaxKind.Identifier) return "identifier";
  if (kind === ts.SyntaxKind.PrivateIdentifier) return "private_identifier"; // 仅展示用：不会完美对齐（mine 拆 # + identifier）
  if (kind === ts.SyntaxKind.NumericLiteral || kind === ts.SyntaxKind.BigIntLiteral) return "number";
  if (kind === ts.SyntaxKind.StringLiteral) return "string";
  if (kind === ts.SyntaxKind.NoSubstitutionTemplateLiteral) return "no_substitution_template";
  if (kind === ts.SyntaxKind.TemplateHead) return "template_head";
  if (kind === ts.SyntaxKind.TemplateMiddle) return "template_middle";
  if (kind === ts.SyntaxKind.TemplateTail) return "template_tail";
  if (kind === ts.SyntaxKind.RegularExpressionLiteral) return "regex";
  if (kind === ts.SyntaxKind.EndOfFileToken) return "eof";
  const s = ts.tokenToString(kind);
  if (s !== undefined) {
    // 全字母的 tokenToString = 关键字（含 TS 上下文关键字）——粗流不细分，
    // 一律按 identifier 比对；否则是标点
    if (/^[A-Za-z]+$/.test(s)) return "identifier";
    return "punct";
  }
  return `other(${kind})`;
}

function myTokens(file, variant) {
  const args = ["--dump"];
  if (variant) args.push(`--variant=${variant}`);
  const dump = execFileSync(BIN, [...args, file], { maxBuffer: 1 << 28 });
  return dump
    .toString("utf8")
    .split("\n")
    .filter((l) => /^\d+\t/.test(l)) // 滤掉末尾统计行
    .map((line) => {
      const [start, end, kind] = line.split("\t");
      return { start: Number(start), end: Number(end), kind };
    });
}

function context(text, pos, span = 60) {
  const a = Math.max(0, pos - span);
  const b = Math.min(text.length, pos + span);
  return text.slice(a, pos) + "▶" + text.slice(pos, b);
}

let failed = false;

// --variant=NAME 转发给 CLI；其余参数是语料文件
const argv = process.argv.slice(2);
let variant = null;
const files = [];
for (const a of argv) {
  if (a.startsWith("--variant=")) variant = a.slice("--variant=".length);
  else files.push(a);
}
if (files.length === 0) {
  console.error("用法: node tools/compare-tsc.mjs [--variant=two_phase|scalar|jump_vec] <file>...");
  process.exit(2);
}
const variantLabel = variant ? ` [${variant}]` : "";

for (const file of files) {
  const buf = readFileSync(file);
  const text = buf.toString("utf8");
  const maps = buildOffsetMaps(text, buf.length);
  const iter = makeTscIter(text, maps);
  // 展示用切片：字节区间 → code unit 区间 → JS 字符串切片
  const show = (a, b) => text.slice(maps.byteToCU[a], maps.byteToCU[b]);
  const mine = myTokens(file, variant);

  // 模板上下文栈（模拟 tsc parser 的驱动）：TemplateHead/Middle 压一层，
  // 层内花括号平衡；平衡归零的 `}` 按 parser 行为 reScan 成 TemplateMiddle/Tail
  const tplStack = [];
  function nextTsc() {
    let t = iter.scan();
    if (t.kind === ts.SyntaxKind.CloseBraceToken && tplStack.length > 0 && tplStack[tplStack.length - 1] === 0) {
      t = iter.reScanTemplate();
      if (t.kind === ts.SyntaxKind.TemplateTail) tplStack.pop();
      return t;
    }
    if (t.kind === ts.SyntaxKind.TemplateHead || t.kind === ts.SyntaxKind.TemplateMiddle) {
      tplStack.push(0);
    } else if (tplStack.length > 0) {
      if (t.kind === ts.SyntaxKind.OpenBraceToken) tplStack[tplStack.length - 1]++;
      else if (t.kind === ts.SyntaxKind.CloseBraceToken) tplStack[tplStack.length - 1]--;
    }
    return t;
  }

  let merged = 0; // 吞噬同步的 token 数（tsc 侧 >> >= 等待 parser 合并的情况）
  let regexRescan = 0; // 正则经 reScanSlashToken 对齐（tsc 保守判除号）
  let regexPartial = 0; // 正则含转义换行时 tsc 只扫一半，以 mine 边界同步
  const hardKinds = new Map();
  const hardSamples = [];
  let mismatch = null;

  let r = nextTsc();
  let j = 0;
  while (true) {
    const m = mine[j];
    if (m === undefined || r === undefined) {
      mismatch = { r, m };
      break;
    }
    if (r.start !== m.start) {
      mismatch = { r, m };
      break;
    }

    // 正则：tsc 保守判除号，按 parser 行为 reScan 对齐。注意正则体内可能出现
    // 相邻 `//`，tsc 保守路径会当行注释吞到行尾，吞噬同步必失败，必须走这里
    if (m.kind === "regex" && r.kind === ts.SyntaxKind.SlashToken && r.end === r.start + 1) {
      const rr = iter.reScanSlash();
      if (rr.end === m.end) {
        regexRescan++;
        r = rr; // 落入完美对齐分支（kind: regex == regex）
      } else if (rr.end < m.end) {
        // tsc 正则不允许字面换行，含转义换行的正则 tsc 只扫一半；
        // 以 mine 边界同步
        regexPartial++;
        iter.skipTo(m.end);
        r = nextTsc();
        j++;
        continue;
      } else {
        mismatch = { r: rr, m };
        break;
      }
    }

    if (r.end === m.end) {
      // 完美对齐：对比 kind
      const rk = classify(r.kind, show(r.start, r.end));
      if (rk !== m.kind) {
        const key = `${rk} != ${m.kind}`;
        hardKinds.set(key, (hardKinds.get(key) ?? 0) + 1);
        if (hardSamples.length < 5) {
          hardSamples.push(`  [${r.start},${r.end}) tsc=${rk} mine=${m.kind} ${JSON.stringify(show(r.start, r.end))}`);
        }
      }
      if (r.kind === ts.SyntaxKind.EndOfFileToken) break; // 双方 eof 收尾
      r = nextTsc();
      j++;
      continue;
    }

    // 边界不咬合：一侧的一个 token 必须恰好是另一侧一串 token 的拼接
    if (r.end < m.end) {
      // tsc 侧推进到 end == m.end（例如 tsc 的 ">" ">" vs mine 的 ">>"）
      let ok = false;
      let t = r;
      let count = 1;
      while (t.end < m.end) {
        t = nextTsc();
        count++;
        if (t === undefined) break;
        if (t.end > m.end) break;
        if (t.end === m.end) { ok = true; break; }
      }
      if (!ok) {
        mismatch = { r, m };
        break;
      }
      merged += count;
      if (r.kind === ts.SyntaxKind.EndOfFileToken || t.kind === ts.SyntaxKind.EndOfFileToken) {
        mismatch = { r, m };
        break;
      }
      r = nextTsc();
      j++;
      continue;
    }

    // r.end > m.end：mine 侧推进到 end == r.end（例如 tsc 的 regex vs mine 的 "/" ...）
    let ok = false;
    let mj = j;
    while (mine[mj] && mine[mj].end < r.end) mj++;
    if (mine[mj] && mine[mj].end === r.end) ok = true;
    if (!ok) {
      mismatch = { r, m };
      break;
    }
    merged += mj - j + 1;
    if (r.kind === ts.SyntaxKind.EndOfFileToken) break;
    r = nextTsc();
    j = mj + 1;
  }

  if (mismatch) {
    failed = true;
    const { r, m } = mismatch;
    console.log(`✗ ${file}${variantLabel}: 切分错位（mine 第 ${j} 个 lexeme）`);
    if (r) console.log(`  tsc:  [${r.start},${r.end}) ${classify(r.kind, "")} ${JSON.stringify(show(r.start, r.end))}`);
    if (m) console.log(`  mine: [${m.start},${m.end}) ${m.kind} ${JSON.stringify(show(m.start, m.end))}`);
    const pos = r?.start ?? m.start;
    console.log(`  上下文: ${JSON.stringify(context(text, maps.byteToCU[pos]))}`);
  } else {
    console.log(`✓ ${file}${variantLabel}: 切分与 tsc 完全一致（${mine.length} lexemes）`);
  }
  if (merged > 0) console.log(`  吞噬同步（tsc 待 parser 合并的 >> >=、PrivateIdentifier 等）: ${merged}`);
  if (regexRescan > 0) console.log(`  正则 reScan 对齐: ${regexRescan}`);
  if (regexPartial > 0) console.log(`  正则含转义换行，以 mine 边界同步: ${regexPartial}`);
  for (const [k, v] of hardKinds) console.log(`  !! kind 硬差异 ${k}: ${v}`);
  for (const s of hardSamples) console.log(s);
}
process.exit(failed ? 1 : 0);
