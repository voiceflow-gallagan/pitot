import assert from 'node:assert/strict';
import { test } from 'node:test';
import { normalizeKey, parseKeybindings } from '../lib/parse-keybindings.js';
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

/** Contexts the parser gives each action of a one-section page with the given intro paragraph. */
function parsedContexts(contexts, intro, ids) {
  const page = [
    '## Contexts', '', '| Context | Description |', '| :- | :- |', ...contexts.map((name) => `| \`${name}\` | ${name} |`), '',
    '## Available actions', '', '### Some actions', '', intro, '',
    '| Action | Default | Description |', '| :- | :- | :- |', ...ids.map((id) => `| \`${id}\` | (unbound) | ${id} |`), '',
  ].join('\n');
  return Object.fromEntries(parseKeybindings(page).actions.map((action) => [action.id, action.contexts]));
}

test('a sentence that names actions gives its contexts to those actions only', () => {
  const intro = '`band:toggle` applies in the `Chat` context. The other actions apply in `Band`.';
  assert.deepEqual(parsedContexts(['Chat', 'Band'], intro, ['band:toggle', 'band:next']), { 'band:toggle': ['Chat'], 'band:next': ['Band'] });
});

test('a semicolon clause is read on its own, so "the others" keep their context', () => {
  const intro =
    'Actions for the diff panel. `app:cycleDiffBase` is in the `DiffPanel` context, which is active while the panel is open; the others are `Global`.';
  assert.deepEqual(parsedContexts(['DiffPanel', 'Global'], intro, ['app:cycleDiffBase', 'app:diffFileListUp']), {
    'app:cycleDiffBase': ['DiffPanel'],
    'app:diffFileListUp': ['Global'],
  });
});

test('an action whose sentence says "also" keeps the general contexts too', () => {
  const intro = [
    'The scroll, resize, and close actions apply in the `Pane` [context](#contexts).',
    '`pane:close` also applies in the `PaneField` context, so it works while one of the pane\'s fields has focus.',
    '`pane:next` and `pane:previous` apply in the `Global` context while more than one pane is open.',
  ].join(' ');
  assert.deepEqual(parsedContexts(['Pane', 'PaneField', 'Global'], intro, ['pane:top', 'pane:close', 'pane:next']), {
    'pane:top': ['Pane'],
    'pane:close': ['Pane', 'PaneField'],
    'pane:next': ['Global'],
  });
});
