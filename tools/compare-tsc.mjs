// 用 tsc 的 scanner 作为参考实现，与 my-scanner 的输出做 lexeme 级差分测试。
//
//   node tools/compare-tsc.mjs [--variant=NAME] <file>...
//
// 歧义决策（`/` 是正则还是除号、模板续片从哪个 `}` 开始）的真相冻结在样本侧
// （samples/decisions/**，发布期由 scripts/gen-derived.mjs 用 tsc parser 生成
// 一次，格式见 tools/sample-derived.mjs）。运行期只跑 tsc scanner：到达决策点
// 时按真相重扫（reScanSlashToken / reScanTemplateToken），不再由我方输出触发；
// 同时双向断言我方与真相一致——每个决策点上我方的类别与 span 全中（「该判
// 正则判成除号」，T1），我方判出的正则/模板续片也必须在真相里（「多判」，
// 吞噬同步抓不到）；不一致即打印决策分歧并失败。坐标换算用样本侧稀疏修正表
// （samples/offsets/**，每个非 ASCII 字符一条），不再运行期建全量映射。
//
// 与 tsc 的语义差异对齐（均为 tsc scanner 的设计，不是谁对谁错）：
// 1. 偏移坐标系：tsc 按 UTF-16 code unit 计，my-scanner 按字节计；
//    tsc 侧 token 坐标经 offsets 修正表换算成字节偏移后比较——非 ASCII
//    标识符也精确对齐（旧实现按 latin1 喂 tsc，靠吞噬同步兜底 unicode
//    标识符，遇到 UTF-8 续字节 0xA0（= NBSP，被 tsc 当空白跳过）必然错位）。
// 2. tsc scanner 永远不合并 `>` 家族（>> >= >>> >>=），由 parser reScan
//    合并（泛型 `A<B<C>>` 的需要）；`/` 的正则/除号由 scanner 保守判除号，
//    重扫点来自样本侧决策真相。因此对比采用"双向吞噬同步"：完美对齐优先；
//    否则一侧的一个 token 必须恰好是另一侧一串 token 的拼接（边界咬合），
//    只验证切分正确。
// 3. my-scanner 的粗流（Lexeme）：trivia 不进流（与 tsc skipTrivia=true
//    同口径），关键字不细分（tsc 的 keyword token 一律按 identifier
//    比对），私有名 `#foo` 拆成 `#` + identifier 两个 lexeme（tsc 是
//    单个 PrivateIdentifier，走吞噬同步），模板拆 Head/Middle/Tail 片
//    （与 tsc 同构，1:1 对齐）。
//
// kind 映射到 my-scanner 的粗分类，kind 不一致记 hard diff 并失败。
// decisions 头里的 tsc 版本 / 样本 sha256 与现场不符、或 decisions/offsets
// 缺失，都是硬报错（重生成派生文件后再跑，见 scripts/gen-derived.mjs）。

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { gunzipSync } from "node:zlib";
import ts from "typescript";
import {
  decodeDecisionsFile, decodeOffsetsFile, derivedPathsFor, makeConverter, sha256Hex,
} from "./sample-derived.mjs";

const BIN = new URL("../zig-out/bin/my-scanner", import.meta.url).pathname;
const GEN_HINT = "先跑 node scripts/gen-derived.mjs <file>（或 node scripts/publish-samples.mjs --render-only 全量重生成）";

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

// 决策真相里两类歧义点在我方粗流里对应的 kind
const MINE_KINDS = { regex: ["regex"], tpl: ["template_middle", "template_tail"] };
// 反向断言用：真相有记录的 kind 集合——我方出现这些 kind 就必须在真相里（多判）
const TRUTH_KINDS = new Set(Object.values(MINE_KINDS).flat());

let failed = false;

// --variant=NAME 转发给 CLI；其余参数是样本文件
const argv = process.argv.slice(2);
let variant = null;
const files = [];
for (const a of argv) {
  if (a.startsWith("--variant=")) variant = a.slice("--variant=".length);
  else files.push(a);
}
if (files.length === 0) {
  console.error("用法: node tools/compare-tsc.mjs [--variant=two_phase|scalar|jump_vec|bitmap] <file>...");
  process.exit(2);
}
const variantLabel = variant ? ` [${variant}]` : "";

