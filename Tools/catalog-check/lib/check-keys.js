import { rowKey } from './check-tweaks.js';

/** Every settings key and env var the parsed pages document, or null for a page that did not parse. */
export function documentedKeys(docs) {
  return {
    settings: docs.settings ? new Set([...docs.settings.index.keys(), ...docs.settings.sections.keys()]) : null,
    env: docs.env ? new Set(docs.env.vars.keys()) : null,
  };
}

function compareKind({ kind, page, documented, cataloged, unverified, known }, out) {
  const label = kind === 'setting' ? 'setting' : 'env var';
  for (const name of unverified) {
    if (documented.has(name)) out.info('keys', name, `unverified ${label} is now documented on ${page}: promote it to tweaks.json or drop it from unverified.json`);
  }
  const uncataloged = [...documented].filter((name) => !cataloged.has(name) && !unverified.has(name)).sort();
  if (known) {
    for (const name of uncataloged) if (!known.has(name)) out.info('keys', name, `new ${label} on ${page} since the last baseline: candidate to add`);
    for (const name of [...known].sort()) if (!documented.has(name)) out.info('keys', name, `${label} was in the last baseline and is gone from ${page}: deprecated or removed`);
  }
  return uncataloged;
}

export function checkKeys(catalog, docs, known, out) {
  const documented = documentedKeys(docs);
  const unverified = catalog.unverified?.keys ?? [];
  const pick = (kind, list) => new Set(list.filter((item) => item.kind === kind).map((item) => item.name));
  const cataloged = (type) => new Set(catalog.tweaks.filter((row) => row.location.type === type).map(rowKey));
  const uncataloged = { settings: [], env: [] };
  if (!known) out.info('keys', 'known-keys.json', 'no baseline, so new and removed keys are not reported; run with --update-known to create it');
  if (documented.settings) {
    uncataloged.settings = compareKind(
      { kind: 'setting', page: 'settings-reference', documented: documented.settings, cataloged: cataloged('setting'), unverified: pick('setting', unverified), known: known?.settings },
      out,
    );
  }
  if (documented.env) {
    uncataloged.env = compareKind(
      { kind: 'env', page: 'env-vars', documented: documented.env, cataloged: cataloged('env'), unverified: pick('env', unverified), known: known?.env },
      out,
    );
  }
  out.info('keys', 'coverage', `${uncataloged.settings.length} documented settings and ${uncataloged.env.length} env vars are in neither tweaks.json nor unverified.json (listed under "uncataloged" in --json)`);
  return uncataloged;
}
