import { normalizeKey } from './parse-keybindings.js';

function catalogKey(action, contexts) {
  const context = contexts.find((name) => action.contextDefaults?.[name] !== undefined);
  return context ? action.contextDefaults[context] : action.defaultKey;
}

function checkContexts(catalog, docs, out) {
  const mine = new Set(catalog.contexts.map((context) => context.name));
  for (const name of mine) if (!docs.contexts.has(name)) out.error('keybindings', name, 'context is in the catalog but not in the docs Contexts table');
  for (const name of docs.contexts.keys()) if (!mine.has(name)) out.error('keybindings', name, 'docs list this context but the catalog does not');
}

function checkActionIds(catalog, docs, out) {
  const documented = new Set(docs.actions.map((row) => row.id));
  for (const action of catalog.actions) {
    if (action.legacy) {
      if (documented.has(action.id)) out.warn('keybindings', action.id, 'the catalog marks this action legacy but the docs list it in an action table');
      else if (!docs.mentions.has(action.id)) out.warn('keybindings', action.id, 'legacy action is no longer mentioned in the docs');
    } else if (!documented.has(action.id)) {
      out.error('keybindings', action.id, 'action is in the catalog but in no docs action table (removed or renamed)');
    }
  }
  const mine = new Set(catalog.actions.map((action) => action.id));
  for (const id of documented) if (!mine.has(id)) out.error('keybindings', id, 'docs list this action but the catalog does not');
}

function checkRows(catalog, docs, out) {
  const byId = new Map(catalog.actions.map((action) => [action.id, action]));
  for (const row of docs.actions) {
    const action = byId.get(row.id);
    if (!action) continue;
    const where = row.contexts.length > 0 ? row.contexts.join('/') : row.section;
    const mine = catalogKey(action, row.contexts);
    if (normalizeKey(mine) !== normalizeKey(row.key)) {
      out.warn('keybindings', row.id, `default key in ${where} is "${row.key}" in the docs but "${mine ?? '(unbound)'}" in the catalog`);
    }
    if (row.contexts.length > 0 && !row.contexts.some((name) => action.contexts.includes(name))) {
      out.warn('keybindings', row.id, `docs list it under ${where} but the catalog contexts are ${action.contexts.join(', ') || 'empty'}`);
    }
  }
}

export function checkKeybindings(catalog, docs, out) {
  checkContexts(catalog, docs, out);
  checkActionIds(catalog, docs, out);
  checkRows(catalog, docs, out);
}
