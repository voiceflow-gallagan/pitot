import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';

export const DOCS_PREFIX = 'https://code.claude.com/docs/';
const DOCS_BASE = `${DOCS_PREFIX}en/`;
export const BASE_PAGES = ['settings-reference', 'env-vars', 'keybindings', 'model-config', 'output-styles', 'sub-agents'];
export const USER_AGENT = 'pitot-catalog-check/0.1.0 (docs drift check for the Pitot catalog; Node.js)';
const TIMEOUT_MS = 30_000;
const PAUSE_MS = 500;

/** Page id such as `settings-reference` for a docs URL, or null when the URL is not an English docs page. */
export function pageIdFromUrl(url) {
  if (typeof url !== 'string' || !url.startsWith(DOCS_BASE)) return null;
  const id = url.slice(DOCS_BASE.length).split(/[#?]/)[0].replace(/\.md$/, '').replace(/\/$/, '');
  return /^[a-z0-9-]+(\/[a-z0-9-]+)*$/.test(id) ? id : null;
}

export function anchorFromUrl(url) {
  const hash = url.indexOf('#');
  return hash >= 0 ? url.slice(hash + 1) : null;
}

export function pageUrl(id) {
  return `${DOCS_BASE}${id}.md`;
}

export function pageFile(dir, id) {
  return path.join(dir, `${id.replaceAll('/', '__')}.md`);
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function looksLikeHtml(text) {
  return /^\s*<(!doctype|html)\b/i.test(text);
}

async function fetchOnce(id, fetchImpl) {
  const response = await fetchImpl(pageUrl(id), {
    headers: { 'User-Agent': USER_AGENT, Accept: 'text/markdown, text/plain;q=0.9' },
    redirect: 'follow',
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (!response.ok) return { error: `HTTP ${response.status}`, retry: response.status >= 500 };
  if (response.url && !response.url.startsWith(DOCS_PREFIX)) return { error: `redirected to ${response.url}` };
  const text = await response.text();
  if (looksLikeHtml(text)) return { error: 'the server returned HTML, not markdown' };
  return { text };
}

async function fetchPage(id, fetchImpl, pauseMs) {
  let result;
  try {
    result = await fetchOnce(id, fetchImpl);
  } catch (error) {
    result = { error: error.message, retry: true };
  }
  if (!result.retry) return result;
  await sleep(pauseMs * 4);
  try {
    return await fetchOnce(id, fetchImpl);
  } catch (error) {
    return { error: error.message };
  }
}

async function readPage(dir, id) {
  try {
    const text = await readFile(pageFile(dir, id), 'utf8');
    return looksLikeHtml(text) ? { error: 'the saved page is HTML, not markdown' } : { text };
  } catch (error) {
    return { error: error.code === 'ENOENT' ? `no saved page at ${pageFile(dir, id)}` : error.message };
  }
}

/**
 * Loads each page once, in order. Live fetches are sequential with a pause between them.
 * Returns a Map from page id to `{ text }` or `{ error }`.
 */
export async function loadPages(ids, { offline = null, save = null, fetchImpl = globalThis.fetch, pauseMs = PAUSE_MS } = {}) {
  const pages = new Map();
  for (const [index, id] of ids.entries()) {
    if (offline) {
      pages.set(id, await readPage(offline, id));
      continue;
    }
    if (index > 0) await sleep(pauseMs);
    const page = await fetchPage(id, fetchImpl, pauseMs);
    pages.set(id, page.error ? { error: page.error } : { text: page.text });
    if (save && page.text) {
      await mkdir(save, { recursive: true });
      await writeFile(pageFile(save, id), page.text);
    }
  }
  return pages;
}
