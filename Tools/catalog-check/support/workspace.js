import { cp, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { saveKnown } from '../lib/inputs.js';
import { runCheck } from '../lib/run.js';

const here = path.dirname(fileURLToPath(import.meta.url));
export const TOOL_DIR = path.resolve(here, '..');
export const FIXTURE_PAGES = path.join(TOOL_DIR, 'fixtures', 'pages');
export const FIXTURE_CATALOG = path.join(TOOL_DIR, 'fixtures', 'catalog');

/** A temp workspace with copies of the synthetic catalog and pages, removed after the test. */
export async function workspace(t) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'catalog-check-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const catalog = path.join(root, 'catalog');
  const pages = path.join(root, 'pages');
  await cp(FIXTURE_CATALOG, catalog, { recursive: true });
  await cp(FIXTURE_PAGES, pages, { recursive: true });
  const known = path.join(root, 'known-keys.json');
  const baseline = await runCheck({ catalogDir: catalog, knownFile: known, offline: pages });
  await saveKnown(known, baseline.documented, '2026-10-06');
  return {
    root,
    catalog,
    pages,
    known,
    run: () => runCheck({ catalogDir: catalog, knownFile: known, offline: pages }),
    async editJson(file, edit) {
      const target = path.join(catalog, file);
      const data = JSON.parse(await readFile(target, 'utf8'));
      edit(data);
      await writeFile(target, JSON.stringify(data, null, 2));
    },
    async editPage(id, edit) {
      const target = path.join(pages, `${id}.md`);
      await writeFile(target, edit(await readFile(target, 'utf8')));
    },
  };
}

export function replaceOnce(text, search, replacement) {
  const index = text.indexOf(search);
  if (index < 0) throw new Error(`fixture text not found: ${search}`);
  return text.slice(0, index) + replacement + text.slice(index + search.length);
}

export const tweak = (data, id) => data.tweaks.find((row) => row.id === id);

export const matching = (result, severity, subject, pattern) =>
  result.findings.filter((f) => f.severity === severity && f.subject === subject && pattern.test(f.message));
