// 样本侧派生文件（decisions / offsets）的编码、解码、坐标换算与路径映射——
// 生成器（scripts/gen-derived.mjs）与消费侧（tools/compare-tsc.mjs）共用的
// 单一事实源。
//
// 背景：源码里「`/` 是正则还是除号」「模板续片从哪个 `}` 开始」这类歧义决策，
// 由发布期用 tsc parser 生成一次、冻结到样本目录（samples/decisions/**），
// 运行期差分只跑 tsc scanner（不再由我方输出触发重扫），决策分歧直接红灯；
// 非 ASCII 样本的「字节 ↔ UTF-16 code unit」换算同样冻结成稀疏表
// （samples/offsets/**，每个非 ASCII 字符一条），免去运行期全量建表。
//
// 路径映射（P 为样本文件路径）：
//   groupDir = dirname(P)   root = dirname(groupDir)   name = basename(P)
//   decisions = root/decisions/<basename(groupDir)>/<name>.tsv
//   offsets   = root/offsets/<basename(groupDir)>/<name>.tsv.gz
//
// offsets 明文格式（落盘前 gzip；零非 ASCII 的文件不生成）：
//   # my-scanner offsets v1
//   # src: samples/real/hanzi-chai.ts
//   # sha256: <样本文件字节的 sha256，64 hex>
//   U <dcu> <dbyte>
// `U` 行为增量：cu_i = cu_{i-1} + dcu、byte_i = byte_{i-1} + dbyte
// （首条相对 0/0），每个非 ASCII 字符一行、升序。
//
// decisions 明文格式：
//   # my-scanner decisions v1
//   # src: samples/real/typescript.js
//   # sha256: <64 hex>
//   # tsc: 6.0.3
//   D regex <startByte> <endByte> <startCU> <endCU>   // RegularExpressionLiteral
//   D tpl <startByte> <endByte> <startCU> <endCU>     // TemplateMiddle/TemplateTail（起点是那个 }）
// 记录按 startByte 升序。
import { createHash } from "node:crypto";
import { basename, dirname, join } from "node:path";

const OFFSETS_HEADER = "# my-scanner offsets v1";
const DECISIONS_HEADER = "# my-scanner decisions v1";

/// 样本文件字节的 sha256（hex），头里记录、消费侧校验用
export function sha256Hex(buf) {
  return createHash("sha256").update(buf).digest("hex");
}

/// 样本文件路径 → 派生文件路径（见文件头映射）
export function derivedPathsFor(file) {
  const groupDir = dirname(file);
  const root = dirname(groupDir);
  const group = basename(groupDir);
  const name = basename(file);
  return {
    decisions: join(root, "decisions", group, `${name}.tsv`),
    offsets: join(root, "offsets", group, `${name}.tsv.gz`),
  };
}

/// 逐码点扫 text，每个非 ASCII 字符一条 {cu, byte}（升序）。
/// 宽度按码点推导（UTF-8：1/2/3/4；UTF-16：1 或 2 code unit）。
export function buildOffsetEntries(text) {
  const entries = [];
  let cu = 0, byte = 0;
  for (const ch of text) { // for..of 按码点迭代（代理对整体出现）
    const cp = ch.codePointAt(0);
    if (cp > 0x7f) entries.push({ cu, byte });
    cu += ch.length; // UTF-16 code unit 数
    byte += cp <= 0x7f ? 1 : cp <= 0x7ff ? 2 : cp <= 0xffff ? 3 : 4;
  }
  return entries;
}

/// offsets 明文（未 gzip）
export function encodeOffsetsFile({ srcPath, sha256, entries }) {
  const lines = [OFFSETS_HEADER, `# src: ${srcPath}`, `# sha256: ${sha256}`];
  let cu = 0, byte = 0;
  for (const e of entries) {
    lines.push(`U ${e.cu - cu} ${e.byte - byte}`);
    cu = e.cu;
    byte = e.byte;
  }
  return lines.join("\n") + "\n";
}

