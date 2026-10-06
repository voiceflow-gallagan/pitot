import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { loadPages, pageIdFromUrl, USER_AGENT } from '../lib/pages.js';

function fakeFetch(responses) {
  const calls = [];
  let active = 0;
  const impl = async (url, init) => {
    active += 1;
    assert.equal(active, 1, 'fetches must be sequential');
    calls.push({ url, init });
    await new Promise((resolve) => setTimeout(resolve, 5));
    active -= 1;
    const { status = 200, body = '' } = responses[url] ?? { status: 404 };
    return { ok: status >= 200 && status < 300, status, url, text: async () => body };
  };
  return { impl, calls };
}

test('pages are fetched one at a time with a named User-Agent and no cookies', async () => {
  const base = 'https://code.claude.com/docs/en/';
  const { impl, calls } = fakeFetch({
    [`${base}a.md`]: { body: '# A' },
    [`${base}b.md`]: { body: '<!DOCTYPE html><html></html>' },
  });
  const pages = await loadPages(['a', 'b', 'c'], { fetchImpl: impl, pauseMs: 1 });
  assert.deepEqual(pages.get('a'), { text: '# A' });
  assert.match(pages.get('b').error, /HTML, not markdown/);
  assert.equal(pages.get('c').error, 'HTTP 404');
  assert.deepEqual(
    calls.map((call) => call.url),
    [`${base}a.md`, `${base}b.md`, `${base}c.md`],
  );
  for (const { init } of calls) {
    assert.equal(init.headers['User-Agent'], USER_AGENT);
    assert.equal(Object.keys(init.headers).some((name) => name.toLowerCase() === 'cookie'), false);
    assert.equal(init.credentials, undefined);
  }
});

test('--save writes each fetched page', async (t) => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'catalog-check-save-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const { impl } = fakeFetch({ 'https://code.claude.com/docs/en/plugins/overview.md': { body: '# Plugins' } });
  await loadPages(['plugins/overview'], { fetchImpl: impl, save: dir, pauseMs: 1 });
  assert.equal(await readFile(path.join(dir, 'plugins__overview.md'), 'utf8'), '# Plugins');
});

test('page ids come only from English docs URLs', () => {
  assert.equal(pageIdFromUrl('https://code.claude.com/docs/en/settings-reference#tui'), 'settings-reference');
  assert.equal(pageIdFromUrl('https://code.claude.com/docs/en/env-vars.md'), 'env-vars');
  assert.equal(pageIdFromUrl('https://code.claude.com/docs/en/plugins/mods/admin'), 'plugins/mods/admin');
  assert.equal(pageIdFromUrl('https://www.schemastore.org/claude-code-settings.json'), null);
  assert.equal(pageIdFromUrl('https://code.claude.com/docs/ja/settings'), null);
});
