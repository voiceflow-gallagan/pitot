import assert from 'node:assert/strict';
import { test } from 'node:test';
import { normalizeKey } from '../lib/parse-keybindings.js';
import { matching, workspace } from '../support/workspace.js';

test('an action missing from the catalog is an ERROR', async (t) => {
  const ws = await workspace(t);
  await ws.editJson('keybindings.json', (data) => {
    data.actions = data.actions.filter((action) => action.id !== 'chat:stash');
  });
  const result = await ws.run();
  assert.equal(matching(result, 'ERROR', 'chat:stash', /docs list this action but the catalog does not/).length, 1);
});

test('a catalog action the docs no longer list is an ERROR', async (t) => {
  const ws = await workspace(t);
  await ws.editJson('keybindings.json', (data) => {
    data.actions.push({ id: 'chat:teleport', namespace: 'chat', contexts: ['Chat'], description: 'Not real' });
  });
  const result = await ws.run();
  assert.equal(matching(result, 'ERROR', 'chat:teleport', /in no docs action table/).length, 1);
});

test('context drift is an ERROR on both sides', async (t) => {
  const ws = await workspace(t);
  await ws.editJson('keybindings.json', (data) => {
    data.contexts = data.contexts.filter((context) => context.name !== 'Footer');
    data.contexts.push({ name: 'Doctor', description: 'Removed in v2.1.205' });
  });
  const result = await ws.run();
  assert.equal(matching(result, 'ERROR', 'Footer', /docs list this context/).length, 1);
  assert.equal(matching(result, 'ERROR', 'Doctor', /not in the docs Contexts table/).length, 1);
});

test('a changed default key is a WARN', async (t) => {
  const ws = await workspace(t);
  await ws.editJson('keybindings.json', (data) => {
    data.actions.find((action) => action.id === 'chat:submit').defaultKey = 'Ctrl+Enter';
  });
  const result = await ws.run();
  assert.equal(matching(result, 'WARN', 'chat:submit', /"Enter" in the docs but "Ctrl\+Enter" in the catalog/).length, 1);
});

test('a removed action in the docs is reported against the catalog row', async (t) => {
  const ws = await workspace(t);
  await ws.editPage('keybindings', (text) => text.replace(/^\| `plugin:favorite` .*\n/m, ''));
  const result = await ws.run();
  assert.equal(matching(result, 'ERROR', 'plugin:favorite', /in no docs action table/).length, 1);
});

test('key text is compared without markdown escapes, footnote marks or case', () => {
  assert.equal(normalizeKey('Shift+Tab\\*'), normalizeKey('Shift+Tab'));
  assert.equal(normalizeKey('Ctrl+\\_, Ctrl+Shift+-'), normalizeKey('Ctrl+_, Ctrl+Shift+-'));
  assert.equal(normalizeKey('`wheelup`'), 'wheelup');
  assert.equal(normalizeKey('(unbound)'), normalizeKey(undefined));
  assert.notEqual(normalizeKey('Enter'), normalizeKey('Enter, Space'));
});
