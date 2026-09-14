#!/usr/bin/env node
'use strict';

const DEFAULT_UCD_BASE = 'https://www.unicode.org/Public/UCD/latest/ucd';
const DEFAULT_SECURITY_BASE = 'https://www.unicode.org/Public/security/latest';
const UCD_BASE = process.env.UCD_BASE || DEFAULT_UCD_BASE;
const SECURITY_BASE = process.env.UNICODE_SECURITY_BASE || DEFAULT_SECURITY_BASE;
const SHOW_ALL = process.argv.includes('--all');
const MAX_CODE_POINT = 0x10ffff;

async function fetchText(base, path) {
  const url = `${base}/${path}`;
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`failed to fetch ${url}: HTTP ${response.status}`);
  }
  return { url, text: await response.text() };
}

function parseVersion(text, filePrefix) {
  const match = text.match(new RegExp(
    `^# ${filePrefix}-(\\d+\\.\\d+\\.\\d+)\\.txt$`,
    'm',
  ));
  if (!match) throw new Error(`cannot find Unicode version in ${filePrefix}`);
  return match[1];
}

function parseSecurityVersion(text) {
  const match = text.match(/^# Version: (\d+\.\d+\.\d+)$/m);
  if (!match) throw new Error('cannot find Unicode version in IdentifierStatus');
  return match[1];
}

function parseProperty(text, property) {
  const result = new Uint8Array(MAX_CODE_POINT + 1);

  for (const rawLine of text.split('\n')) {
    const line = rawLine.split('#', 1)[0].trim();
    if (!line) continue;

    const [rangeText, propertyText] = line.split(';').map(part => part.trim());
    if (propertyText !== property) continue;

    const [startText, endText = startText] = rangeText.split('..');
    const start = Number.parseInt(startText, 16);
    const end = Number.parseInt(endText, 16);
    result.fill(1, start, end + 1);
  }

  return result;
}

function encodeUtf8(codePoint) {
  if (codePoint <= 0x7ff) {
    return [
      0xc0 | (codePoint >> 6),
      0x80 | (codePoint & 0x3f),
    ];
  }
  if (codePoint <= 0xffff) {
    return [
      0xe0 | (codePoint >> 12),
      0x80 | ((codePoint >> 6) & 0x3f),
      0x80 | (codePoint & 0x3f),
    ];
  }
  return [
    0xf0 | (codePoint >> 18),
    0x80 | ((codePoint >> 12) & 0x3f),
    0x80 | ((codePoint >> 6) & 0x3f),
    0x80 | (codePoint & 0x3f),
  ];
}

// The high byte stores the prefix length. The low 24 bits store up to three
// UTF-8 prefix bytes. Full four-byte sequences are intentionally not prefixes.
function prefixKey(bytes, length) {
  return (
    (length << 24)
    | (bytes[0] << 16)
    | (length >= 2 ? bytes[1] << 8 : 0)
    | (length >= 3 ? bytes[2] : 0)
  ) >>> 0;
}

function keyLength(key) {
  return key >>> 24;
}

function keyBytes(key) {
  const length = keyLength(key);
  return [
    (key >>> 16) & 0xff,
    (key >>> 8) & 0xff,
    key & 0xff,
  ].slice(0, length);
}

function parentKeys(key) {
  const bytes = keyBytes(key);
  return Array.from(
    { length: bytes.length - 1 },
    (_, index) => prefixKey(bytes, index + 1),
  );
}

function formatBytes(bytes) {
  return bytes.map(byte => byte.toString(16).toUpperCase().padStart(2, '0')).join(' ');
}

function formatRanges(keys) {
  const sorted = [...keys].sort((a, b) =>
    keyLength(a) - keyLength(b) || a - b);
  const ranges = [];

  for (const key of sorted) {
    const previous = ranges.at(-1);
    if (
      previous
      && keyLength(previous.end) === keyLength(key)
      && previous.end + 1 === key
    ) {
      previous.end = key;
    } else {
      ranges.push({ start: key, end: key });
    }
  }

  return ranges.map(({ start, end }) => {
    const first = formatBytes(keyBytes(start));
    return start === end ? first : `${first} .. ${formatBytes(keyBytes(end))}`;
  });
}

function collectPrefixStats(analyses) {
  const stats = Object.fromEntries(
    Object.keys(analyses).map(name => [
      name,
      { eligibleCodePoints: 0, totals: new Map(), matches: new Map() },
    ]),
  );

  for (let codePoint = 0x80; codePoint <= MAX_CODE_POINT; codePoint++) {
    if (codePoint >= 0xd800 && codePoint <= 0xdfff) continue;

    const bytes = encodeUtf8(codePoint);
    for (const [name, analysis] of Object.entries(analyses)) {
      if (!analysis.include(codePoint)) continue;

      const current = stats[name];
      current.eligibleCodePoints++;
      for (let length = 1; length < bytes.length; length++) {
        const key = prefixKey(bytes, length);
        current.totals.set(key, (current.totals.get(key) || 0) + 1);
        if (analysis.match(codePoint)) {
          current.matches.set(key, (current.matches.get(key) || 0) + 1);
        }
      }
    }
  }

  return stats;
}

function guaranteedPrefixes(totals, matches) {
  return new Set(
    [...totals]
      .filter(([key, total]) => matches.get(key) === total)
      .map(([key]) => key),
  );
}

function minimalPrefixes(guaranteed) {
  return [...guaranteed].filter(key =>
    parentKeys(key).every(parent => !guaranteed.has(parent)));
}

function printAnalysis(name, { eligibleCodePoints, totals, matches }) {
  const guaranteed = guaranteedPrefixes(totals, matches);
  const minimal = minimalPrefixes(guaranteed);
  const firstBytes = [...guaranteed].filter(key => keyLength(key) === 1);
  const counts = new Map();

  for (const key of minimal) {
    const length = keyLength(key);
    counts.set(length, (counts.get(length) || 0) + 1);
  }

  console.log(`\n${name}`);
  console.log(`  eligible non-ASCII scalar values: ${eligibleCodePoints}`);
  console.log(`  all-completion first bytes: ${
    formatRanges(firstBytes).join(', ') || '(none)'
  }`);
  console.log(`  minimal guaranteed proper prefixes: ${minimal.length}`);
  console.log(`  by prefix length: ${
    [...counts].sort(([a], [b]) => a - b)
      .map(([length, count]) => `${length}-byte=${count}`)
      .join(', ') || '(none)'
  }`);

  if (SHOW_ALL && minimal.length) {
    for (const [length, count] of [...counts].sort(([a], [b]) => a - b)) {
      const keys = minimal.filter(key => keyLength(key) === length);
      console.log(`  ${length}-byte prefixes (${count}):`);
      for (const range of formatRanges(keys)) console.log(`    ${range}`);
    }
  }
}

async function main() {
  const [derived, propList, categories, identifierStatus] = await Promise.all([
    fetchText(UCD_BASE, 'DerivedCoreProperties.txt'),
    fetchText(UCD_BASE, 'PropList.txt'),
    fetchText(UCD_BASE, 'extracted/DerivedGeneralCategory.txt'),
    fetchText(SECURITY_BASE, 'IdentifierStatus.txt'),
  ]);
  const derivedVersion = parseVersion(derived.text, 'DerivedCoreProperties');
  const propListVersion = parseVersion(propList.text, 'PropList');
  const categoriesVersion = parseVersion(
    categories.text,
    'DerivedGeneralCategory',
  );
  const securityVersion = parseSecurityVersion(identifierStatus.text);
  const versions = new Set([
    derivedVersion,
    propListVersion,
    categoriesVersion,
    securityVersion,
  ]);
  if (versions.size !== 1) {
    throw new Error(
      `Unicode version mismatch: ${[...versions].join(', ')}`,
    );
  }

  const idContinue = parseProperty(derived.text, 'ID_Continue');
  const whiteSpace = parseProperty(propList.text, 'White_Space');
  const deprecated = parseProperty(propList.text, 'Deprecated');
  const privateUse = parseProperty(categories.text, 'Co');
  const spaceSeparator = parseProperty(categories.text, 'Zs');
  const identifierAllowed = parseProperty(identifierStatus.text, 'Allowed');
  const ecmaWhitespace = spaceSeparator.slice();
  for (const codePoint of [
    0x0009, // CHARACTER TABULATION
    0x000b, // LINE TABULATION
    0x000c, // FORM FEED
    0x0020, // SPACE
    0x00a0, // NO-BREAK SPACE
    0xfeff, // ZERO WIDTH NO-BREAK SPACE
    0x000a, // LINE FEED
    0x000d, // CARRIAGE RETURN
    0x2028, // LINE SEPARATOR
    0x2029, // PARAGRAPH SEPARATOR
  ]) {
    ecmaWhitespace[codePoint] = 1;
  }
  const includeAll = () => true;

  const analyses = {
    'ID_Continue / all scalar values': {
      include: includeAll,
      match: codePoint => idContinue[codePoint],
    },
    'ID_Continue / globally exclude Private_Use and Deprecated': {
      include: codePoint => !privateUse[codePoint] && !deprecated[codePoint],
      match: codePoint => idContinue[codePoint],
    },
    'ID_Continue / globally allow only UTS #39 Identifier_Status=Allowed': {
      include: codePoint => identifierAllowed[codePoint],
      match: codePoint => idContinue[codePoint],
    },
    'White_Space / all scalar values': {
      include: includeAll,
      match: codePoint => whiteSpace[codePoint],
    },
    'Non-ECMAScript-whitespace / valid-source sticky approximation': {
      include: includeAll,
      match: codePoint => !ecmaWhitespace[codePoint],
    },
  };
  const stats = collectPrefixStats(analyses);

  console.log(`Unicode version: ${derivedVersion}`);
  console.log(`UCD base: ${UCD_BASE}`);
  console.log(`Security data base: ${SECURITY_BASE}`);
  console.log(
    'A proper prefix omits at least one trailing UTF-8 byte; full code-point '
    + 'encodings are excluded.',
  );
  console.log(
    'Exclusion policies model code points that cannot occur anywhere in the '
    + 'input, not merely code points forbidden inside identifiers.',
  );
  for (const [name] of Object.entries(analyses)) {
    printAnalysis(name, stats[name]);
  }
  if (!SHOW_ALL) console.log('\nUse --all to list every minimal prefix.');
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
