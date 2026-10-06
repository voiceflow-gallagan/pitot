import { checkKeybindings } from './check-keybindings.js';
import { checkKeys, documentedKeys } from './check-keys.js';
import { checkTweaks } from './check-tweaks.js';
import { parseDocs } from './docs.js';
import { loadCatalog, loadKnown, pagesFor } from './inputs.js';
import { loadPages, pageUrl } from './pages.js';
import { collector, counts, SEVERITIES } from './report.js';

const AREA_ORDER = ['pages', 'tweaks', 'keybindings', 'keys'];

function sortFindings(findings) {
  const rank = (f) => [SEVERITIES.indexOf(f.severity), AREA_ORDER.indexOf(f.area)];
  return findings
    .map((finding, order) => ({ finding, order }))
    .sort((a, b) => {
      const [sa, aa] = rank(a.finding);
      const [sb, ab] = rank(b.finding);
      return sa - sb || aa - ab || a.order - b.order;
    })
    .map(({ finding }) => finding);
}

/**
 * Runs every check and returns the findings. Nothing here exits the process,
 * so tests call it directly with saved pages and a copied catalog.
 */
export async function runCheck({ catalogDir, knownFile, offline = null, save = null, fetchImpl, pauseMs }) {
  const catalog = await loadCatalog(catalogDir);
  const known = await loadKnown(knownFile);
  const ids = pagesFor(catalog);
  const pages = await loadPages(ids, { offline, save, fetchImpl, pauseMs });
  const out = collector();
  const docs = parseDocs(pages, out);
  checkTweaks(catalog.tweaks, docs, out);
  if (docs.keybindings) checkKeybindings(catalog.keybindings, docs.keybindings, out);
  const uncataloged = checkKeys(catalog, docs, known, out);
  const findings = sortFindings(out.findings);
  return {
    source: offline ? 'offline' : 'live',
    offline,
    pages: ids.map((id) => ({ id, url: pageUrl(id), ...(pages.get(id).error ? { error: pages.get(id).error } : {}) })),
    summary: {
      tweaks: catalog.tweaks.length,
      contexts: catalog.keybindings.contexts.length,
      actions: catalog.keybindings.actions.length,
      unverified: catalog.unverified?.keys?.length ?? 0,
    },
    findings,
    counts: counts(findings),
    uncataloged,
    documented: documentedKeys(docs),
  };
}
