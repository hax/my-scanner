#!/usr/bin/env node
// 从 Unicode UCD 的 DerivedCoreProperties.txt 生成 src/unicode_tables.zig
// （ID_Start / ID_Continue 两级位图，供 scanner 判定 unicode 标识符字符）。
//
//   node tools/gen_unicode_tables.mjs              # 拉最新 UCD
//   node tools/gen_unicode_tables.mjs --from-zig   # 用现有 zig 里的范围表
//                                                  # 转换（零版本漂移）
//   UCD_BASE=http://localhost:8888 node ...        # 用镜像
//
// 表结构（unicode-ident 方案）：码点按 512 个分块，root[cp>>9]（u8）
// 映射到去重后的叶；每叶 512 bit = 8×u64。一次查询 = root 一次 load +
// 叶一次 load，O(1)，替代此前的范围表二分（~10 次比较）——中文标识符
// 密集语料上每个字符都要查，值得。
// 生成时自检：位图与范围表在全码点空间（0..0x10FFFF）逐点一致。

import { readFileSync, writeFileSync } from "node:fs";

const UCD_BASE = process.env.UCD_BASE || "https://www.unicode.org/Public/UCD/latest/ucd";
const OUT = new URL("../src/unicode_tables.zig", import.meta.url).pathname;
const FROM_ZIG = process.argv.includes("--from-zig");

const CHUNK = 512; // 码点/块（cp >> 9）
const WORDS = CHUNK / 64; // 8 × u64 / 叶
const NCHUNKS = 0x110000 / CHUNK; // 2176

