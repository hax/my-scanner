#!/usr/bin/env node

import vm from 'node:vm';
import ts from 'typescript';

const MODES = {
  js: { fileName: 'probe.js', scriptKind: ts.ScriptKind.JS },
  jsx: { fileName: 'probe.jsx', scriptKind: ts.ScriptKind.JSX },
  ts: { fileName: 'probe.ts', scriptKind: ts.ScriptKind.TS },
  tsx: { fileName: 'probe.tsx', scriptKind: ts.ScriptKind.TSX },
};

const DEFAULT_OUT = '%^&|*/<=?';
const DEFAULT_IN = '=&|*?';
const ASCII_PUNCTUATION = String.raw`!"#$%&'()*+,-./:;<=>?@[\]^_` + '`{|}~';

const AUDIT_ASSUMPTIONS = [
  'regexp token boundaries are restored by the mandatory later regexp scan',
  'TypeScript leading union/intersection separators are recoverable and may be dropped',
];

const SAMPLES = [
  // Plain JS expressions. Several examples deliberately put a unary
  // expression or regexp immediately after a binary operator.
  'let a=1,b=2; a+b; a-b; a*b; a/b; a%b; a&b; a|b; a^b;',
  'let a=1,b=2; a%+b; a%-b; a%!b; a%~b; a%/x/.test("x");',
  'let a=1,b=2; a^+b; a^-b; a^!b; a^~b; a^/x/.test("x");',
  'let a=1,b=2; a&+b; a&-b; a&!b; a&~b; a&/x/.test("x");',
  'let a=1,b=2; a|+b; a|-b; a|!b; a|~b; a|/x/.test("x");',
  'let a=1,b=2; a*+b; a*-b; a*!b; a*~b; a*/x/.test("x");',
  'let a=1,b=2; a++&b; a++|b; a++*b;',
  'let a=1,b=2; a--&b; a--|b; a--*b;',
  'let b=2; /x/&b; /x/|b; /x/*b; /x/?b:0;',
  'let a=1,b=2; (a)&b; [a][0]&b; ({a:1}).a&b;',
  'let a=1,b=2; a&&b; a||b; a**b; a??b;',
  'let a=1,b=2; a%=b; a^=b; a&=b; a|=b; a*=b;',
  'let a=1,b=2; a!=b; a!==b; a==b; a===b; a=>b;',

  // TypeScript-only boundaries: postfix non-null assertion and generic
  // closers. Leading union/intersection probes are intentionally excluded per
  // AUDIT_ASSUMPTIONS.
  'let a:any,b:any; a!&b; a!|b; a!*b;',
  'type A={a:1}; type B={b:2}; type F<T>=T; type T4=F<A>&B; type T5=F<A>|B;',

  // JSX boundaries. Text inside an element is one JSXText token, while the
  // punctuation immediately following a closing element is a separate token.
  'const x=<div>&amp;</div>;',
  'const x=<>text</>;',
  'let b=1; const x=<div/>; x&&b;',
  'let b=1; const x=b&<div/>;',
  'let b=1; const x=b|<div/>;',
  'let b=1; const x=b*<div/>;',
  'let b=1; const x=(<div/>)&b;',
  'let b=1; const x=(<div/>)|b;',
  'let b=1; const x=(<div/>)*b;',
];

function argument(name, fallback) {
  const prefix = `--${name}=`;
  const value = process.argv.find(item => item.startsWith(prefix));
  return value ? value.slice(prefix.length) : fallback;
}

function selectedModes() {
  const requested = argument('modes', Object.keys(MODES).join(','))
    .split(',')
    .filter(Boolean);
  for (const mode of requested) {
    if (!MODES[mode]) throw new Error(`unknown mode: ${mode}`);
  }
  return requested;
}

function collectLeaves(node, sourceFile, result = []) {
  const children = node.getChildren(sourceFile);
  if (!children.length) {
    const start = node.getStart(sourceFile);
    if (start < node.end) {
      result.push({
        kind: ts.SyntaxKind[node.kind],
        start,
        end: node.end,
        text: sourceFile.text.slice(start, node.end),
      });
    }
    return result;
  }

  for (const child of children) collectLeaves(child, sourceFile, result);
  return result;
}

function parseInMode(source, mode, { fileName, scriptKind }) {
  if (mode === 'js') {
    try {
      new vm.Script(source);
    } catch {
      return [];
    }
  } else {
    const transpiled = ts.transpileModule(source, {
      fileName,
      reportDiagnostics: true,
      compilerOptions: {
        allowJs: true,
        checkJs: true,
        jsx: ts.JsxEmit.Preserve,
        target: ts.ScriptTarget.Latest,
      },
    });
    if (transpiled.diagnostics.some(diagnostic =>
      diagnostic.category === ts.DiagnosticCategory.Error)) {
      return [];
    }
  }

  const sourceFile = ts.createSourceFile(
    fileName,
    source,
    ts.ScriptTarget.Latest,
    true,
    scriptKind,
  );
  if (sourceFile.parseDiagnostics.length) return [];

  const leaves = collectLeaves(sourceFile, sourceFile)
    .sort((left, right) => left.start - right.start || left.end - right.end);
  const boundaries = [];

  for (let index = 1; index < leaves.length; index++) {
    const left = leaves[index - 1];
    const right = leaves[index];
    if (left.end !== right.start) continue;

    boundaries.push({
      left: source[left.end - 1],
      right: source[right.start],
      leftToken: left.text,
      rightToken: right.text,
      leftKind: left.kind,
      rightKind: right.kind,
      mode,
      source,
    });
  }

  return boundaries;
}

