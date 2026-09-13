// 用 tsc 的 scanner 作为参考实现，与 my-scanner 的输出做 token 级差分对比。
//
//   node tools/compare-tsc.mjs <file>...
//
// 与 tsc 的语义差异对齐（均为 tsc scanner 的设计，不是谁对谁错）：
// 1. 偏移坐标系：tsc 按 UTF-16 code unit 计，my-scanner 按字节计。
//    把源文件按 latin1 喂给 tsc（每字节恰一个 code unit）即可统一；
//    非 ASCII 只出现在注释/字符串里，不影响 token 边界。
// 2. tsc scanner 永远不合并 `>` 家族（>> >= >>> >>=），由 parser reScan
//    合并（泛型 `A<B<C>>` 的需要）；`/` 的正则/除号也保守判除号。
//    因此对比采用"双向吞噬同步"：完美对齐优先；否则一侧的一个 token
//    必须恰好是另一侧一串 token 的拼接（边界咬合），只验证切分正确。
// 3. 模板字面量整体算一个 token：tsc 的 TemplateHead/Middle/Tail/子表达式
//    在吞并阶段合并（嵌套模板用 Head/Tail 计数）。
//
// kind 映射到 my-scanner 的粗分类；keyword/identifier 之间的差异记 soft diff
// （TS 上下文关键字两边取舍不同），其余 kind 不一致记 hard diff。

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import ts from "typescript";

const BIN = new URL("../zig-out/bin/my-scanner", import.meta.url).pathname;

// 与 src/scanner.zig 的 keywords 表保持一致
const KEYWORDS = new Set([
  "await", "break", "case", "catch", "class", "const", "continue", "debugger",
  "default", "delete", "do", "else", "enum", "export", "extends", "finally",
  "for", "function", "if", "implements", "import", "in", "instanceof",
  "interface", "let", "new", "of", "package", "private", "protected", "public",
  "return", "static", "super", "switch", "this", "throw", "try", "typeof",
  "var", "void", "while", "with", "yield", "async",
]);

