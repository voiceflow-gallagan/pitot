# Environment variables

> Synthetic test page for catalog-check. It copies the layout of the env vars page, not its text. The variable names are real or made up, the descriptions are written for this test.

## Set environment variables

Export a variable in your shell, or put it in the `env` block of a settings file.

## Variables

| Variable | Purpose |
| :- | :- |
| `ANTHROPIC_API_KEY` | API key for requests |
| `ANTHROPIC_BASE_URL` | Sends requests to another endpoint |
| `CLAUDE_CODE_EXAMPLE_LAUNCH_ONLY` | Made-up variable that only the launcher sets |
| `CLAUDE_CODE_NEW_INIT` | Makes `/init` ask before it writes files |
| `CLAUDE_CODE_SUBAGENT_MODEL` | Model for subagents. See [model aliases](/docs/en/model-config) |
| `CLAUDE_CODE_SUBAGENT_MODEL_FORCE` | Uses `CLAUDE_CODE_SUBAGENT_MODEL` even when a subagent names its own model. Requires Claude Code v2.1.257 or later |
| `CLAUDE_CODE_TMPDIR` | Folder for temporary files |
| `CLAUDE_CONFIG_DIR` | Folder for configuration files |
| `DISABLE_ERROR_REPORTING` | Set to `1` to stop error reports |
| `DISABLE_TELEMETRY` | Set to `1` to stop usage metrics |

## See also

* [Settings](/docs/en/settings-reference)
