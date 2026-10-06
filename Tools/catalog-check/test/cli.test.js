import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { test } from 'node:test';
import { TOOL_DIR, tweak, workspace } from '../support/workspace.js';

const cli = (args) => spawnSync(process.execPath, [path.join(TOOL_DIR, 'check.js'), ...args], { encoding: 'utf8' });
const offlineArgs = (ws) => ['--offline', ws.pages, '--catalog', ws.catalog, '--known', ws.known];

test('exit code 0 and a PASS line on the saved pages', async (t) => {
  const ws = await workspace(t);
  const run = cli(offlineArgs(ws));
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.match(run.stdout, /Result: PASS\. 0 errors/);
});

test('exit code 1 and a grouped report when a row drifts', async (t) => {
  const ws = await workspace(t);
  await ws.editJson('tweaks.json', (data) => {
    tweak(data, 'maxEffortLevel').minVersion = '2.1.300';
  });
  const run = cli(offlineArgs(ws));
  assert.equal(run.status, 1);
  assert.match(run.stdout, /ERROR: a catalog row is wrong now \(1\)\n {2}\[tweaks\] maxEffortLevel: minVersion is 2\.1\.300/);
  assert.match(run.stdout, /Result: FAIL\. 1 errors/);
});

test('--json prints machine output with the same verdict', async (t) => {
  const ws = await workspace(t);
  const run = cli([...offlineArgs(ws), '--json']);
  assert.equal(run.status, 0);
  const report = JSON.parse(run.stdout);
  assert.equal(report.ok, true);
  assert.equal(report.counts.error, 0);
  assert.ok(Array.isArray(report.findings));
  assert.ok(report.uncataloged.settings.length > 0);
});

test('an unknown flag or a bad combination exits 2 with usage', () => {
  const unknown = cli(['--bogus']);
  assert.equal(unknown.status, 2);
  assert.match(unknown.stderr, /Usage: node check\.js/);
  const both = cli(['--offline', 'x', '--save', 'y']);
  assert.equal(both.status, 2);
});
