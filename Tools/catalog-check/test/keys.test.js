import assert from 'node:assert/strict';
import { test } from 'node:test';
import { matching, replaceOnce, workspace } from '../support/workspace.js';

const indexRow = (key) => `| [\`${key}\`](#${key.toLowerCase()}) | Added for the test | Interface and terminal | Any file |\n`;
const section = (key) => `### \`${key}\`\n\nAdded for the test.\n\n* **Scope**: [\`Any file\`](#scopes)\n* **Type**: Boolean\n* **Default**: \`false\`\n\n`;

test('a setting and an env var new in the docs are listed as candidates to add', async (t) => {
  const ws = await workspace(t);
  await ws.editPage('settings-reference', (text) => {
    const withRow = replaceOnce(text, '| [`agent`](#agent) |', `${indexRow('brandNewSetting')}| [\`agent\`](#agent) |`);
    return replaceOnce(withRow, '### `alwaysThinkingEnabled`', `${section('brandNewSetting')}### \`alwaysThinkingEnabled\``);
  });
  await ws.editPage('env-vars', (text) => replaceOnce(text, '| `ANTHROPIC_API_KEY` |', '| `CLAUDE_CODE_BRAND_NEW` | Added for the test |\n| `ANTHROPIC_API_KEY` |'));
  const result = await ws.run();
  assert.equal(matching(result, 'INFO', 'brandNewSetting', /new setting on settings-reference since the last baseline: candidate to add/).length, 1);
  assert.equal(matching(result, 'INFO', 'CLAUDE_CODE_BRAND_NEW', /new env var on env-vars since the last baseline/).length, 1);
  assert.ok(result.uncataloged.settings.includes('brandNewSetting'));
  assert.equal(result.counts.error, 0);
});

test('an unverified key that is now documented is listed for promotion, not as new', async (t) => {
  const ws = await workspace(t);
  await ws.editPage('settings-reference', (text) => replaceOnce(text, '| [`agent`](#agent) |', `${indexRow('exampleUnverifiedSetting')}| [\`agent\`](#agent) |`));
  const result = await ws.run();
  assert.equal(matching(result, 'INFO', 'exampleUnverifiedSetting', /now documented on settings-reference: promote it/).length, 1);
  assert.equal(matching(result, 'INFO', 'exampleUnverifiedSetting', /candidate to add/).length, 0);
});

test('a key gone from the docs since the baseline is listed as removed', async (t) => {
  const ws = await workspace(t);
  await ws.editPage('settings-reference', (text) =>
    text.replace(/^\| \[`language`\].*\n/m, '').replace(/### `language`[\s\S]*?(?=### `maxEffortLevel`)/, ''),
  );
  const result = await ws.run();
  assert.equal(matching(result, 'INFO', 'language', /gone from settings-reference: deprecated or removed/).length, 1);
});

test('a catalog row whose key left the docs is an ERROR as well as a removal note', async (t) => {
  const ws = await workspace(t);
  await ws.editPage('settings-reference', (text) =>
    text.replace(/^\| \[`fastMode`\].*\n/m, '').replace(/### `fastMode`[\s\S]*?(?=### `fastModePerSessionOptIn`)/, ''),
  );
  const result = await ws.run();
  assert.equal(matching(result, 'ERROR', 'fastMode', /setting fastMode is not on settings-reference/).length, 1);
  assert.equal(matching(result, 'INFO', 'fastMode', /deprecated or removed/).length, 1);
});
