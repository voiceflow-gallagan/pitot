const FENCE = /^\s*(```|~~~)/;
const HEADING = /^(#{1,6})\s+(.*?)\s*#*\s*$/;
const TABLE_SEPARATOR = /^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/;

export function toLines(text) {
  return text.replace(/\r\n?/g, '\n').split('\n');
}

/** Marks every line that sits inside a fenced code block, fence lines included. */
export function fencedMask(lines) {
  const mask = new Array(lines.length).fill(false);
  let open = null;
  lines.forEach((line, index) => {
    const fence = line.match(FENCE);
    if (open) {
      mask[index] = true;
      if (fence && fence[1] === open) open = null;
    } else if (fence) {
      mask[index] = true;
      open = fence[1];
    }
  });
  return mask;
}

function stripProse(md) {
  return md
    .replace(/<\/?[A-Za-z][\w-]*(\s[^>]*)?\/?>/g, '')
    .replace(/\*\*/g, '')
    .replace(/\\([\\`*_{}[\]()#+\-.!<>|])/g, '$1');
}

/** Plain text of inline markdown. Code span contents are kept verbatim. */
export function stripInline(md) {
  return md
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, '$1')
    .split(/(`[^`]*`)/)
    .map((part) => (part.startsWith('`') && part.endsWith('`') && part.length > 1 ? part.slice(1, -1) : stripProse(part)))
    .join('')
    .replace(/\s+/g, ' ')
    .trim();
}

export function slugify(headingText) {
  return stripInline(headingText)
    .toLowerCase()
    .replace(/[.\s/]+/g, '-')
    .replace(/[^a-z0-9_-]/g, '')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '');
}

export function headings(lines) {
  const mask = fencedMask(lines);
  const result = [];
  lines.forEach((line, index) => {
    if (mask[index]) return;
    const match = line.match(HEADING);
    if (match) result.push({ level: match[1].length, text: match[2], slug: slugify(match[2]), line: index });
  });
  return result;
}

/** The lines under a heading, up to the next heading of the same or a higher level. */
export function sectionRange(lines, allHeadings, heading) {
  const next = allHeadings.find((h) => h.line > heading.line && h.level <= heading.level);
  return { start: heading.line + 1, end: next ? next.line : lines.length };
}

export function anchors(text, allHeadings) {
  const ids = new Set(allHeadings.map((h) => h.slug));
  for (const match of text.matchAll(/\bid=["']([^"']+)["']/g)) ids.add(match[1]);
  return ids;
}

export function codeSpans(md) {
  return [...md.matchAll(/`([^`]+)`/g)].map((match) => match[1]);
}

/** Inline code spans of a whole page. Fenced blocks are skipped so their backticks do not pair with prose. */
export function pageCodeSpans(lines) {
  const mask = fencedMask(lines);
  return lines.flatMap((line, index) => (mask[index] ? [] : codeSpans(line)));
}

export function unquote(value) {
  return value.replace(/^"(.*)"$/, '$1');
}

export function splitRow(line) {
  const trimmed = line.trim().replace(/^\|/, '').replace(/\|$/, '');
  const cells = [];
  let current = '';
  let inCode = false;
  for (let i = 0; i < trimmed.length; i += 1) {
    const char = trimmed[i];
    if (char === '\\' && trimmed[i + 1] === '|') {
      current += '|';
      i += 1;
    } else if (char === '`') {
      inCode = !inCode;
      current += char;
    } else if (char === '|' && !inCode) {
      cells.push(current.trim());
      current = '';
    } else {
      current += char;
    }
  }
  cells.push(current.trim());
  return cells;
}

/**
 * Every pipe table between start and end. A table is a header row, a separator row,
 * and the rows that follow until the first line that does not start with a pipe.
 */
export function tables(lines, start = 0, end = lines.length) {
  const mask = fencedMask(lines);
  const result = [];
  for (let i = start; i < end - 1; i += 1) {
    if (mask[i] || !lines[i].trim().startsWith('|') || !TABLE_SEPARATOR.test(lines[i + 1].trim())) continue;
    const headers = splitRow(lines[i]).map(stripInline);
    const rows = [];
    let j = i + 2;
    while (j < end && lines[j].trim().startsWith('|')) {
      rows.push({ cells: splitRow(lines[j]), line: j });
      j += 1;
    }
    result.push({ headers, rows, line: i });
    i = j - 1;
  }
  return result;
}

export function columnIndex(table, name) {
  return table.headers.findIndex((header) => header.toLowerCase() === name.toLowerCase());
}

/** True when the page names `term` as code, in bold, as link text, or as a whole table cell. */
export function mentionsTerm(text, term) {
  const escaped = term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const patterns = [`\`"?${escaped}"?\``, `\\*\\*${escaped}\\*\\*`, `\\[${escaped}\\]\\(`, `\\|\\s*${escaped}\\s*\\|`];
  return patterns.some((pattern) => new RegExp(pattern).test(text));
}
