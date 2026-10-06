import { codeSpans, columnIndex, headings, sectionRange, tables, toLines } from './markdown.js';
import { REQUIRES } from './parse-settings.js';

function parseTable(lines, allHeadings, problems) {
  const heading = allHeadings.find((h) => h.slug === 'variables');
  if (!heading) {
    problems.push('the "Variables" heading is missing');
    return new Map();
  }
  const { start, end } = sectionRange(lines, allHeadings, heading);
  const table = tables(lines, start, end).find((t) => columnIndex(t, 'Variable') >= 0 && columnIndex(t, 'Purpose') >= 0);
  if (!table) {
    problems.push('the Variables section has no table with a Variable column');
    return new Map();
  }
  const nameCol = columnIndex(table, 'Variable');
  const purposeCol = columnIndex(table, 'Purpose');
  const vars = new Map();
  for (const row of table.rows) {
    const name = codeSpans(row.cells[nameCol] ?? '')[0];
    if (!name || !/^[A-Z][A-Z0-9_]*$/.test(name)) continue;
    const versions = [...(row.cells[purposeCol] ?? '').matchAll(REQUIRES)].map((m) => m[1]);
    vars.set(name, { minVersion: versions[0] ?? null, versions });
  }
  if (vars.size === 0) problems.push('the Variables table has no variable rows');
  else if ([...vars.values()].every((v) => v.versions.length === 0)) problems.push('no variable says "Requires Claude Code vX or later"');
  return vars;
}

export function parseEnvVars(text) {
  const lines = toLines(text);
  const problems = [];
  const vars = parseTable(lines, headings(lines), problems);
  return { vars, problems };
}
