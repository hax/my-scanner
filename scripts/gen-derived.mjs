// 生成样本侧派生文件：歧义决策真相（decisions）+ 坐标修正表（offsets）。
// 文件格式与路径映射见 tools/sample-derived.mjs 头部说明。
//
//   node scripts/gen-derived.mjs              # tools/samples-manifest.json 全量（发布流程调用）
//   node scripts/gen-derived.mjs <file>...    # 指定样本文件（输出位置按路径映射推导）
//
// 每个文件：读字节 → 断言 utf8 往返一致（样本必须合法 UTF-8）→ tsc parser
// 解析（有语法错误即退出，真相源必须无语法错误）→ 收集正则/模板续片决策点
// （AST span，code unit）→ 经稀疏表换算字节 → 写 decisions（.tsv）与
// offsets（.tsv.gz，零非 ASCII 不生成；gzip 断言确定性，发布流程靠
// 「内容不变则不提交」）。decisions 随 tsc 版本失效；offsets 只随样本字节变。
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { gunzipSync, gzipSync } from "node:zlib";
import {
  buildOffsetEntries, decodeOffsetsFile, derivedPathsFor, encodeDecisionsFile,
  encodeOffsetsFile, makeConverter, sha256Hex,
} from "../tools/sample-derived.mjs";

const ROOT = resolve(new URL("..", import.meta.url).pathname);

let ts;
try {
  ts = (await import(new URL("../tools/node_modules/typescript/lib/typescript.js", import.meta.url))).default;
} catch {
  console.error("无法加载 tools/node_modules/typescript：先 cd tools && npm i");
  process.exit(2);
}

/// 展示/记入头部的路径：仓库内用相对路径，仓库外保留绝对路径
const show = (p) => {
  const r = relative(ROOT, p);
  return r.startsWith("..") ? p : r;
};

const args = process.argv.slice(2);
const files = args.length > 0
  ? args.map((a) => resolve(a))
  : JSON.parse(readFileSync(join(ROOT, "tools/samples-manifest.json"), "utf8"))
      .files.map((f) => resolve(ROOT, f.path));

let totalRegex = 0, totalTpl = 0;
for (const absPath of files) {
  const label = show(absPath);
  if (!existsSync(absPath)) {
    console.error(`✗ ${label}: 文件不存在`);
    process.exit(1);
  }
  const buf = readFileSync(absPath);
  const text = buf.toString("utf8");
  if (!Buffer.from(text, "utf8").equals(buf)) {
    console.error(`✗ ${label}: 样本必须合法 UTF-8（utf8 解码后再编码与原始字节不一致）`);
    process.exit(1);
  }
  const sha256 = sha256Hex(buf);

  // ---- 决策真相：tsc parser 的 AST span（code unit）----
  const scriptKind = absPath.endsWith(".js") ? ts.ScriptKind.JS : ts.ScriptKind.TS;
  const sf = ts.createSourceFile(absPath, text, ts.ScriptTarget.Latest, true, scriptKind);
  const diags = sf.parseDiagnostics ?? [];
  if (diags.length > 0) {
    console.error(`✗ ${label}: tsc 解析出 ${diags.length} 个语法错误，决策真相源必须无语法错误：`);
    for (const d of diags.slice(0, 5)) {
      console.error(`    ${ts.flattenDiagnosticMessageText(d.messageText, " ")}`);
    }
    process.exit(1);
  }
  const raw = [];
  const visit = (node) => {
    const k = node.kind;
    if (k === ts.SyntaxKind.RegularExpressionLiteral) {
      raw.push({ cls: "regex", startCU: node.getStart(sf), endCU: node.getEnd() });
    } else if (k === ts.SyntaxKind.TemplateMiddle || k === ts.SyntaxKind.TemplateTail) {
      raw.push({ cls: "tpl", startCU: node.getStart(sf), endCU: node.getEnd() });
    }
    node.forEachChild(visit);
  };
  visit(sf);

  const offsetEntries = buildOffsetEntries(text);
  const { cuToByte } = makeConverter(offsetEntries, text.length, buf.length);
  const records = raw
    .map((r) => ({
      cls: r.cls,
      startByte: cuToByte(r.startCU), endByte: cuToByte(r.endCU),
      startCU: r.startCU, endCU: r.endCU,
    }))
    .sort((a, b) => a.startByte - b.startByte);

  // ---- 落盘 ----
  const out = derivedPathsFor(absPath);
  mkdirSync(dirname(out.decisions), { recursive: true });
  const decisionsPlain = encodeDecisionsFile({ srcPath: label, sha256, tscVersion: ts.version, records });
  writeFileSync(out.decisions, decisionsPlain);

  let offsetsNote;
  if (offsetEntries.length === 0) {
    rmSync(out.offsets, { force: true }); // 纯 ASCII：不生成，并清掉历史派生
    offsetsNote = "offsets 无（纯 ASCII）";
  } else {
    const plain = encodeOffsetsFile({ srcPath: label, sha256, entries: offsetEntries });
    const gz1 = gzipSync(Buffer.from(plain, "utf8"), { level: 9 });
    const gz2 = gzipSync(Buffer.from(plain, "utf8"), { level: 9 });
    // 发布流程靠「内容不变则不提交」：gzip 必须确定，且解码往返一致
    if (!gz1.equals(gz2) || gunzipSync(gz1).toString("utf8") !== plain ||
        JSON.stringify(decodeOffsetsFile(plain).entries) !== JSON.stringify(offsetEntries)) {
      console.error(`✗ ${label}: gzip 不确定或编解码往返不一致，派生文件无法稳定复现`);
      process.exit(1);
    }
    mkdirSync(dirname(out.offsets), { recursive: true });
    writeFileSync(out.offsets, gz1);
    offsetsNote = `offsets ${offsetEntries.length} 条 ${plain.length}B / gz ${gz1.length}B`;
  }

  const nRegex = records.filter((r) => r.cls === "regex").length;
  const nTpl = records.length - nRegex;
  totalRegex += nRegex;
  totalTpl += nTpl;
  console.log(`gen-derived: ${label} → decisions ${records.length} 条（regex ${nRegex} + tpl ${nTpl}）${decisionsPlain.length}B；${offsetsNote}`);
}
console.log(`gen-derived: 共 ${files.length} 个文件，decisions regex ${totalRegex} + tpl ${totalTpl} = ${totalRegex + totalTpl} 条`);
