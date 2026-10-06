import { mentionsTerm } from './markdown.js';
import { anchorFromUrl, DOCS_PREFIX, pageIdFromUrl } from './pages.js';
import { LISTS, SUGGESTION_SOURCES } from './parse-lists.js';
import { matchesEnvName } from './parse-settings.js';

const USER_ONLY_SCOPES = new Set(['User or managed', 'User, local, or managed']);
const KEY_PAGES = new Set(['settings-reference', 'env-vars']);

export function rowKey(row) {
  return row.location.type === 'env' ? row.location.name : row.location.path.join('.');
}

const escapeRegExp = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

function checkLink(row, docs, out) {
  const url = row.docURL;
  if (typeof url !== 'string' || !url.startsWith(DOCS_PREFIX)) {
    out.error('tweaks', row.id, `docURL "${url}" is not a ${DOCS_PREFIX} link`);
    return;
  }
  const id = pageIdFromUrl(url);
  if (!id) {
    out.warn('tweaks', row.id, `docURL ${url} is not an English docs page, so it was not checked`);
    return;
  }
  const page = docs.pages.get(id);
  if (!page) return;
  const anchor = anchorFromUrl(url);
  if (anchor && !page.anchors.has(anchor)) out.warn('tweaks', row.id, `docURL anchor #${anchor} is not on ${id}`);
  const key = rowKey(row);
  if (!KEY_PAGES.has(id) && !mentionsTerm(page.text, key)) out.warn('tweaks', row.id, `docURL page ${id} no longer names ${key}`);
}

function checkScope(row, scope, out) {
  const userOnly = row.scope === 'userOnly';
  if (scope === 'Managed') {
    out.error('tweaks', row.id, 'docs scope is "Managed": only managed settings can set this key');
  } else if (scope === 'Global config') {
    out.error('tweaks', row.id, 'docs scope is "Global config": the key lives in ~/.claude.json, not in settings.json');
  } else if (USER_ONLY_SCOPES.has(scope)) {
    if (!userOnly) out.error('tweaks', row.id, `docs scope is "${scope}" but the row is not scope userOnly`);
  } else if (scope === 'Any file') {
    if (userOnly) out.error('tweaks', row.id, 'docs scope is "Any file" but the row is scope userOnly');
  } else {
    out.error('tweaks', row.id, `docs scope "${scope}" is not one this check knows, so the row scope cannot be verified`);
  }
}

function checkUserOnlyValues(row, section, out) {
  for (const value of row.userOnlyValues ?? []) {
    if (!new RegExp(`\\b${escapeRegExp(value)}\\b`).test(section.scopeText ?? '')) {
      out.warn('tweaks', row.id, `userOnlyValues lists "${value}" but the docs Scope line does not name it`);
    }
  }
}

function checkType(row, type, out) {
  const kind = row.valueType.type;
  if (type.kind === 'missing') {
    out.error('tweaks', row.id, 'cannot parse settings-reference: the entry has no Type line');
    return;
  }
  if (kind === 'bool' && type.kind !== 'bool') out.error('tweaks', row.id, `the row is bool but the docs type is "${type.text}"`);
  if (kind !== 'bool' && type.kind === 'bool') out.error('tweaks', row.id, `the row is ${kind} but the docs type is Boolean`);
  if (kind === 'fixedString' && !type.text.includes(`"${row.valueType.value}"`)) {
    out.error('tweaks', row.id, `fixed value "${row.valueType.value}" is not in the docs type "${type.text}"`);
  }
  if (kind !== 'enum') return;
  if (type.kind !== 'enum') {
    out.error('tweaks', row.id, `the row is an enum but the docs list no values: "${type.text}"`);
    return;
  }
  const mine = row.valueType.options.map((option) => option.value);
  const accepted = new Set([...type.values, ...type.aliases]);
  for (const value of mine) if (!accepted.has(value)) out.error('tweaks', row.id, `enum value "${value}" is not documented`);
  for (const value of type.values) if (!mine.includes(value)) out.warn('tweaks', row.id, `documented value "${value}" is not in the catalog`);
  const extras = [...type.aliases.filter((v) => !mine.includes(v)), ...type.patterns];
  if (extras.length > 0) out.info('tweaks', row.id, `docs also accept ${extras.map((v) => `"${v}"`).join(', ')} (aliases and patterns, not compared)`);
}

function checkVersion(row, documented, mentioned, page, out) {
  const mine = row.minVersion ?? null;
  if (mine === documented) return;
  if (mine && documented) {
    out.error('tweaks', row.id, `minVersion is ${mine} but ${page} says "Requires Claude Code v${documented}"`);
  } else if (documented) {
    out.error('tweaks', row.id, `${page} says "Requires Claude Code v${documented}" but the row has no minVersion`);
  } else if (mentioned.includes(mine)) {
    out.warn('tweaks', row.id, `minVersion ${mine} appears on ${page} only for a detail of the key, not for the key itself`);
  } else {
    out.error('tweaks', row.id, `minVersion is ${mine} but ${page} states no version for this key`);
  }
}

