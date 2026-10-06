import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { BASE_PAGES, pageIdFromUrl } from './pages.js';

async function readJson(file, { optional = false } = {}) {
  let text;
  try {
    text = await readFile(file, 'utf8');
  } catch (error) {
    if (optional && error.code === 'ENOENT') return null;
    throw new Error(`cannot read ${file}: ${error.message}`);
  }
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new Error(`${file} is not valid JSON: ${error.message}`);
  }
}

export async function loadCatalog(dir) {
  const tweaksFile = await readJson(path.join(dir, 'tweaks.json'));
  const keybindings = await readJson(path.join(dir, 'keybindings.json'));
  const unverified = await readJson(path.join(dir, 'unverified.json'), { optional: true });
  if (!Array.isArray(tweaksFile?.tweaks)) throw new Error(`${path.join(dir, 'tweaks.json')} has no tweaks array`);
  if (!Array.isArray(keybindings?.actions) || !Array.isArray(keybindings?.contexts)) {
    throw new Error(`${path.join(dir, 'keybindings.json')} needs contexts and actions arrays`);
  }
  return { tweaks: tweaksFile.tweaks, keybindings, unverified };
}

/** Docs pages the run needs: the base list plus every page the catalog links to. */
export function pagesFor(catalog) {
  const urls = [
    ...catalog.tweaks.map((row) => row.docURL),
    catalog.keybindings.docURL,
    catalog.keybindings.header?.docs,
    ...(catalog.unverified?.docsChecked ?? []),
  ];
  const ids = new Set(BASE_PAGES);
  for (const url of urls) {
    const id = pageIdFromUrl(url);
    if (id) ids.add(id);
  }
  return [...ids];
}

export async function loadKnown(file) {
  const known = await readJson(file, { optional: true });
  if (known === null) return null;
  if (!Array.isArray(known.settings) || !Array.isArray(known.env)) throw new Error(`${file} needs settings and env arrays`);
  return { settings: new Set(known.settings), env: new Set(known.env), updated: known.updated ?? null };
}

export async function saveKnown(file, { settings, env }, date) {
  const body = { updated: date, settings: [...settings].sort(), env: [...env].sort() };
  await writeFile(file, `${JSON.stringify(body, null, 2)}\n`);
}
