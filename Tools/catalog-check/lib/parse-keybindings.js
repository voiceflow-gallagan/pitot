import { codeSpans, columnIndex, fencedMask, headings, pageCodeSpans, sectionRange, stripInline, tables, toLines } from './markdown.js';

function paragraphs(lines) {
  const mask = fencedMask(lines);
  return lines
    .map((line, index) => (mask[index] ? '' : line))
    .join('\n')
    .split(/\n\s*\n/)
    .map((p) => p.trim())
    .filter(Boolean);
}

/** Contexts named in the closest paragraph above the table that names any, within the same subsection. */
function tableContexts(lines, sectionStart, tableLine, known) {
  const prose = paragraphs(lines.slice(sectionStart, tableLine)).reverse();
  for (const paragraph of prose) {
    const named = [...new Set(codeSpans(paragraph).filter((span) => known.has(span)))];
    if (named.length > 0) return named;
  }
  return [];
}

function parseContexts(lines, allHeadings, problems) {
  const heading = allHeadings.find((h) => h.slug === 'contexts');
  if (!heading) {
    problems.push('the "Contexts" heading is missing');
    return new Map();
  }
  const { start, end } = sectionRange(lines, allHeadings, heading);
  const table = tables(lines, start, end).find((t) => columnIndex(t, 'Context') >= 0);
  const contexts = new Map();
  if (!table) {
    problems.push('the Contexts section has no table with a Context column');
    return contexts;
  }
  const nameCol = columnIndex(table, 'Context');
  const descriptionCol = columnIndex(table, 'Description');
  for (const row of table.rows) {
    const name = codeSpans(row.cells[nameCol] ?? '')[0];
    if (name) contexts.set(name, stripInline(row.cells[descriptionCol] ?? ''));
  }
  if (contexts.size === 0) problems.push('the Contexts table has no rows');
  return contexts;
}

function parseActions(lines, allHeadings, contexts, problems) {
  const heading = allHeadings.find((h) => h.slug === 'available-actions');
  if (!heading) {
    problems.push('the "Available actions" heading is missing');
    return [];
  }
  const known = new Set(contexts.keys());
  const { start, end } = sectionRange(lines, allHeadings, heading);
  const subsections = allHeadings.filter((h) => h.line > heading.line && h.line < end && h.level === heading.level + 1);
  const rows = [];
  for (const sub of subsections) {
    const range = sectionRange(lines, allHeadings, sub);
    for (const table of tables(lines, range.start, range.end)) {
      const actionCol = columnIndex(table, 'Action');
      const defaultCol = columnIndex(table, 'Default');
      if (actionCol < 0 || defaultCol < 0) continue;
      const tableCtx = tableContexts(lines, range.start, table.line, known);
      for (const row of table.rows) {
        const id = codeSpans(row.cells[actionCol] ?? '')[0];
        if (!id || !/^[\w-]+:[\w-]+$/.test(id)) continue;
        rows.push({ id, key: row.cells[defaultCol] ?? '', contexts: tableCtx, section: stripInline(sub.text), line: row.line + 1 });
      }
    }
  }
  if (rows.length === 0) problems.push('no action tables with Action and Default columns were found');
  return rows;
}

export function parseKeybindings(text) {
  const lines = toLines(text);
  const allHeadings = headings(lines);
  const problems = [];
  const contexts = parseContexts(lines, allHeadings, problems);
  const actions = parseActions(lines, allHeadings, contexts, problems);
  return { contexts, actions, mentions: new Set(pageCodeSpans(lines)), problems };
}

/** Comparable form of a docs or catalog default key: unescaped, footnote marks removed, lower case. */
export function normalizeKey(raw) {
  if (raw == null) return '(unbound)';
  const text = raw
    .replace(/\\\*(?=\s*(,|$))/g, '')
    .replace(/\\(.)/g, '$1')
    .replace(/`/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  return text === '' || /^\(unbound\)$/i.test(text) ? '(unbound)' : text.toLowerCase();
}