export function decodeOffsetsFile(plainText) {
  let srcPath = null, sha256 = null;
  const entries = [];
  let cu = 0, byte = 0;
  for (const line of plainText.split("\n")) {
    if (line === "" || line === OFFSETS_HEADER) continue;
    if (line.startsWith("# src: ")) { srcPath = line.slice("# src: ".length); continue; }
    if (line.startsWith("# sha256: ")) { sha256 = line.slice("# sha256: ".length); continue; }
    const m = /^U (\d+) (\d+)$/.exec(line);
    if (!m) throw new Error(`offsets 文件存在无法解析的行: ${JSON.stringify(line)}`);
    cu += Number(m[1]);
    byte += Number(m[2]);
    entries.push({ cu, byte });
  }
  if (!srcPath || !sha256) throw new Error("offsets 文件缺少 # src / # sha256 头");
  return { srcPath, sha256, entries };
}

/// entries（非 ASCII 字符的升序 {cu, byte} 表）→ 双向换算函数。
/// 只保证字符边界处精确（token 边界不会落在字符内部）：
/// 1. 空表 → 恒等（纯 ASCII 文件）；
/// 2. 首条目之前 → byte = byte₀ − (cu₀ − cu)（前置段全是 ASCII，1:1）；
/// 3. 末条目之后 → byte = byteLen − (cuLen − cu)（用文件总长回推，不需存宽度）。
/// 中间段二分后从后一非 ASCII 字符回推（两者之间全是 ASCII，步长一致）；
/// 反方向同理。
export function makeConverter(entries, cuLen, byteLen) {
  const n = entries.length;
  if (n === 0) return { cuToByte: (cu) => cu, byteToCU: (byte) => byte };
  const cus = new Uint32Array(n);
  const bytes = new Uint32Array(n);
  for (let i = 0; i < n; i++) { cus[i] = entries[i].cu; bytes[i] = entries[i].byte; }

  // 首个 >= x 的下标（lower bound）
  function firstAtLeast(arr, x) {
    let lo = 0, hi = n;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (arr[mid] < x) lo = mid + 1;
      else hi = mid;
    }
    return lo;
  }

  const cuToByte = (cu) => {
    if (cu <= cus[0]) return bytes[0] - (cus[0] - cu);
    if (cu > cus[n - 1]) return byteLen - (cuLen - cu);
    const i = firstAtLeast(cus, cu);
    return bytes[i] - (cus[i] - cu);
  };
  const byteToCU = (byte) => {
    if (byte <= bytes[0]) return cus[0] - (bytes[0] - byte);
    if (byte > bytes[n - 1]) return cuLen - (byteLen - byte);
    const i = firstAtLeast(bytes, byte);
    return cus[i] - (bytes[i] - byte);
  };
  return { cuToByte, byteToCU };
}

/// decisions 明文（.tsv，不压缩）
export function encodeDecisionsFile({ srcPath, sha256, tscVersion, records }) {
  const lines = [
    DECISIONS_HEADER,
    `# src: ${srcPath}`,
    `# sha256: ${sha256}`,
    `# tsc: ${tscVersion}`,
  ];
  for (const r of records) {
    lines.push(`D ${r.cls} ${r.startByte} ${r.endByte} ${r.startCU} ${r.endCU}`);
  }
  return lines.join("\n") + "\n";
}

export function decodeDecisionsFile(text) {
  let srcPath = null, sha256 = null, tscVersion = null;
  const records = [];
  for (const line of text.split("\n")) {
    if (line === "" || line === DECISIONS_HEADER) continue;
    if (line.startsWith("# src: ")) { srcPath = line.slice("# src: ".length); continue; }
    if (line.startsWith("# sha256: ")) { sha256 = line.slice("# sha256: ".length); continue; }
    if (line.startsWith("# tsc: ")) { tscVersion = line.slice("# tsc: ".length); continue; }
    const m = /^D (regex|tpl) (\d+) (\d+) (\d+) (\d+)$/.exec(line);
    if (!m) throw new Error(`decisions 文件存在无法解析的行: ${JSON.stringify(line)}`);
    records.push({
      cls: m[1],
      startByte: Number(m[2]),
      endByte: Number(m[3]),
      startCU: Number(m[4]),
      endCU: Number(m[5]),
    });
  }
  if (!srcPath || !sha256 || !tscVersion) throw new Error("decisions 文件缺少 # src / # sha256 / # tsc 头");
  return { srcPath, sha256, tscVersion, records };
}
