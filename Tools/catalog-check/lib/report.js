export const SEVERITIES = ['ERROR', 'WARN', 'INFO'];

export function collector() {
  const findings = [];
  const add = (severity) => (area, subject, message) => findings.push({ severity, area, subject, message });
  return { findings, error: add('ERROR'), warn: add('WARN'), info: add('INFO') };
}

export function counts(findings) {
  return Object.fromEntries(SEVERITIES.map((s) => [s.toLowerCase(), findings.filter((f) => f.severity === s).length]));
}

const HEADINGS = {
  ERROR: 'ERROR: a catalog row is wrong now',
  WARN: 'WARN: a default, description or link may differ',
  INFO: 'INFO: new, promoted or removed keys',
};

export function formatText(result) {
  const { findings, summary, source, pages } = result;
  const total = counts(findings);
  const lines = [
    `Catalog drift check against ${source === 'live' ? 'the live docs' : `saved pages in ${result.offline}`}`,
    `Pages: ${pages.map((p) => (p.error ? `${p.id} (failed)` : p.id)).join(', ')}`,
    `Catalog: ${summary.tweaks} tweaks, ${summary.contexts} keybinding contexts, ${summary.actions} keybinding actions, ${summary.unverified} unverified keys`,
  ];
  for (const severity of SEVERITIES) {
    const group = findings.filter((f) => f.severity === severity);
    if (group.length === 0) continue;
    lines.push('', `${HEADINGS[severity]} (${group.length})`);
    for (const f of group) lines.push(`  [${f.area}] ${f.subject}: ${f.message}`);
  }
  const verdict = total.error > 0 ? 'FAIL' : 'PASS';
  lines.push('', `Result: ${verdict}. ${total.error} errors, ${total.warn} warnings, ${total.info} notes.`);
  return lines.join('\n');
}

export function formatJson(result) {
  const total = counts(result.findings);
  return JSON.stringify(
    {
      ok: total.error === 0,
      source: result.source,
      counts: total,
      pages: result.pages,
      summary: result.summary,
      findings: result.findings,
      uncataloged: result.uncataloged,
    },
    null,
    2,
  );
}
