# How Claude Code merges settings files

Pitot shows which settings file wins for each key. This page lists the merge rules it follows. Code comments and tests refer to them by number.

"Tested" means a run of Claude Code on throwaway files showed the rule. `Tools/conformance` repeats those runs. "Docs" means the official docs state it. "Inferred" means neither: the rule fits the tested ones and Pitot assumes it.

Layers, lowest to highest: user (`~/.claude/settings.json`), project (`.claude/settings.json`), local (`.claude/settings.local.json`), the `--settings` file of one session, and managed settings.

| # | Rule | Status |
|---|---|---|
| 1 | The same key with a plain value in project and local: the local value wins. | Tested |
| 2 | The same env variable in project and local: the local value wins. | Tested |
| 3 | Different env variables in several files all apply. `env` merges per variable. | Tested |
| 4 | The same env variable in the `--settings` file and local: the `--settings` value wins. | Tested |
| 5 | An empty `env: {}` in a higher file removes nothing. | Tested |
| 6 | A variable missing from a higher file keeps the lower value. | Tested |
| 7 | An env variable set to `null` in a higher file wins, and processes see the text `null`. | Tested |
| 8 | A typed key set to `null`, such as `"outputStyle": null`, makes Claude Code ignore the whole file. | Tested |
| 9 | An object set to `null`, such as `"permissions": null`, makes Claude Code ignore the whole file. | Tested |
| 10 | In `-p` mode an invalid file is dropped without a message. Interactive sessions show a settings error. | Tested, docs |
| 11 | Nested objects merge key by key. A higher `permissions` block without `defaultMode` keeps the lower `defaultMode`. | Tested |
| 12 | Hook lists from several files join, so every hook runs. | Tested, docs |
| 13 | `hooks` merges per event. | Tested |
| 14 | `permissions.allow` lists from several files join. | Tested, docs |
| 15 | Project `permissions.allow` rules are ignored until the folder is trusted. | Tested, docs |
| 16 | Layer order, lowest to highest: user, project, local, `--settings`, managed. | Tested for project, local and `--settings`; docs for user and managed |
| 17 | Objects merge recursively at every depth. Lists join, lower file first. | Inferred from rules 3, 5, 7, 11, 12, 13 |
| 18 | Repeated list entries are removed: strings, numbers and Booleans by value. | Docs for managed files, inferred elsewhere |
| 19 | `fallbackModel` comes whole from the highest file. `modelPicker` comes whole from managed, `--settings` or user. | Docs |
| 20 | An `extraKnownMarketplaces` or `managedMcpServers` entry from a higher file replaces the lower entry with the same name whole. | Docs |
| 21 | A managed `availableModels` list applies as is. `deniedModels` is read from managed settings only. | Docs, inferred for `deniedModels` |
| 22 | `sandbox` Booleans come from the highest file, and managed overrides. `sandbox` lists join. | Docs |
| 23 | `enabledPlugins` is decided per plugin by the highest file. | Docs |
| 24 | For `env`, the highest file that sets a variable wins. | Docs, tested by rules 2 to 6 |
| 25 | Claude Code ignores some variables, such as `CLAUDE_CONFIG_DIR`, `HOME` and `TMPDIR`, in project and local `env`. | Docs |
| 26 | A `deny` rule from any file beats an `allow` rule from any file. | Docs |
| 27 | Some restrictive values win even over managed settings, such as `disableClaudeAiConnectors: true` from any file or the lowest `maxEffortLevel`. | Docs, not tested |
| 28 | Managed settings: `managed-settings.json` first, then `managed-settings.d/*.json` in alphabetical order. Nested blocks merge key by key. | Docs |
| 29 | A file sets a key when the key is present. A `null` value counts as set. | Inferred |

Docs pages: https://code.claude.com/docs/en/settings, https://code.claude.com/docs/en/settings-reference, https://code.claude.com/docs/en/managed-settings, https://code.claude.com/docs/en/hooks and https://code.claude.com/docs/en/permissions.

Pitot never writes `null` to a settings file. To unset a key it removes the key, because of rules 8 and 9.
