#!/usr/bin/env node
import { saveKnown } from './lib/inputs.js';
import { parseOptions, USAGE } from './lib/options.js';
import { formatJson, formatText } from './lib/report.js';
import { runCheck } from './lib/run.js';

async function main() {
  let opts;
  try {
    opts = parseOptions(process.argv.slice(2));
  } catch (error) {
    console.error(`${error.message}\n\n${USAGE}`);
    return 2;
  }
  if (opts.help) {
    console.log(USAGE);
    return 0;
  }
  const result = await runCheck({ catalogDir: opts.catalog, knownFile: opts.known, offline: opts.offline ?? null, save: opts.save ?? null });
  console.log(opts.json ? formatJson(result) : formatText(result));
  if (opts['update-known']) {
    const { settings, env } = result.documented;
    const pageErrors = result.findings.some((f) => f.area === 'pages' && f.severity === 'ERROR');
    if (!settings || !env || pageErrors) {
      console.error('Baseline not written: a page failed to load or parse.');
      return 1;
    }
    await saveKnown(opts.known, { settings, env }, new Date().toISOString().slice(0, 10));
    console.error(`Baseline written to ${opts.known}: ${settings.size} settings, ${env.size} env vars.`);
  }
  return result.counts.error > 0 ? 1 : 0;
}

main().then(
  (code) => {
    process.exitCode = code;
  },
  (error) => {
    console.error(`catalog-check: ${error.message}`);
    process.exitCode = 2;
  },
);
