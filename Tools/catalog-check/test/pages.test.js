import assert from 'node:assert/strict';
import { rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { test } from 'node:test';
import { matching, workspace } from '../support/workspace.js';

const parseErrors = (result, page) => result.findings.filter((f) => f.severity === 'ERROR' && f.subject === page && /cannot (parse|load)/.test(f.message));

test('a settings page that no longer parses is an ERROR and its rows are skipped, not passed', async (t) => {
  const ws = await workspace(t);
  await ws.editPage('settings-reference', () => '# All settings\n\nThis page moved.\n');
  const result = await ws.run();
  assert.ok(parseErrors(result, 'settings-reference').length > 0);
  assert.equal(result.findings.filter((f) => f.area === 'tweaks' && f.severity === 'ERROR').length, 0);
  assert.ok(result.counts.error > 0);
});

test('a renamed table header is an ERROR naming the page', async (t) => {
  const ws = await workspace(t);
  await ws.editPage('env-vars', (text) => text.replace('| Variable | Purpose |', '| Name | Purpose |'));
  const result = await ws.run();
  assert.equal(matching(result, 'ERROR', 'env-vars', /cannot parse env-vars: the Variables section has no table with a Variable column/).length, 1);
});

test('keybinding action tables in a new format are an ERROR', async (t) => {
  const ws = await workspace(t);
  await ws.editPage('keybindings', (text) => text.replaceAll('| Action | Default | Description |', '| Name | Key | Description |'));
  const result = await ws.run();
  assert.equal(matching(result, 'ERROR', 'keybindings', /no action tables/).length, 1);
});

test('a lost alias table on a secondary page is an ERROR', async (t) => {
  const ws = await workspace(t);
  await ws.editPage('model-config', (text) => text.replace('### Model aliases', '### Aliases you can use'));
  const result = await ws.run();
  assert.equal(matching(result, 'ERROR', 'model-config', /"Model aliases" table is missing/).length, 1);
});

test('a missing or HTML page is an ERROR', async (t) => {
  const ws = await workspace(t);
  await rm(path.join(ws.pages, 'sub-agents.md'));
  await writeFile(path.join(ws.pages, 'output-styles.md'), '<!DOCTYPE html><html><body>Sign in</body></html>');
  const result = await ws.run();
  assert.equal(matching(result, 'ERROR', 'sub-agents', /cannot load sub-agents: no saved page/).length, 1);
  assert.equal(matching(result, 'ERROR', 'output-styles', /cannot load output-styles: the saved page is HTML/).length, 1);
});

test('key entries in a new format are an ERROR, not a silent pass', async (t) => {
  const ws = await workspace(t);
  await ws.editPage('settings-reference', (text) => text.replaceAll('* **Default**:', '* **Default value**:'));
  const result = await ws.run();
  assert.equal(matching(result, 'ERROR', 'settings-reference', /most key entries have no "\* \*\*Default\*\*:" line/).length, 1);
});
