import { codeSpans, columnIndex, headings, sectionRange, stripInline, tables, toLines } from './markdown.js';

function sectionOf(text, slug) {
  const lines = toLines(text);
  const allHeadings = headings(lines);
  const heading = allHeadings.find((h) => h.slug === slug);
  if (!heading) return null;
  const { start, end } = sectionRange(lines, allHeadings, heading);
  return { lines, start, end };
}

function firstTable(section, column) {
  if (!section) return null;
  return tables(section.lines, section.start, section.end).find((t) => columnIndex(t, column) >= 0) ?? null;
}

function modelAliases(text) {
  const table = firstTable(sectionOf(text, 'model-aliases'), 'Model alias');
  if (!table) return { problem: 'the "Model aliases" table is missing' };
  const col = columnIndex(table, 'Model alias');
  const values = table.rows
    .filter((row) => !/not itself a model alias/i.test(row.cells.join(' ')))
    .map((row) => codeSpans(row.cells[col] ?? '')[0])
    .filter(Boolean);
  return values.length > 0 ? { values } : { problem: 'the "Model aliases" table has no aliases' };
}

function builtInStyles(text) {
  const table = firstTable(sectionOf(text, 'built-in-output-styles'), 'Style');
  if (!table) return { problem: 'the "Built-in output styles" table is missing' };
  const col = columnIndex(table, 'Style');
  const values = table.rows.map((row) => stripInline(row.cells[col] ?? '')).filter(Boolean);
  return values.length > 0 ? { values } : { problem: 'the "Built-in output styles" table has no styles' };
}

function subagentAliases(text) {
  const section = sectionOf(text, 'choose-a-model');
  if (!section) return { problem: 'the "Choose a model" section is missing' };
  const line = section.lines.slice(section.start, section.end).find((l) => /\*\*Model alias\*\*/.test(l));
  const values = line ? codeSpans(line) : [];
  return values.length > 0 ? { values } : { problem: 'the "Model alias" line in "Choose a model" names no aliases' };
}

/** Documented value lists that catalog suggestions are checked against, keyed by list name. */
export const LISTS = {
  modelAliases: { page: 'model-config', label: 'model aliases', parse: modelAliases },
  subagentAliases: { page: 'sub-agents', label: 'subagent model aliases', parse: subagentAliases },
  builtInStyles: { page: 'output-styles', label: 'built-in output styles', parse: builtInStyles },
};

/** Which documented list each tweak's `suggestions` come from. */
export const SUGGESTION_SOURCES = {
  model: 'modelAliases',
  CLAUDE_CODE_SUBAGENT_MODEL: 'subagentAliases',
  outputStyle: 'builtInStyles',
};
