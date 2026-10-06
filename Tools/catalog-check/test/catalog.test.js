import assert from 'node:assert/strict';
import { test } from 'node:test';
import { matching, tweak, workspace } from '../support/workspace.js';

test('the fixture catalog has no ERROR against the synthetic pages', async (t) => {
  const ws = await workspace(t);
  const result = await ws.run();
  assert.equal(result.counts.error, 0, JSON.stringify(result.findings.filter((f) => f.severity === 'ERROR'), null, 2));
  assert.ok(result.findings.every((f) => f.severity !== 'ERROR'));
  assert.equal(result.pages.length, 6);
  assert.ok(result.pages.every((page) => !page.error));
});

test('a renamed setting key is an ERROR on its row', async (t) => {
  const ws = await workspace(t);
  await ws.editJson('tweaks.json', (data) => {
    tweak(data, 'editorMode').location.path = ['editorModus'];
  });
  const result = await ws.run();
  assert.equal(matching(result, 'ERROR', 'editorMode', /editorModus is not on settings-reference/).length, 1);
});

test('a renamed env var is an ERROR on its row', async (t) => {
  const ws = await workspace(t);
  await ws.editJson('tweaks.json', (data) => {
    tweak(data, 'DISABLE_TELEMETRY').location.name = 'DISABLE_TELEMETRY_NOW';
  });
  const result = await ws.run();
  assert.equal(matching(result, 'ERROR', 'DISABLE_TELEMETRY', /DISABLE_TELEMETRY_NOW is not on env-vars/).length, 1);
});

test('an undocumented enum value is an ERROR and the dropped documented value a WARN', async (t) => {
  const ws = await workspace(t);
  await ws.editJson('tweaks.json', (data) => {
    tweak(data, 'theme').valueType.options.find((option) => option.value === 'light').value = 'lite';
  });
  const result = await ws.run();
  assert.equal(matching(result, 'ERROR', 'theme', /enum value "lite" is not documented/).length, 1);
  assert.equal(matching(result, 'WARN', 'theme', /documented value "light" is not in the catalog/).length, 1);
});

test('minVersion drift is an ERROR in every direction', async (t) => {
  const ws = await workspace(t);
  await ws.editJson('tweaks.json', (data) => {
    tweak(data, 'maxEffortLevel').minVersion = '2.1.268';
    delete tweak(data, 'promptCacheTtl').minVersion;
    tweak(data, 'tui').minVersion = '2.1.100';
    tweak(data, 'CLAUDE_CODE_SUBAGENT_MODEL_FORCE').minVersion = '2.1.258';
  });
  const result = await ws.run();
  assert.equal(matching(result, 'ERROR', 'maxEffortLevel', /minVersion is 2\.1\.268 but settings-reference says "Requires Claude Code v2\.1\.267"/).length, 1);
  assert.equal(matching(result, 'ERROR', 'promptCacheTtl', /v2\.1\.242" but the row has no minVersion/).length, 1);
  assert.equal(matching(result, 'ERROR', 'tui', /states no version/).length, 1);
  assert.equal(matching(result, 'ERROR', 'CLAUDE_CODE_SUBAGENT_MODEL_FORCE', /env-vars says "Requires Claude Code v2\.1\.257"/).length, 1);
});

test('a scope that no longer matches the docs is an ERROR', async (t) => {
  const ws = await workspace(t);
  await ws.editJson('tweaks.json', (data) => {
    delete tweak(data, 'askUserQuestionTimeout').scope;
    tweak(data, 'theme').scope = 'userOnly';
  });
  const result = await ws.run();
  assert.equal(matching(result, 'ERROR', 'askUserQuestionTimeout', /"User or managed" but the row is not scope userOnly/).length, 1);
  assert.equal(matching(result, 'ERROR', 'theme', /"Any file" but the row is scope userOnly/).length, 1);
});

test('a bool row whose docs type changed is an ERROR', async (t) => {
  const ws = await workspace(t);
  await ws.editJson('tweaks.json', (data) => {
    tweak(data, 'editorMode').valueType = { type: 'bool' };
  });
  const result = await ws.run();
  assert.equal(matching(result, 'ERROR', 'editorMode', /the row is bool but the docs type/).length, 1);
});

test('an undocumented suggestion is an ERROR', async (t) => {
  const ws = await workspace(t);
  await ws.editJson('tweaks.json', (data) => {
    tweak(data, 'model').suggestions.push({ value: 'opus-max', label: 'Opus max' });
  });
  const result = await ws.run();
  assert.equal(matching(result, 'ERROR', 'model', /suggestion "opus-max" is not documented on model-config/).length, 1);
});

test('a default that no longer matches is a WARN, not an ERROR', async (t) => {
  const ws = await workspace(t);
  await ws.editJson('tweaks.json', (data) => {
    tweak(data, 'theme').defaultDescription = 'light';
    tweak(data, 'fastMode').defaultDescription = 'true: fast mode is on.';
  });
  const result = await ws.run();
  assert.equal(result.counts.error, 0);
  assert.equal(matching(result, 'WARN', 'theme', /docs default is "dark"/).length, 1);
  assert.equal(matching(result, 'WARN', 'fastMode', /docs default is "unset, fast mode stays off"/).length, 1);
});

test('a broken docURL anchor is a WARN', async (t) => {
  const ws = await workspace(t);
  await ws.editJson('tweaks.json', (data) => {
    tweak(data, 'tui').docURL = 'https://code.claude.com/docs/en/settings-reference#no-such-key';
  });
  const result = await ws.run();
  assert.equal(matching(result, 'WARN', 'tui', /anchor #no-such-key is not on settings-reference/).length, 1);
});

test('an env var that project and local settings cannot set must be userOnly', async (t) => {
  const ws = await workspace(t);
  await ws.editJson('tweaks.json', (data) => {
    tweak(data, 'ANTHROPIC_BASE_URL').location.name = 'CLAUDE_CONFIG_DIR';
    tweak(data, 'CLAUDE_CODE_NEW_INIT').location.name = 'CLAUDE_CODE_EXAMPLE_LAUNCH_ONLY';
  });
  const result = await ws.run();
  assert.equal(matching(result, 'ERROR', 'ANTHROPIC_BASE_URL', /project and local settings cannot set CLAUDE_CONFIG_DIR/).length, 1);
  assert.equal(matching(result, 'ERROR', 'CLAUDE_CODE_NEW_INIT', /ignores CLAUDE_CODE_EXAMPLE_LAUNCH_ONLY in every settings file/).length, 1);
});

test('a docURL anchor that exists but belongs to another key is a WARN', async (t) => {
  const ws = await workspace(t);
  await ws.editJson('tweaks.json', (data) => {
    tweak(data, 'tui').docURL = 'https://code.claude.com/docs/en/settings-reference#theme';
  });
  const result = await ws.run();
  assert.equal(matching(result, 'WARN', 'tui', /points to #theme but the settings index links tui to #tui/).length, 1);
});
