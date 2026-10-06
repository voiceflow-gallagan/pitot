import assert from 'node:assert/strict';
import path from 'node:path';
import { test } from 'node:test';
import { DEFAULT_SAVE_DIR, parseOptions } from '../lib/options.js';
import { TOOL_DIR } from '../support/workspace.js';

test('--save without a folder writes to the git-ignored cache folder', () => {
  assert.equal(DEFAULT_SAVE_DIR, path.join(TOOL_DIR, '.cache'));
  assert.equal(parseOptions(['--save']).save, DEFAULT_SAVE_DIR);
  const withFlag = parseOptions(['--save', '--json']);
  assert.equal(withFlag.save, DEFAULT_SAVE_DIR);
  assert.equal(withFlag.json, true);
});

test('--save keeps a folder given on the command line', () => {
  assert.equal(parseOptions(['--save', 'out']).save, 'out');
  assert.equal(parseOptions(['--save=out']).save, 'out');
});

test('--save refuses the synthetic fixtures folder', () => {
  assert.throws(() => parseOptions(['--save', path.join(TOOL_DIR, 'fixtures', 'pages')]), /fixtures/);
  assert.throws(() => parseOptions(['--save', path.join(TOOL_DIR, 'fixtures')]), /fixtures/);
});

test('--save cannot be combined with --offline', () => {
  assert.throws(() => parseOptions(['--offline', 'x', '--save']), /cannot be combined with --offline/);
});