function uniqueCounterexamples(items) {
  const seen = new Set();
  return items.filter(item => {
    const key = [
      item.left,
      item.right,
      item.mode,
      item.leftToken,
      item.rightToken,
      item.source,
    ].join('\0');
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function isRecoveredBoundary(boundary) {
  return boundary.leftKind === 'RegularExpressionLiteral';
}

function printExample(example, indent = '    ') {
  console.log(
    `${indent}${JSON.stringify(example.left + example.right)} `
    + `[${example.mode}] ${JSON.stringify(example.leftToken)} | `
    + `${JSON.stringify(example.rightToken)}`,
  );
  console.log(`${indent}  ${example.source}`);
}

function oneExamplePerMode(examples) {
  const seen = new Set();
  return examples.filter(example => {
    if (seen.has(example.mode)) return false;
    seen.add(example.mode);
    return true;
  });
}

function auditAddition(side, char, outSet, inSet, boundaries) {
  const nextOut = new Set(outSet);
  const nextIn = new Set(inSet);
  if (side === 'out' || side === 'both') nextOut.add(char);
  if (side === 'in' || side === 'both') nextIn.add(char);

  return uniqueCounterexamples(boundaries.filter(boundary =>
    nextOut.has(boundary.left)
    && nextIn.has(boundary.right)
    && !(outSet.has(boundary.left) && inSet.has(boundary.right))));
}

function printAudit(
  side,
  candidates,
  outSet,
  inSet,
  boundaries,
  enabledModes,
) {
  console.log(`\nAdding one character to ${side.toUpperCase()}:`);
  for (const char of candidates) {
    const examples = auditAddition(side, char, outSet, inSet, boundaries);
    if (!examples.length) {
      console.log(`  ${JSON.stringify(char)}: no counterexample in samples`);
      continue;
    }

    const modes = [...new Set(examples.map(example => example.mode))].join('/');
    console.log(`  ${JSON.stringify(char)}: BLOCKED in ${modes}`);
    for (const example of oneExamplePerMode(examples)) {
      printExample(example, '    ');
    }
    const notObserved = enabledModes.filter(mode =>
      !examples.some(example => example.mode === mode));
    if (notObserved.length) {
      console.log(`    no counterexample observed in ${notObserved.join('/')}`);
    }
  }
}

function main() {
  const outText = argument('out', DEFAULT_OUT);
  const inText = argument('in', DEFAULT_IN);
  const outSet = new Set(outText);
  const inSet = new Set(inText);
  const enabledModes = selectedModes();
  const observedBoundaries = [];

  for (const source of SAMPLES) {
    for (const mode of enabledModes) {
      observedBoundaries.push(...parseInMode(source, mode, MODES[mode]));
    }
  }
  const recoveredBoundaries = observedBoundaries.filter(isRecoveredBoundary);
  const boundaries = observedBoundaries.filter(boundary =>
    !isRecoveredBoundary(boundary));

  const currentViolations = uniqueCounterexamples(boundaries.filter(boundary =>
    outSet.has(boundary.left) && inSet.has(boundary.right)));
  console.log(`TypeScript parser version: ${ts.version}`);
  console.log(`Current OUT: ${outText}`);
  console.log(`Current IN:  ${inText}`);
  console.log(`Modes: ${enabledModes.join('/')}`);
  console.log('Audit assumptions:');
  for (const assumption of AUDIT_ASSUMPTIONS) console.log(`  - ${assumption}`);
  console.log(
    `Valid adjacent token boundaries collected: ${observedBoundaries.length}`,
  );
  console.log(`Boundaries delegated to recovery: ${recoveredBoundaries.length}`);
  console.log(`Current-relation counterexamples: ${currentViolations.length}`);
  for (const example of currentViolations.slice(0, 10)) printExample(example);

  const outCandidates = [...ASCII_PUNCTUATION]
    .filter(char => !outSet.has(char));
  const inCandidates = [...ASCII_PUNCTUATION]
    .filter(char => !inSet.has(char));
  const bothCandidates = [...ASCII_PUNCTUATION]
    .filter(char => !outSet.has(char) || !inSet.has(char));

  printAudit(
    'out',
    outCandidates,
    outSet,
    inSet,
    boundaries,
    enabledModes,
  );
  printAudit(
    'in',
    inCandidates,
    outSet,
    inSet,
    boundaries,
    enabledModes,
  );
  printAudit(
    'both',
    bothCandidates,
    outSet,
    inSet,
    boundaries,
    enabledModes,
  );

  console.log(
    '\nThis is a samples-based counterexample search, not a grammar proof. '
    + 'A character with no reported counterexample still needs review before '
    + 'being added.',
  );
}

main();