function checkDefault(row, documented, out) {
  const text = row.defaultDescription ?? '';
  if (documented.kind === 'missing') {
    out.warn('tweaks', row.id, 'the settings-reference entry has no Default line');
  } else if (documented.kind === 'unset') {
    if (!/^unset\b/i.test(text)) out.warn('tweaks', row.id, `docs default is "${documented.text}" but defaultDescription is "${text}"`);
    if (row.defaultValue != null) out.warn('tweaks', row.id, `docs default is unset but defaultValue is ${JSON.stringify(row.defaultValue)}`);
  } else if (documented.kind === 'literal') {
    if (!new RegExp(`^${escapeRegExp(documented.value)}(:|\\s|$)`).test(text)) {
      out.warn('tweaks', row.id, `docs default is "${documented.value}" but defaultDescription is "${text}"`);
    }
    if (row.defaultValue != null && String(row.defaultValue) !== documented.value) {
      out.warn('tweaks', row.id, `docs default is "${documented.value}" but defaultValue is ${JSON.stringify(row.defaultValue)}`);
    }
  }
}

function checkSetting(row, docs, out) {
  const key = rowKey(row);
  const entry = docs.settings.index.get(key);
  const section = docs.settings.sections.get(key);
  if (!entry && !section) {
    out.error('tweaks', row.id, `setting ${key} is not on settings-reference (removed or renamed)`);
    return;
  }
  if (!entry) out.warn('tweaks', row.id, `setting ${key} has an entry on settings-reference but is missing from the settings index`);
  const scope = entry?.scope || section?.scopeLabel;
  if (scope) checkScope(row, scope, out);
  else out.error('tweaks', row.id, `cannot parse settings-reference: no scope found for ${key}`);
  const anchor = anchorFromUrl(row.docURL ?? '');
  const linksHere = pageIdFromUrl(row.docURL) === 'settings-reference';
  const brokenAnchor = anchor && !docs.pages.get('settings-reference').anchors.has(anchor);
  if (entry?.anchor && linksHere && anchor !== entry.anchor && !brokenAnchor) {
    out.warn('tweaks', row.id, `docURL points to #${anchor ?? '(none)'} but the settings index links ${key} to #${entry.anchor}`);
  }
  if (!section) {
    out.error('tweaks', row.id, `cannot parse settings-reference: ${key} is in the index but has no entry, so type, default and version are unchecked`);
    return;
  }
  checkUserOnlyValues(row, section, out);
  checkType(row, section.type, out);
  checkVersion(row, section.minVersion, section.versions, 'settings-reference', out);
  checkDefault(row, section.default, out);
}

function checkEnv(row, docs, out) {
  const name = rowKey(row);
  const documented = docs.env.vars.get(name);
  if (!documented) {
    out.error('tweaks', row.id, `env var ${name} is not on env-vars (removed or renamed)`);
    return;
  }
  checkVersion(row, documented.minVersion, documented.versions, 'env-vars', out);
  const ignored = docs.settings?.ignoredEnv;
  if (!ignored) return;
  const userOnly = row.scope === 'userOnly';
  if (matchesEnvName(ignored.everyFile, name)) {
    out.error('tweaks', row.id, `settings-reference says Claude Code ignores ${name} in every settings file`);
  } else if (matchesEnvName(ignored.projectLocal, name)) {
    if (!userOnly) out.error('tweaks', row.id, `settings-reference says project and local settings cannot set ${name}, but the row is not scope userOnly`);
  } else if (userOnly) {
    out.warn('tweaks', row.id, `the row is scope userOnly but the settings-reference list of variables ignored in project and local settings does not name ${name}`);
  }
}

function checkSuggestions(row, docs, out) {
  if (!Array.isArray(row.suggestions) || row.suggestions.length === 0) return;
  const listName = SUGGESTION_SOURCES[row.id];
  if (!listName) {
    out.info('tweaks', row.id, 'suggestions are not checked: no documented list is configured for this row in lib/parse-lists.js');
    return;
  }
  const values = docs.lists[listName];
  if (!values) return;
  const { page: pageId, label } = LISTS[listName];
  const pageText = docs.pages.get(pageId).text;
  const mine = row.suggestions.map((suggestion) => suggestion.value);
  for (const value of mine) {
    if (!values.includes(value) && !mentionsTerm(pageText, value)) out.error('tweaks', row.id, `suggestion "${value}" is not documented on ${pageId}`);
  }
  const unoffered = values.filter((value) => !mine.includes(value));
  if (unoffered.length > 0) out.info('tweaks', row.id, `${pageId} documents ${label} that are not suggestions: ${unoffered.join(', ')}`);
}

export function checkTweaks(tweaks, docs, out) {
  for (const row of tweaks) {
    checkLink(row, docs, out);
    if (row.location.type === 'setting' && docs.settings) checkSetting(row, docs, out);
    if (row.location.type === 'env' && docs.env) checkEnv(row, docs, out);
    checkSuggestions(row, docs, out);
  }
}
