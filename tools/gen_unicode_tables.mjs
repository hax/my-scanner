#!/usr/bin/env node
// 从 Unicode UCD 的 DerivedCoreProperties.txt 生成 src/unicode_tables.zig
// （ID_Start / ID_Continue 范围表，供 scanner 判定 unicode 标识符字符）。
//
//   node tools/gen_unicode_tables.mjs            # 拉最新 UCD
//   UCD_BASE=http://localhost:8888 node ...      # 用镜像
//
// 生成的表是范围并集（已排序、去重叠），运行时二分查找。

import { writeFileSync } from "node:fs";

const UCD_BASE = process.env.UCD_BASE || "https://www.unicode.org/Public/UCD/latest/ucd";
const OUT = new URL("../src/unicode_tables.zig", import.meta.url).pathname;

async function main() {
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

  const emit = (name, rs) =>
    `pub const ${name} = [_]Range{\n` +
    rs.map(([lo, hi]) => `    .{ .lo = 0x${lo.toString(16)}, .hi = 0x${hi.toString(16)} },`).join("\n") +
    `\n};\n`;

  const src = `//! unicode 标识符字符表（由 tools/gen_unicode_tables.mjs 生成，勿手改）。
//! 来源：Unicode ${version} DerivedCoreProperties 的 ID_Start / ID_Continue，
//! ID_Continue 追加 ECMAScript IdentifierPart 显式包含的 ZWNJ(U+200C)/ZWJ(U+200D)。
//! ASCII 部分由 scanner 的 ASCII 快路径处理，表只覆盖 >= 0x80 的码点。

pub const Range = struct { lo: u21, hi: u21 };

${emit("id_start", norm(start).filter(([lo]) => lo >= 0x80))}
${emit("id_continue", norm(cont).filter(([lo]) => lo >= 0x80))}
`;
  writeFileSync(OUT, src);
  console.log(`wrote ${OUT}: id_start ${norm(start).length} ranges (>=0x80: ${norm(start).filter(([l]) => l >= 0x80).length}), id_continue ${norm(cont).length} (>=0x80: ${norm(cont).filter(([l]) => l >= 0x80).length}), Unicode ${version}`);
}

main();
