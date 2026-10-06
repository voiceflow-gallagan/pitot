import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

const TOOL_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FIXTURES_DIR = path.join(TOOL_DIR, 'fixtures');
export const DEFAULT_SAVE_DIR = path.join(TOOL_DIR, '.cache');

export const USAGE = `Usage: node check.js [options]

Compares Catalog/tweaks.json, keybindings.json and unverified.json with the Claude Code docs.
Exit code: 0 when there is no ERROR, 1 when there is at least one, 2 on a usage or input error.

  --json             print machine-readable output
  --offline <dir>    read saved pages from <dir> instead of fetching them
  --save [dir]       save the fetched pages to [dir] (default: ./.cache, ignored by git)
  --catalog <dir>    catalog directory (default: ../../Catalog)
  --known <file>     baseline of documented keys (default: ./known-keys.json)
  --update-known     rewrite the baseline from the pages after a clean parse
  --help             show this text`;

/** `--save` may come without a folder, so a bare `--save` gets the cache folder before parseArgs sees it. */
function withSaveDefault(argv) {
  return argv.map((arg, index) => {
    const next = argv[index + 1];
    return arg === '--save' && (next === undefined || next.startsWith('--')) ? `--save=${DEFAULT_SAVE_DIR}` : arg;
  });
}

function isInside(dir, parent) {
  const relative = path.relative(parent, path.resolve(dir));
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
}

export function parseOptions(argv) {
  const { values } = parseArgs({
    args: withSaveDefault(argv),
    options: {
      json: { type: 'boolean', default: false },
      offline: { type: 'string' },
      save: { type: 'string' },
      catalog: { type: 'string', default: path.resolve(TOOL_DIR, '..', '..', 'Catalog') },
      known: { type: 'string', default: path.join(TOOL_DIR, 'known-keys.json') },
      'update-known': { type: 'boolean', default: false },
      help: { type: 'boolean', default: false },
    },
  });
  if (values.offline && values.save) throw new Error('--save needs live pages, so it cannot be combined with --offline');
  if (values.save && isInside(values.save, FIXTURES_DIR)) {
    throw new Error('--save cannot write into fixtures/: the test pages there are synthetic and the docs pages must not be committed');
  }
  return values;
}
