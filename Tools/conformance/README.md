# Conformance test

This tool checks that Pitot computes the same settings as a real Claude Code process. It writes project and local settings files into throwaway projects. It asks Pitot's `EffectiveSettings` what a session should see. Then it starts Claude Code in each project and compares what the session really sees.

It only compares values that can be seen from outside a running Claude Code. Those are environment variables, which hooks ran, and two fields that Claude Code reports when a session starts.

## Run it

```bash
cd Tools/conformance
swift test                     # unit tests, no Claude Code needed
swift run conformance --cases  # list the cases and Pitot's expected values, runs nothing
swift run conformance --dry-run --work-dir /tmp/conformance  # write the fixtures, print the commands
swift run conformance          # run Claude Code and compare
```

`--work-dir <path>` picks the folder for the throwaway projects. Without it the tool makes a new folder in the temporary directory. The folder keeps the fixtures and the raw output after the run.

The run prints one row per check, then a summary. It exits 0 when every case passes, 1 when a case fails, and 2 on a usage error or when it cannot write the fixtures.

## How it observes Claude Code

- Each settings file has a `SessionStart` hook. The hook writes the `PITOT_CONF_` variables it sees to its own file. If the file exists, the hook ran, so Claude Code loaded that settings file.
- The project file in the first batch also has a `UserPromptSubmit` hook.
- Claude Code runs with `--output-format stream-json`. The `init` message reports `output_style` and `permissionMode`. The `result` message reports the cost.

## Cases

The rule numbers refer to `Core/MERGE-RULES.md`.

| Case | Rules | What it shows |
|---|---|---|
| `env-local-wins` | 2 | The same env variable in project and local: local wins |
| `env-per-variable` | 3, 6 | Different env variables in project and local: both apply |
| `env-null-text` | 7 | An env variable set to `null` in local: the file still loads, and processes see the text `null` |
| `scalar-local-wins` | 1 | `outputStyle` in project and local: local wins |
| `nested-object-merge` | 11 | `permissions` in both files: the project `defaultMode` stays when local sets only `ask` |
| `hooks-join` | 12 | `SessionStart` hooks from both files run |
| `hooks-per-event` | 13 | A project `UserPromptSubmit` hook runs although local sets other hook events |
| `env-empty-object` | 5 | `env: {}` in local removes no project variable |
| `typed-null-drops-file` | 8, 10 | `outputStyle: null` in local makes Claude Code ignore the whole local file |
| `object-null-drops-file` | 9, 10 | `permissions: null` in project makes Claude Code ignore the whole project file |

Cases that share a project folder are grouped in a batch, and each batch is one Claude Code run. There are 4 batches, so one execution makes 4 runs. The catalog may never need more than 6 runs, and a unit test checks this.

The unit tests also pin Pitot's expected value for every check to what the earlier test runs saw. So a change to `EffectiveSettings` that breaks a rule fails `swift test` before anyone runs Claude Code.

## Safety

- Claude Code runs with `--setting-sources project,local`, so your user settings in `~/.claude/settings.json` are never loaded.
- It runs with `--model haiku`, `--tools ""` (no tools at all), `--strict-mcp-config` (no MCP servers), `--no-session-persistence`, `--max-budget-usd 0.25` and a 60 second limit per run.
- The tool removes `PITOT_CONF_` variables from the environment it passes to Claude Code, so a variable you set yourself cannot fake a result.
- Claude Code creates an empty folder per project under `~/.claude/projects`. The tool removes a folder only when it was not there before the run, its name is the one Claude Code derives from a throwaway project, and it holds no files. Any other folder is reported and left alone.
- Managed settings always load. The machine this was written on has none. On a machine with managed settings that set `env`, hooks, `outputStyle` or `permissions`, the results can differ. That is not a Pitot bug.

## Self-test of the comparison

Set `CONFORMANCE_MUTATE=1`. The tool then flips one expected value: in `env-local-wins`, it expects the project value of `PITOT_CONF_1` instead of the local value. That is what Pitot would say if it ranked project above local. The run must fail with exactly that case.

```bash
CONFORMANCE_MUTATE=1 swift run conformance   # must exit 1
```

## What it cannot prove

- **Most settings are invisible from outside.** A key such as `cleanupPeriodDays` changes behavior, but Claude Code does not print it at startup. This tool cannot see those values, so it cannot check them. It checks the merge rules on keys it can see. The same merge code handles the other keys, but that part is inferred, not proven.
- **The user and managed layers are not tested.** Loading user settings would mean reading your real file. This machine has no managed file.
- **The `--settings` file is not tested.** Pitot does not model the command-line layer, so the tool never passes `--settings`.
- **Some rules are out of reach.** Arrays such as `permissions.allow` join across files, but no outside signal shows the joined list. Restrictive keys, keys that only some layers may set, and env variables Claude Code ignores in project files are not covered. Whether an identical hook in two files runs once or twice is also not covered.
- **Live reload is not tested.** Each run starts a new session.

## Last result

Claude Code 2.1.291, 2026-10-06: 10 of 10 cases pass in 4 runs, reported cost $0.058. The mutation run failed only `env-local-wins`, as intended.
