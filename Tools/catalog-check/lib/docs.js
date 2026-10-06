import { anchors, headings, toLines } from './markdown.js';
import { parseEnvVars } from './parse-env.js';
import { parseKeybindings } from './parse-keybindings.js';
import { LISTS } from './parse-lists.js';
import { parseSettingsReference } from './parse-settings.js';

function reportProblems(out, id, problems) {
  for (const problem of problems) out.error('pages', id, `cannot parse ${id}: ${problem}`);
}

/**
 * Parses every loaded page. A page that failed to load or parse becomes an ERROR finding,
 * and its parsed form stays null so the checks that need it are skipped rather than passed.
 */
export function parseDocs(pages, out) {
  const docs = { pages: new Map(), settings: null, env: null, keybindings: null, lists: {} };
  for (const [id, page] of pages) {
    if (page.error) {
      out.error('pages', id, `cannot load ${id}: ${page.error}`);
      continue;
    }
    docs.pages.set(id, { text: page.text, anchors: anchors(page.text, headings(toLines(page.text))) });
  }

  const settingsPage = docs.pages.get('settings-reference');
  if (settingsPage) {
    const parsed = parseSettingsReference(settingsPage.text);
    reportProblems(out, 'settings-reference', parsed.problems);
    if (parsed.index.size > 0 && parsed.sections.size > 0) docs.settings = parsed;
  }

  const envPage = docs.pages.get('env-vars');
  if (envPage) {
    const parsed = parseEnvVars(envPage.text);
    reportProblems(out, 'env-vars', parsed.problems);
    if (parsed.vars.size > 0) docs.env = parsed;
  }

  const keysPage = docs.pages.get('keybindings');
  if (keysPage) {
    const parsed = parseKeybindings(keysPage.text);
    reportProblems(out, 'keybindings', parsed.problems);
    if (parsed.contexts.size > 0 && parsed.actions.length > 0) docs.keybindings = parsed;
  }

  for (const [name, list] of Object.entries(LISTS)) {
    const page = docs.pages.get(list.page);
    if (!page) continue;
    const parsed = list.parse(page.text);
    if (parsed.problem) reportProblems(out, list.page, [parsed.problem]);
    else docs.lists[name] = parsed.values;
  }
  return docs;
}
