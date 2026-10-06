import assert from 'node:assert/strict';
import { test } from 'node:test';
import { headings, mentionsTerm, slugify, splitRow, stripInline, tables, toLines } from '../lib/markdown.js';
import { parseType } from '../lib/parse-settings.js';

test('table rows split on unescaped pipes outside code', () => {
  assert.deepEqual(splitRow('| `a|b` | c \\| d | e |'), ['`a|b`', 'c | d', 'e']);
});

test('a table ends at the first line that is not a row', () => {
  const lines = toLines('Intro\n\n| Action | Default |\n| :- | :- |\n| `chat:submit` | Enter |\n\n| Not | Table |');
  const [table, ...rest] = tables(lines);
  assert.deepEqual(table.headers, ['Action', 'Default']);
  assert.deepEqual(table.rows.map((row) => row.cells), [['`chat:submit`', 'Enter']]);
  assert.equal(rest.length, 0);
});

test('headings inside fenced code are ignored', () => {
  const lines = toLines('# Title\n```bash\n# not a heading\n```\n## Real');
  assert.deepEqual(headings(lines).map((h) => h.text), ['Title', 'Real']);
});

test('slugs match the docs anchors for dotted keys', () => {
  assert.equal(slugify('`permissions.defaultMode`'), 'permissions-defaultmode');
  assert.equal(slugify('Fields for `modelPicker`'), 'fields-for-modelpicker');
  assert.equal(slugify('Settings index'), 'settings-index');
});

test('inline markdown is stripped but code keeps angle brackets', () => {
  assert.equal(stripInline('[**`best`**](#x) and `custom:<slug>` <span id="y" />'), 'best and custom:<slug>');
});

test('terms count as mentioned in code, bold, link text or a cell', () => {
  const text = 'Use `opus[1m]` or **Default** or [Concise](#concise) | Learning |';
  for (const term of ['opus[1m]', 'Default', 'Concise', 'Learning']) assert.ok(mentionsTerm(text, term), term);
  assert.equal(mentionsTerm(text, 'opus'), false);
});

test('enum types read inline lists and sub-bullets, and split aliases and patterns', () => {
  const inline = parseType({ text: 'string, one of `"low"`, `"high"`, or `"max"`. A `"max"` value sets no cap', items: [] });
  assert.deepEqual(inline.values, ['low', 'high', 'max']);
  const bullets = parseType({
    text: 'string, one of:',
    items: ['`"default"`: normal', '`"manual"`: an alias for `"default"`', '`"custom:<slug>"`: a custom theme'],
  });
  assert.deepEqual(bullets.values, ['default']);
  assert.deepEqual(bullets.aliases, ['manual']);
  assert.deepEqual(bullets.patterns, ['custom:<slug>']);
  assert.equal(parseType({ text: 'Boolean', items: ['`true`: on'] }).kind, 'bool');
});
