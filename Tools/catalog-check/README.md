# catalog-check

This tool compares the Pitot catalog with the official Claude Code docs. It reads `Catalog/tweaks.json`, `Catalog/keybindings.json` and `Catalog/unverified.json`. It fetches the docs pages in markdown form and reports every place where the catalog no longer matches them. It needs Node 20 or later and has no dependencies.

## Run it before each release

```bash
cd Tools/catalog-check
npm ci
node check.js
```

The run fetches six pages, one at a time, with a short pause between them. It sends a User-Agent that names the tool, and no cookies or credentials.

The exit code is 0 when the report has no ERROR, 1 when it has at least one, and 2 when an option or an input file is wrong.

## Read the report

Findings are grouped by severity. Each line names the area, the catalog row or key, and what differs.

| Severity | Meaning | What to do |
| :- | :- | :- |
| ERROR | A catalog row is wrong now: a key or action is gone, an enum value is not documented, `minVersion` or scope differs, a suggestion is not documented, or a page did not load or parse | Fix the catalog row, or the parser if the docs only changed format. Do not release with an ERROR |
| WARN | A default, a key binding, a link anchor or a documented enum value may differ | Read the docs entry and decide. Update the row when the docs are right |
| INFO | New documented keys, unverified keys that are now documented, keys that left the docs, and values the check does not compare | Decide whether to add, promote or drop the key |

A page that does not load or no longer parses is always an ERROR. The checks that need that page are skipped, so they cannot pass by accident.

## What it checks

- **Settings rows**: the key is in the settings index and has an entry. The scope column still matches `scope: userOnly`. Enum values match the documented values. The type is still Boolean for bool rows. `minVersion` equals the "Requires Claude Code vX or later" line of the entry. `defaultDescription` starts with the documented default. The `docURL` anchor exists and is the anchor the index uses for that key.
- **Env var rows**: the variable is in the env-vars table and `minVersion` matches its row. A variable that project and local settings cannot set must be `userOnly`.
- **Suggestions**: model aliases are checked against model-config, subagent aliases against sub-agents, and output style names against output-styles. The mapping is in `lib/parse-lists.js`.
- **Keybindings**: contexts and action ids match on both sides. Default keys match per context, including `contextDefaults`. Legacy actions are still mentioned on the page.
- **New and removed keys**: compared with the baseline in `known-keys.json`.

## The baseline of documented keys

`known-keys.json` lists every settings key and env var the docs documented at the last review. The report uses it to say which keys are new and which left the docs. Without it, the report only gives a count of keys that are not in the catalog. Run `--json` to see that full list under `uncataloged`.

After you review the INFO lines, update the baseline:

```bash
node check.js --update-known
```

The tool refuses to write the baseline when a page failed to load or parse.

## Options

| Option | Effect |
| :- | :- |
| `--json` | Print machine-readable output instead of the text report |
| `--offline <dir>` | Read saved pages from a directory instead of fetching them |
| `--save [dir]` | Save the fetched pages to a directory. Without a directory, pages go to `.cache/`, which git ignores. The tool refuses to save into `fixtures/` |
| `--catalog <dir>` | Use another catalog directory. The default is `../../Catalog` |
| `--known <file>` | Use another baseline file. The default is `./known-keys.json` |
| `--update-known` | Rewrite the baseline from the pages after the check |

## Tests

```bash
node --test
```

The tests never use the network, the real docs or the real `Catalog/`. They run against two sets of synthetic files:

| Folder | Content |
| :- | :- |
| `fixtures/pages` | Six short pages written for the tests. They copy the markdown layout of the docs pages: tables, one heading per key, Scope, Type and Default bullets, "Requires Claude Code vX" phrases. The text is our own. |
| `fixtures/catalog` | `tweaks.json`, `keybindings.json` and `unverified.json` with the same structure as `Catalog/`, but only the rows the synthetic pages cover |

Each test copies both folders to a temporary workspace, changes a catalog row or a page, and checks the finding.

Never save the real docs pages into `fixtures/`. They are not ours to publish, and the tool refuses to write there. To look at the current pages, save them to the cache and run the check on the saved copy:

```bash
node check.js --save
node check.js --offline .cache
```

When the docs change their layout, change the synthetic page in `fixtures/pages` the same way, in our own words, then update the parser until the tests pass.

## Limits

- The parser reads the current markdown layout: the settings index table, one `### \`key\`` entry per setting with Scope, Type and Default bullets, the env-vars Variables table, and the keybindings Contexts and action tables. Large layout changes trigger "cannot parse" errors.
- The context of a keybinding table comes from the nearest paragraph above it that names a context. The History table names none, so its rows are not checked for context.
- Enum aliases such as `manual` and patterns such as `custom:<slug>` are listed as INFO and not compared.
- Defaults are compared only when the docs give "unset" or a single literal value. A free-text default is not compared.
- Env var scope comes from the prose list "Variables Claude Code ignores in env" on the settings reference. A variable that list does not name is treated as settable from any file.