let totalRegex = 0, totalTpl = 0, totalHits = 0;

for (const file of files) {
  const buf = readFileSync(file);
  const text = buf.toString("utf8");
  const sha = sha256Hex(buf);

  // ---- 加载并校验派生文件（决策真相 + 坐标修正表）----
  const paths = derivedPathsFor(file);
  let fatal = null;
  let dec = null;
  let offsetEntries = [];
  if (!existsSync(paths.decisions)) {
    fatal = `缺少决策真相 ${paths.decisions}（${GEN_HINT}）`;
  } else {
    dec = decodeDecisionsFile(readFileSync(paths.decisions, "utf8"));
    if (dec.sha256 !== sha) fatal = `${paths.decisions} 的 # sha256 与样本不符（样本已改，${GEN_HINT}）`;
    else if (dec.tscVersion !== ts.version) fatal = `${paths.decisions} 由 tsc ${dec.tscVersion} 生成，当前 tsc 为 ${ts.version}（升版后须重生成派生文件）`;
  }
  if (!fatal) {
    if (existsSync(paths.offsets)) {
      const off = decodeOffsetsFile(gunzipSync(readFileSync(paths.offsets)).toString("utf8"));
      if (off.sha256 !== sha) fatal = `${paths.offsets} 的 # sha256 与样本不符（${GEN_HINT}）`;
      else offsetEntries = off.entries;
    } else if (text.length !== buf.length) {
      fatal = `offsets 文件缺失但样本含非 ASCII（${paths.offsets}），${GEN_HINT}`;
    }
  }
  if (fatal) {
    failed = true;
    console.log(`✗ ${file}${variantLabel}: ${fatal}`);
    continue;
  }

  const conv = makeConverter(offsetEntries, text.length, buf.length);
  // 展示用切片：字节区间 → code unit 区间 → JS 字符串切片
  const show = (a, b) => text.slice(conv.byteToCU(a), conv.byteToCU(b));
  const mine = myTokens(file, variant);
  const decByStart = new Map(dec.records.map((d) => [d.startByte, d]));

  // ---- tsc 侧：scanner + 按真相驱动的重扫 ----
  const scanner = ts.createScanner(ts.ScriptTarget.Latest, /*skipTrivia*/ true);
  scanner.setText(text);
  const grab = () => ({
    kind: scanner.getToken(),
    start: conv.cuToByte(scanner.getTokenStart()),
    end: conv.cuToByte(scanner.getTokenEnd()),
  });
  let rescan = 0;      // 按决策真相重扫的次数（正则 / 模板续片）
  let rescanPartial = 0; // 含转义换行的正则 tsc 只扫一半，按真相边界跳过
  let staleTruth = 0;  // 真相点上的 tsc token 与预期不符（真相与当前 tsc 行为不一致）
  function nextTsc() {
    for (;;) {
      scanner.scan();
      let t = grab();
      const d = decByStart.get(t.start);
      if (!d) return t;
      if (d.cls === "regex") {
        if (t.kind !== ts.SyntaxKind.SlashToken && t.kind !== ts.SyntaxKind.SlashEqualsToken) {
          staleTruth++;
          return t;
        }
        scanner.reScanSlashToken();
        t = grab();
        if (t.end < d.endByte) {
          // tsc 正则不允许字面换行：含转义换行的正则 tsc 只扫一半。
          // 跳到真相边界后，整段 [start, end) 以真相 span 合成一个 regex
          // token 交给同步循环（否则跳过的那段在我方没有对应物，必然
          // 假报错位）；真相与我一方的类别/span 一致性由决策断言另行校验。
          rescanPartial++;
          scanner.setTextPos(conv.byteToCU(d.endByte));
          return { kind: ts.SyntaxKind.RegularExpressionLiteral, start: d.startByte, end: d.endByte };
        }
        if (t.end > d.endByte) staleTruth++;
        rescan++;
        return t;
      }
      if (t.kind !== ts.SyntaxKind.CloseBraceToken) {
        staleTruth++;
        return t;
      }
      scanner.reScanTemplateToken(false);
      rescan++;
      return grab();
    }
  }

  let merged = 0; // 吞噬同步的 token 数（tsc 侧 >> >= 等待 parser 合并的情况）
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

  // ---- 我方断言：每个决策点上类别与 span 必须全中 ----
  const mineByStart = new Map(mine.map((m) => [m.start, m]));
  const diffs = [];
  for (const d of dec.records) {
    const m = mineByStart.get(d.startByte);
    if (!m || m.end !== d.endByte || !MINE_KINDS[d.cls].includes(m.kind)) diffs.push({ d, m });
  }
  // 反向：我方判出的正则/模板续片必须都在真相里。「多判正则」不会被吞噬
  // 同步抓到（如 `} / 2 /` 里 tsc 的 `/` `2` `/` 恰好拼成我方的一个 regex），
  // 只有对着真相集合核对才现形。
  const truthStarts = new Set(dec.records.map((d) => d.startByte));
  const extras = mine.filter((m) => TRUTH_KINDS.has(m.kind) && !truthStarts.has(m.start));
  totalRegex += dec.records.filter((d) => d.cls === "regex").length;
  totalTpl += dec.records.filter((d) => d.cls === "tpl").length;
  totalHits += dec.records.length - diffs.length;

  // ---- 报告 ----
  const ok = !mismatch && diffs.length === 0 && extras.length === 0 && staleTruth === 0;
  if (ok) {
    console.log(`✓ ${file}${variantLabel}: 切分与 tsc 完全一致（${mine.length} lexemes）`);
  } else {
    failed = true;
    if (mismatch) {
      const { r: rr, m } = mismatch;
      console.log(`✗ ${file}${variantLabel}: 切分错位（mine 第 ${j} 个 lexeme）`);
      if (rr) console.log(`  tsc:  [${rr.start},${rr.end}) ${classify(rr.kind, "")} ${JSON.stringify(show(rr.start, rr.end))}`);
      if (m) console.log(`  mine: [${m.start},${m.end}) ${m.kind} ${JSON.stringify(show(m.start, m.end))}`);
      const pos = rr?.start ?? m.start;
      console.log(`  上下文: ${JSON.stringify(context(text, conv.byteToCU(pos)))}`);
    } else if (staleTruth > 0) {
      console.log(`✗ ${file}${variantLabel}: 决策真相与当前 tsc 行为不一致 ${staleTruth} 处（重生成派生文件）`);
    } else {
      console.log(`✗ ${file}${variantLabel}: 决策分歧 ${diffs.length + extras.length} 处`);
    }
  }
  for (const { d, m } of diffs.slice(0, 10)) {
    const mineDesc = m ? `${m.kind} [${m.start},${m.end})` : "无（该处没有 lexeme）";
    console.log(`  决策分歧: ${d.cls} @${d.startByte} 真相=[${d.startByte},${d.endByte}) 我方=${mineDesc} 上下文: ${JSON.stringify(context(text, conv.byteToCU(d.startByte)))}`);
  }
  for (const m of extras.slice(0, 10)) {
    console.log(`  决策分歧: 多判 ${m.kind} @${m.start} 真相=无 我方=[${m.start},${m.end}) 上下文: ${JSON.stringify(context(text, conv.byteToCU(m.start)))}`);
  }
  if (diffs.length + extras.length > 10) console.log(`  ...共 ${diffs.length + extras.length} 处决策分歧`);
  if (dec.records.length > 0) {
    const nR = dec.records.filter((d) => d.cls === "regex").length;
    console.log(`  决策点: regex ${nR} + tpl ${dec.records.length - nR} = ${dec.records.length}，全中 ${dec.records.length - diffs.length}`);
  }
  if (merged > 0) console.log(`  吞噬同步（tsc 待 parser 合并的 >> >=、PrivateIdentifier 等）: ${merged}`);
  if (rescan > 0) console.log(`  按决策真相重扫: ${rescan}`);
  if (rescanPartial > 0) console.log(`  正则含转义换行、按真相边界跳过: ${rescanPartial}`);
  for (const [k, v] of hardKinds) console.log(`  !! kind 硬差异 ${k}: ${v}`);
  for (const s of hardSamples) console.log(s);
}
if (files.length > 1) {
  console.log(`决策点合计: regex ${totalRegex} + tpl ${totalTpl} = ${totalRegex + totalTpl}，全中 ${totalHits}`);
}
process.exit(failed ? 1 : 0);