async function loadRanges() {
  if (FROM_ZIG) {
    // 解析现有 unicode_tables.zig 的范围表（保持同一 Unicode 版本）
    const text = readFileSync(OUT, "utf8");
    const version = text.match(/Unicode ([0-9.]+) DerivedCoreProperties/)?.[1] ?? "unknown";
    const grab = (name) => {
      const body = text.match(new RegExp(`pub const ${name} = \\[_\\]Range\\{([\\s\\S]*?)\\};`))?.[1];
      if (!body) throw new Error(`parse ${name} failed`);
      return [...body.matchAll(/\.\{ \.lo = 0x([0-9a-f]+), \.hi = 0x([0-9a-f]+) \}/g)]
        .map((m) => [parseInt(m[1], 16), parseInt(m[2], 16)]);
    };
    return { start: grab("id_start"), cont: grab("id_continue"), version };
  }
  const url = `${UCD_BASE}/DerivedCoreProperties.txt`;
  console.log(`fetching ${url} ...`);
  const res = await fetch(url);
  if (!res.ok) throw new Error(`fetch failed: ${res.status}`);
  const text = await res.text();
  const version = text.match(/^# DerivedCoreProperties-([0-9.]+)\.txt$/m)?.[1] ?? "unknown";

  const start = [];
  const cont = [];
  for (const line of text.split("\n")) {
    if (line.startsWith("#") || line.trim() === "") continue;
    const m = line.match(/^([0-9A-F]+)(?:\.\.([0-9A-F]+))?\s*;\s*(\w+)/);
    if (!m) continue;
    const lo = parseInt(m[1], 16);
    const hi = m[2] ? parseInt(m[2], 16) : lo;
    if (m[3] === "ID_Start") start.push([lo, hi]);
    else if (m[3] === "ID_Continue") cont.push([lo, hi]);
  }
  if (start.length === 0 || cont.length === 0) throw new Error("parse failed");

  // ECMAScript IdentifierPart 显式包含 ZWNJ/U+200C 与 ZWJ/U+200D
  cont.push([0x200c, 0x200d]);

  const norm = (rs) =>
    rs.sort((a, b) => a[0] - b[0]).reduce((acc, [lo, hi]) => {
      const last = acc[acc.length - 1];
      if (last && lo <= last[1] + 1) last[1] = Math.max(last[1], hi);
      else acc.push([lo, hi]);
      return acc;
    }, []);
  // ASCII 部分由 scanner 的 ASCII 快路径处理，表只覆盖 >= 0x80 的码点
  return {
    start: norm(start).filter(([lo]) => lo >= 0x80),
    cont: norm(cont).filter(([lo]) => lo >= 0x80),
    version,
  };
}

// 范围表 → 两级位图（叶去重），附全码点自检
function buildBitmap(ranges) {
  const chunks = new Array(NCHUNKS);
  for (let c = 0; c < NCHUNKS; c++) chunks[c] = new BigUint64Array(WORDS);
  for (const [lo, hi] of ranges) {
    for (let cp = lo; cp <= hi; cp++) {
      chunks[cp >> 9][(cp >> 6) & (WORDS - 1)] |= 1n << BigInt(cp & 63);
    }
  }
  // 叶去重：内容相同的块共享叶；root 项是 u8，叶数必须 <= 255
  const leaves = [];
  const leafIndex = new Map();
  const root = new Uint8Array(NCHUNKS);
  for (let c = 0; c < NCHUNKS; c++) {
    const key = chunks[c].join(",");
    let idx = leafIndex.get(key);
    if (idx === undefined) {
      idx = leaves.length;
      leafIndex.set(key, idx);
      leaves.push(chunks[c]);
      if (leaves.length > 255) throw new Error(`too many unique leaves: ${leaves.length}`);
    }
    root[c] = idx;
  }
  // 自检：全码点空间逐点比对位图与范围表
  let ri = 0;
  for (let cp = 0; cp < 0x110000; cp++) {
    while (ri < ranges.length && cp > ranges[ri][1]) ri++;
    const want = ri < ranges.length && cp >= ranges[ri][0] && cp <= ranges[ri][1];
    const got = (leaves[root[cp >> 9]][(cp >> 6) & (WORDS - 1)] >> BigInt(cp & 63)) & 1n;
    if (want !== (got === 1n)) throw new Error(`bitmap mismatch at U+${cp.toString(16)}`);
  }
  return { root, leaves };
}

function emit(name, { root, leaves }) {
  const fmtU8 = (arr) => {
    let s = "";
    for (let i = 0; i < arr.length; i += 32) {
      s += "    " + [...arr.subarray(i, i + 32)].join(",") + ",\n";
    }
    return s;
  };
  const fmtU64 = (arr) => {
    let s = "";
    for (const leaf of arr) {
      s += "    " + [...leaf].map((w) => `0x${w.toString(16)}`).join(",") + ",\n";
    }
    return s;
  };
  return (
    `pub const ${name}_root = [${NCHUNKS}]u8{\n${fmtU8(root)}};\n\n` +
    `pub const ${name}_leaves = [${leaves.length * WORDS}]u64{\n${fmtU64(leaves)}};\n`
  );
}

async function main() {
  const { start, cont, version } = await loadRanges();
  const startBmp = buildBitmap(start);
  const contBmp = buildBitmap(cont);
  const src = `//! unicode 标识符字符表（由 tools/gen_unicode_tables.mjs 生成，勿手改）。
//! 来源：Unicode ${version} DerivedCoreProperties 的 ID_Start / ID_Continue，
//! ID_Continue 追加 ECMAScript IdentifierPart 显式包含的 ZWNJ(U+200C)/ZWJ(U+200D)。
//! ASCII 部分由 scanner 的 ASCII 快路径处理，表只覆盖 >= 0x80 的码点。
//!
//! 两级位图：root[cp >> 9] 索引去重叶，每叶 512 bit（8×u64）覆盖 512 个
//! 码点。查询 = 2 次 load + shift/mask，O(1)。生成时已自检位图与范围表
//! 在全码点空间逐点一致。

pub const chunk_shift = 9; // 512 码点/块
pub const leaf_words = 8; // u64/叶

${emit("id_start", startBmp)}
${emit("id_continue", contBmp)}
`;
  writeFileSync(OUT, src);
  console.log(
    `wrote ${OUT}: id_start ${startBmp.leaves.length} leaves, id_continue ${contBmp.leaves.length} leaves, Unicode ${version}` +
      (FROM_ZIG ? " (from existing zig ranges)" : ""),
  );
}

main();
