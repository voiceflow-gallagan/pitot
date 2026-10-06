import { codeSpans, columnIndex, headings, sectionRange, stripInline, tables, toLines, unquote } from './markdown.js';

const KEY_HEADING = /^`([A-Za-z][\w.]*)`$/;
const FIELD_BULLET = /^\* \*\*([^*]+)\*\*:\s*(.*)$/;
const SUB_BULLET = /^\s{2,}\* (.*)$/;
export const REQUIRES = /Requires Claude Code v(\d+(?:\.\d+)+)/g;
const ENV_NAME = /^[A-Z][A-Z0-9_]*\*?$/;

function firstVersion(text) {
  const match = [...text.matchAll(REQUIRES)][0];
  return match ? match[1] : null;
}

function fieldBullets(lines, start, end) {
  const fields = new Map();
  for (let i = start; i < end; i += 1) {
    const match = lines[i].match(FIELD_BULLET);
    if (!match) continue;
    const items = [];
    let j = i + 1;
    while (j < end && SUB_BULLET.test(lines[j])) {
      items.push(lines[j].match(SUB_BULLET)[1]);
      j += 1;
    }
    if (!fields.has(match[1])) fields.set(match[1], { text: match[2], items, line: i });
  }
  return fields;
}

/** Values named before the first colon of a sub-bullet, such as `"auto"` in "`"auto"`: matches ...". */
function itemValues(item) {
  const label = item.split(/`:\s/)[0];
  return codeSpans(label.endsWith('`') ? label : `${label}\``).map(unquote);
}

export function parseType(type) {
  if (!type) return { kind: 'missing', values: [], patterns: [], aliases: [] };
  const text = stripInline(type.text);
  const values = [];
  const patterns = [];
  const aliases = [];
  const add = (value, item) => {
    if (value.includes('<')) patterns.push(value);
    else if (item && /\balias for\b/i.test(item)) aliases.push(value);
    else values.push(value);
  };
  if (/\bone of\b/i.test(type.text)) {
    if (type.items.length > 0) {
      for (const item of type.items) for (const value of itemValues(item)) add(value, item);
    } else {
      for (const span of codeSpans(type.text)) if (span.startsWith('"')) add(unquote(span));
    }
  }
  const unique = (list) => [...new Set(list)];
  let kind = 'other';
  if (/^boolean\b/i.test(text)) kind = 'bool';
  else if (values.length > 0) kind = 'enum';
  else if (/^the string\b/i.test(text)) kind = 'fixedString';
  return { kind, text, values: unique(values), patterns: unique(patterns), aliases: unique(aliases) };
}

export function parseDefault(field) {
  if (!field) return { kind: 'missing', text: '' };
  const text = stripInline(field.text);
  if (/^unset\b/i.test(text)) return { kind: 'unset', text };
  const literal = field.text.match(/^`([^`]+)`/);
  if (literal) return { kind: 'literal', value: unquote(literal[1]), text };
  return { kind: 'text', text };
}

function parseIndex(lines, allHeadings, problems) {
  const heading = allHeadings.find((h) => /settings index/i.test(h.text));
  if (!heading) {
    problems.push('the "Settings index" heading is missing');
    return new Map();
  }
  const { start, end } = sectionRange(lines, allHeadings, heading);
  const indexTables = tables(lines, start, end).filter((t) => columnIndex(t, 'Key') >= 0 && columnIndex(t, 'Scope') >= 0);
  if (indexTables.length === 0) {
    problems.push('the settings index has no table with Key and Scope columns');
    return new Map();
  }
  const index = new Map();
  for (const table of indexTables) {
    const keyCol = columnIndex(table, 'Key');
    const scopeCol = columnIndex(table, 'Scope');
    for (const row of table.rows) {
      const cell = row.cells[keyCol] ?? '';
      const key = codeSpans(cell)[0];
      if (!key) continue;
      index.set(key, { anchor: cell.match(/\(#([^)]+)\)/)?.[1] ?? null, scope: stripInline(row.cells[scopeCol] ?? '') });
    }
  }
  if (index.size === 0) problems.push('the settings index table has no key rows');
  return index;
}

function parseSections(lines, allHeadings) {
  const sections = new Map();
  for (const heading of allHeadings) {
    const match = heading.text.match(KEY_HEADING);
    if (!match || heading.level > 4) continue;
    const { start, end } = sectionRange(lines, allHeadings, heading);
    const fields = fieldBullets(lines, start, end);
    const scope = fields.get('Scope');
    const intro = lines.slice(start, scope?.line ?? end).join('\n');
    const body = lines.slice(start, end).join('\n');
    sections.set(match[1], {
      scopeLabel: scope ? (codeSpans(scope.text)[0] ?? null) : null,
      scopeText: scope ? stripInline(scope.text) : null,
      type: parseType(fields.get('Type')),
      default: parseDefault(fields.get('Default')),
      minVersion: firstVersion(intro),
      versions: [...new Set([...body.matchAll(REQUIRES)].map((m) => m[1]))],
    });
  }
  return sections;
}

/** Problems that mean the entry format changed, so most per-key checks would pass by accident. */
function sanityProblems(sections) {
  const all = [...sections.values()];
  const share = (predicate) => all.filter(predicate).length / Math.max(all.length, 1);
  const problems = [];
  if (share((s) => s.type.kind === 'missing') > 0.5) problems.push('most key entries have no "* **Type**:" line');
  if (share((s) => s.default.kind === 'missing') > 0.5) problems.push('most key entries have no "* **Default**:" line');
  if (share((s) => s.scopeLabel === null) > 0.5) problems.push('most key entries have no "* **Scope**:" line');
  if (all.length > 0 && all.every((s) => s.versions.length === 0)) problems.push('no entry says "Requires Claude Code vX or later"');
  return problems;
}

function envNames(text) {
  return codeSpans(text).filter((span) => ENV_NAME.test(span));
}

/** Env vars the "Variables Claude Code ignores in env" list names, split by where they are ignored. */
function parseIgnoredEnv(lines, allHeadings, problems) {
  const heading = allHeadings.find((h) => /variables claude code ignores in/i.test(stripInline(h.text)));
  if (!heading) {
    problems.push('the "Variables Claude Code ignores in env" section is missing');
    return null;
  }
  const { start, end } = sectionRange(lines, allHeadings, heading);
  const bullets = [];
  for (let i = start; i < end; i += 1) {
    if (lines[i].startsWith('* ')) bullets.push([lines[i]]);
    else if (bullets.length > 0 && (lines[i].startsWith(' ') || lines[i] === '')) bullets.at(-1).push(lines[i]);
  }
  const projectLocal = [];
  const everyFile = [];
  for (const bullet of bullets) {
    const text = bullet.join('\n');
    (/ignored from every file/i.test(text) ? everyFile : projectLocal).push(...envNames(text));
  }
  if (projectLocal.length === 0) problems.push('the "Variables Claude Code ignores in env" list names no variables');
  return { projectLocal, everyFile };
}

export function parseSettingsReference(text) {
  const lines = toLines(text);
  const allHeadings = headings(lines);
  const problems = [];
  const index = parseIndex(lines, allHeadings, problems);
  const sections = parseSections(lines, allHeadings);
  if (sections.size === 0) problems.push('no key sections such as "### `model`" were found');
  problems.push(...sanityProblems(sections));
  const ignoredEnv = parseIgnoredEnv(lines, allHeadings, problems);
  return { index, sections, ignoredEnv, problems };
}

export function matchesEnvName(names, name) {
  return names.some((entry) => (entry.endsWith('*') ? name.startsWith(entry.slice(0, -1)) : entry === name));
}