function makeTscIter(text) {
  const scanner = ts.createScanner(ts.ScriptTarget.Latest, /*skipTrivia*/ true);
  scanner.setText(text);

  const grab = () => ({
    kind: scanner.getToken(),
    start: scanner.getTokenStart(),
    end: scanner.getTokenEnd(),
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
    // 跳到指定字节偏移继续扫。模板字符串类型（`${string}` 这种）tsc 纯
    // scanner 无法给出整模板边界（parser 在类型位置不 reScan），模板起点
    // 验证一致后直接同步到 mine 的模板终点。
    skipTo(pos) {
      scanner.setTextPos(pos);
      scanner.scan();
      return (iter.cur = grab());
    },
    cur: null,
  };
  return iter;
}

function classify(kind, tokenText) {
  if (kind === ts.SyntaxKind.Identifier) return "identifier";
  if (kind === ts.SyntaxKind.PrivateIdentifier) return "private_name";
  if (kind === ts.SyntaxKind.NumericLiteral || kind === ts.SyntaxKind.BigIntLiteral) return "number";
  if (kind === ts.SyntaxKind.StringLiteral) return "string";
  if (
    kind === ts.SyntaxKind.NoSubstitutionTemplateLiteral ||
    kind === ts.SyntaxKind.TemplateHead ||
    kind === ts.SyntaxKind.TemplateMiddle ||
    kind === ts.SyntaxKind.TemplateTail
  ) return "template";
  if (kind === ts.SyntaxKind.RegularExpressionLiteral) return "regex";
  if (kind === ts.SyntaxKind.EndOfFileToken) return "eof";
  const s = ts.tokenToString(kind);
  if (s !== undefined) {
    // 全字母的 tokenToString = 关键字（含 TS 上下文关键字），否则是标点
    if (/^[A-Za-z]+$/.test(s)) return KEYWORDS.has(s) ? "keyword" : "identifier";
    return "punct";
  }
  return `other(${kind})`;
}

function myTokens(file) {
  const dump = execFileSync(BIN, ["--dump", file], { maxBuffer: 1 << 28 });
  return dump
    .toString("utf8")
    .split("\n")
    .filter((l) => l !== "")
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
for (const file of process.argv.slice(2)) {
  const buf = readFileSync(file);
  const text = buf.toString("latin1"); // 1 code unit = 1 byte
  const iter = makeTscIter(text);
  const mine = myTokens(file);

  let soft = 0;
  let merged = 0; // 吞噬同步的 token 数（tsc 侧 >> >= 等待 parser 合并的情况）
  let templateSync = 0; // 模板整体以 mine 边界同步（tsc 拆 Head/Middle/Tail）
  let regexRescan = 0; // 正则经 reScanSlashToken 对齐（tsc 保守判除号）
  let regexPartial = 0; // 正则含转义换行时 tsc 只扫一半，以 mine 边界同步
  const hardKinds = new Map();
  const hardSamples = [];
  let mismatch = null;

  let r = iter.scan();
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
        r = iter.skipTo(m.end);
        j++;
        continue;
      } else {
        mismatch = { r: rr, m };
        break;
      }
    }

    // 模板：tsc 流被拆成 Head/普通token/Middle/Tail（模板类型甚至不续扫），
    // 整体边界以 mine 为准同步；模板起点已在上面验证两侧一致
    if (
      (r.kind === ts.SyntaxKind.TemplateHead || r.kind === ts.SyntaxKind.NoSubstitutionTemplateLiteral) &&
      m.kind === "template" && m.end > r.end
    ) {
      templateSync++;
      if (r.kind === ts.SyntaxKind.EndOfFileToken) break;
      r = iter.skipTo(m.end);
      j++;
      continue;
    }

    if (r.end === m.end) {
      // 完美对齐：对比 kind
      const rk = classify(r.kind, text.slice(r.start, r.end));
      if (rk !== m.kind) {
        const bothKwId = (rk === "keyword" || rk === "identifier") &&
          (m.kind === "keyword" || m.kind === "identifier");
        if (bothKwId) {
          soft++;
        } else {
          const key = `${rk} != ${m.kind}`;
          hardKinds.set(key, (hardKinds.get(key) ?? 0) + 1);
          if (hardSamples.length < 5) {
            hardSamples.push(`  [${r.start},${r.end}) tsc=${rk} mine=${m.kind} ${JSON.stringify(text.slice(r.start, r.end))}`);
          }
        }
      }
      if (r.kind === ts.SyntaxKind.EndOfFileToken) break; // 双方 eof 收尾
      r = iter.scan();
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
        t = iter.scan();
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
      r = iter.scan();
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
    r = iter.scan();
    j = mj + 1;
  }

  if (mismatch) {
    failed = true;
    const { r, m } = mismatch;
    console.log(`✗ ${file}: 切分错位（mine 第 ${j} 个 token）`);
    if (r) console.log(`  tsc:  [${r.start},${r.end}) ${classify(r.kind, "")} ${JSON.stringify(text.slice(r.start, r.end))}`);
    if (m) console.log(`  mine: [${m.start},${m.end}) ${m.kind} ${JSON.stringify(text.slice(m.start, m.end))}`);
    const pos = r?.start ?? m.start;
    console.log(`  上下文: ${JSON.stringify(context(text, pos))}`);
  } else {
    console.log(`✓ ${file}: 切分与 tsc 完全一致（${mine.length} tokens）`);
  }
  if (soft > 0) console.log(`  keyword/identifier 取舍差异（soft）: ${soft}`);
  if (merged > 0) console.log(`  吞噬同步（tsc 待 parser 合并的 >> >= 等）: ${merged}`);
  if (templateSync > 0) console.log(`  模板整体同步（tsc 拆 Head/Middle/Tail，以 mine 边界为准）: ${templateSync}`);
  if (regexRescan > 0) console.log(`  正则 reScan 对齐: ${regexRescan}`);
  if (regexPartial > 0) console.log(`  正则含转义换行，以 mine 边界同步: ${regexPartial}`);
  for (const [k, v] of hardKinds) console.log(`  !! kind 硬差异 ${k}: ${v}`);
  for (const s of hardSamples) console.log(s);
}
process.exit(failed ? 1 : 0);

