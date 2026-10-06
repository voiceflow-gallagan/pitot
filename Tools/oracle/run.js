const fs = require('fs');
const path = require('path');
const { modify, applyEdits } = require('jsonc-parser');

const root = path.resolve(__dirname, '..', '..');
const fixturesDir = path.join(root, 'Fixtures');
const expectedDir = path.join(fixturesDir, 'expected');
const ops = JSON.parse(fs.readFileSync(path.join(__dirname, 'ops.json'), 'utf8'));

function detectFormat(text) {
  const eol = text.includes('\r\n') ? '\r\n' : '\n';
  const indented = text.split(/\r?\n/).find((line) => /^[ \t]+\S/.test(line));
  let insertSpaces = true;
  let tabSize = 2;
  if (indented) {
    if (indented[0] === '\t') {
      insertSpaces = false;
      tabSize = 1;
    } else {
      tabSize = indented.match(/^ +/)[0].length;
    }
  }
  return { eol, insertSpaces, tabSize, insertFinalNewline: /\n$/.test(text) };
}

function generate() {
  const counters = new Map();
  const outputs = new Map();
  const deviations = new Map();
  for (const { fixture, op, path: keyPath, value, swiftExpected } of ops) {
    const text = fs.readFileSync(path.join(fixturesDir, `${fixture}.json`), 'utf8');
    const edits = modify(text, keyPath, op === 'remove' ? undefined : value, {
      formattingOptions: detectFormat(text),
      isArrayInsertion: op === 'insert',
    });
    const n = (counters.get(fixture) ?? 0) + 1;
    counters.set(fixture, n);
    const name = `${fixture}.${n}.json`;
    outputs.set(name, applyEdits(text, edits));
    if (swiftExpected) deviations.set(name, swiftExpected);
  }
  return { outputs, deviations };
}

const { outputs, deviations } = generate();

if (process.argv.includes('--check')) {
  const expectedNames = new Set(fs.existsSync(expectedDir) ? fs.readdirSync(expectedDir) : []);
  const mismatches = [];
  for (const [name, content] of outputs) {
    expectedNames.delete(name);
    if (deviations.has(name)) {
      if (!fs.existsSync(path.join(root, deviations.get(name)))) mismatches.push(`${name} (missing swiftExpected)`);
      continue;
    }
    const file = path.join(expectedDir, name);
    if (!fs.existsSync(file) || fs.readFileSync(file, 'utf8') !== content) mismatches.push(name);
  }
  for (const stale of expectedNames) mismatches.push(`${stale} (stale)`);
  if (mismatches.length > 0) {
    console.error(`oracle mismatch: ${mismatches.join(', ')}`);
    process.exit(1);
  }
  console.log(`oracle ok: ${outputs.size - deviations.size} operations, ${deviations.size} deviations skipped`);
} else {
  fs.mkdirSync(expectedDir, { recursive: true });
  for (const stale of fs.readdirSync(expectedDir)) fs.rmSync(path.join(expectedDir, stale));
  for (const [name, content] of outputs) fs.writeFileSync(path.join(expectedDir, name), content);
  console.log(`wrote ${outputs.size} expected files`);
}
